#include "RCWriteJournal.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static int fail(sqlite3 *db, RCError *e)
{
  RCErrorSet(e, 1, "Write journal database error: %s", sqlite3_errmsg(db));
  return 0;
}
static int exec(sqlite3 *db, const char *sql, RCError *e)
{
  return sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK ? 1 : fail(db, e);
}
static int prepare(sqlite3 *db, const char *sql, sqlite3_stmt **q, RCError *e)
{
  return sqlite3_prepare_v2(db, sql, -1, q, NULL) == SQLITE_OK ? 1 : fail(db, e);
}
static void text(sqlite3_stmt *q, int n, const char *s)
{
  sqlite3_bind_text(q, n, s, -1, SQLITE_TRANSIENT);
}
static void blob(sqlite3_stmt *q, int n, const void *p, size_t len)
{
  if (p) sqlite3_bind_blob(q, n, p, (int)len, SQLITE_TRANSIENT);
  else sqlite3_bind_null(q, n);
}
static int outsideTransaction(RCWriteJournal *j, RCError *e)
{
  if (sqlite3_get_autocommit(j->db)) return 1;
  RCErrorSet(e, 1, "Write journal operation requires a committed transaction");
  return 0;
}
int RCWriteETagIsStrong(const char *s)
{
  size_t i, n = s ? strlen(s) : 0;
  if (n < 2 || s[0] != '"' || s[n - 1] != '"') return 0;
  for (i = 1; i + 1 < n; i++)
    if ((unsigned char)s[i] < 0x21 || s[i] == '"' || s[i] == 0x7f) return 0;
  return 1;
}
int RCWriteJournalInitialize(sqlite3 *db, RCError *e)
{
  return exec(db,
      "CREATE TABLE IF NOT EXISTS write_bases("
      "account_id INTEGER NOT NULL REFERENCES accounts(id),resource_key TEXT NOT NULL,"
      "href TEXT NOT NULL,etag TEXT,body BLOB NOT NULL,local_revision INTEGER NOT NULL,"
      "PRIMARY KEY(account_id,resource_key));"
      "CREATE TABLE IF NOT EXISTS write_operations("
      "id INTEGER PRIMARY KEY,account_id INTEGER NOT NULL REFERENCES accounts(id),"
      "change_id TEXT NOT NULL,resource_key TEXT NOT NULL,href TEXT NOT NULL,"
      "kind TEXT NOT NULL CHECK(kind IN ('create','update','delete')),"
      "state TEXT NOT NULL CHECK(state IN ('queued','uncertain','applied','conflict','acknowledged','cancelled')),"
      "local_revision INTEGER NOT NULL,base_etag TEXT,base_body BLOB,desired_body BLOB,"
      "attempts INTEGER NOT NULL DEFAULT 0,retry_at INTEGER NOT NULL DEFAULT 0,"
      "http_status INTEGER,result_etag TEXT,result_body BLOB,"
      "UNIQUE(account_id,change_id));"
      "CREATE INDEX IF NOT EXISTS write_due ON write_operations(account_id,state,retry_at);",
      e);
}
int RCWriteJournalSetBase(RCWriteJournal *j, const char *key, const char *href,
    const char *etag, const void *body, size_t len, long long revision, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int ok;
  if (!key || !*key || !href || !*href || !body || !len || len > INT_MAX || revision <= 0) {
    RCErrorSet(e, 1, "Invalid published write base"); return 0;
  }
  if (!prepare(j->db, "INSERT OR REPLACE INTO write_bases"
      "(account_id,resource_key,href,etag,body,local_revision) VALUES(?,?,?,?,?,?)", &q, e)) return 0;
  sqlite3_bind_int64(q, 1, j->account); text(q, 2, key); text(q, 3, href);
  text(q, 4, etag); blob(q, 5, body, len); sqlite3_bind_int64(q, 6, revision);
  ok = sqlite3_step(q) == SQLITE_DONE;
  sqlite3_finalize(q);
  return ok ? 1 : fail(j->db, e);
}

int RCWriteJournalEnqueue(RCWriteJournal *j, const char *change, const char *key,
    const char *href, const char *kind, long long revision, const void *body,
    size_t len, long long *id, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int create, deleting, step, ok = 0;
  *id = 0;
  if (!change || !*change || !key || !*key || !href || strncmp(href, "https://", 8) ||
      !kind || (strcmp(kind, "create") && strcmp(kind, "update") && strcmp(kind, "delete")) ||
      len > INT_MAX) {
    RCErrorSet(e, 1, "Invalid outgoing operation"); return 0;
  }
  create = !strcmp(kind, "create"); deleting = !strcmp(kind, "delete");
  if ((deleting && (body || len)) || (!deleting && (!body || !len)) ||
      (create ? revision != 0 : revision <= 0)) {
    RCErrorSet(e, 1, "Outgoing operation has no valid body or base revision"); return 0;
  }
  if (!outsideTransaction(j, e) || !exec(j->db, "BEGIN IMMEDIATE", e)) return 0;
  if (!prepare(j->db, "SELECT id,resource_key,href,kind,local_revision,desired_body "
      "FROM write_operations WHERE account_id=? AND change_id=?", &q, e)) goto done;
  sqlite3_bind_int64(q, 1, j->account); text(q, 2, change);
  step = sqlite3_step(q);
  if (step == SQLITE_ROW) {
    if (strcmp(key, (const char *)sqlite3_column_text(q, 1)) ||
        strcmp(href, (const char *)sqlite3_column_text(q, 2)) ||
        strcmp(kind, (const char *)sqlite3_column_text(q, 3)) ||
        revision != sqlite3_column_int64(q, 4) ||
        len != (size_t)sqlite3_column_bytes(q, 5) ||
        (len && memcmp(body, sqlite3_column_blob(q, 5), len))) {
      RCErrorSet(e, 1, "Local change identifier was reused for a different operation"); goto done;
    }
    *id = sqlite3_column_int64(q, 0); ok = 1; goto done;
  }
  if (step != SQLITE_DONE) goto sqlError;
  sqlite3_finalize(q); q = NULL;
  if (!prepare(j->db, "SELECT id FROM write_operations WHERE account_id=? AND "
      "(resource_key=? OR href=?) AND state NOT IN ('acknowledged','cancelled')", &q, e)) goto done;
  sqlite3_bind_int64(q, 1, j->account); text(q, 2, key); text(q, 3, href);
  step = sqlite3_step(q);
  if (step == SQLITE_ROW) { RCErrorSet(e, 1, "Resource already has an unresolved write"); goto done; }
  if (step != SQLITE_DONE) goto sqlError;
  sqlite3_finalize(q); q = NULL;
  if (!prepare(j->db, "SELECT href,etag,local_revision FROM write_bases WHERE "
      "account_id=? AND resource_key=?", &q, e)) goto done;
  sqlite3_bind_int64(q, 1, j->account); text(q, 2, key);
  step = sqlite3_step(q);
  if (step != SQLITE_ROW && step != SQLITE_DONE) goto sqlError;
  if ((create && step != SQLITE_DONE) || (!create && (step != SQLITE_ROW ||
      strcmp(href, (const char *)sqlite3_column_text(q, 0)) ||
      !RCWriteETagIsStrong((const char *)sqlite3_column_text(q, 1)) ||
      revision != sqlite3_column_int64(q, 2)))) {
    RCErrorSet(e, 1, "Write requires the exact published base and a strong ETag"); goto done;
  }
  sqlite3_finalize(q); q = NULL;
  if (!prepare(j->db, "INSERT INTO write_operations(account_id,change_id,resource_key,href,kind,"
      "state,local_revision,desired_body,base_etag,base_body) VALUES(?,?,?,?,?,'queued',?,?,"
      "(SELECT etag FROM write_bases WHERE account_id=?1 AND resource_key=?3),"
      "(SELECT body FROM write_bases WHERE account_id=?1 AND resource_key=?3))", &q, e)) goto done;
  sqlite3_bind_int64(q, 1, j->account); text(q, 2, change); text(q, 3, key);
  text(q, 4, href); text(q, 5, kind); sqlite3_bind_int64(q, 6, revision); blob(q, 7, body, len);
  if (sqlite3_step(q) != SQLITE_DONE) goto sqlError;
  *id = sqlite3_last_insert_rowid(j->db); ok = 1;
  goto done;
sqlError:
  fail(j->db, e);
done:
  sqlite3_finalize(q);
  if (ok) ok = exec(j->db, "COMMIT", e);
  if (!ok) { exec(j->db, "ROLLBACK", NULL); *id = 0; }
  return ok;
}

void RCWriteOperationClear(RCWriteOperation *o)
{
  free(o->changeID);
  free(o->resourceKey); free(o->href); free(o->kind); free(o->state);
  free(o->baseETag); free(o->resultETag);
  free(o->baseBody); free(o->desiredBody); free(o->resultBody);
  memset(o, 0, sizeof(*o));
}
static void *copyColumn(sqlite3_stmt *q, int n)
{
  size_t len = (size_t)sqlite3_column_bytes(q, n);
  unsigned char *p;
  if (sqlite3_column_type(q, n) == SQLITE_NULL) return NULL;
  p = malloc(len + 1);
  if (p) { if (len) memcpy(p, sqlite3_column_blob(q, n), len); p[len] = 0; }
  return p;
}
int RCWriteJournalGet(RCWriteJournal *j, long long id, RCWriteOperation *o, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int ok = 0;
  memset(o, 0, sizeof(*o));
  if (!prepare(j->db, "SELECT resource_key,href,kind,state,base_etag,result_etag,"
      "base_body,desired_body,result_body,local_revision,attempts,change_id,retry_at,http_status FROM write_operations "
      "WHERE account_id=? AND id=?", &q, e)) return 0;
  sqlite3_bind_int64(q, 1, j->account); sqlite3_bind_int64(q, 2, id);
  if (sqlite3_step(q) != SQLITE_ROW) { RCErrorSet(e, 1, "Outgoing operation is unavailable for this account"); goto done; }
#define COPY(field, n) do { o->field = copyColumn(q,n); \
    if (sqlite3_column_type(q,n) != SQLITE_NULL && !o->field) { \
      RCErrorSet(e,1,"Out of memory reading outgoing operation"); goto done; } } while (0)
  COPY(resourceKey,0); COPY(href,1); COPY(kind,2); COPY(state,3);
  COPY(baseETag,4); COPY(resultETag,5); COPY(baseBody,6); COPY(desiredBody,7); COPY(resultBody,8);
  COPY(changeID,11);
#undef COPY
  o->baseLength = (size_t)sqlite3_column_bytes(q,6);
  o->desiredLength = (size_t)sqlite3_column_bytes(q,7);
  o->resultLength = (size_t)sqlite3_column_bytes(q,8);
  o->localRevision = sqlite3_column_int64(q,9); o->attempts = sqlite3_column_int(q,10);
  o->retryAt = sqlite3_column_int64(q,12); o->httpStatus = sqlite3_column_int(q,13);
  o->id = id; ok = 1;
done:
  sqlite3_finalize(q);
  if (!ok) RCWriteOperationClear(o);
  return ok;
}
int RCWriteJournalNext(RCWriteJournal *j, long long now, long long *id, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int step;
  *id = 0;
  if (!prepare(j->db, "SELECT id FROM write_operations WHERE account_id=? AND "
      "state IN ('queued','uncertain') AND retry_at<=? ORDER BY id LIMIT 1", &q, e)) return 0;
  sqlite3_bind_int64(q,1,j->account); sqlite3_bind_int64(q,2,now);
  step = sqlite3_step(q);
  if (step == SQLITE_ROW) *id = sqlite3_column_int64(q,0);
  sqlite3_finalize(q);
  return step == SQLITE_ROW || step == SQLITE_DONE ? 1 : fail(j->db,e);
}
int RCWriteJournalBeginAttempt(RCWriteJournal *j, long long id, long long now, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int ok;
  if (now < 0 || now > LLONG_MAX - 3600) {
    RCErrorSet(e,1,"Invalid outgoing attempt time"); return 0;
  }
  if (!outsideTransaction(j,e) || !prepare(j->db, "UPDATE write_operations SET "
      "state='uncertain',retry_at=?+CASE WHEN attempts<10 THEN (5 << attempts) ELSE 3600 END,"
      "attempts=attempts+1,http_status=NULL,result_etag=NULL,result_body=NULL "
      "WHERE account_id=? AND id=? AND state IN ('queued','uncertain') "
      "AND retry_at<=?", &q,e)) return 0;
  sqlite3_bind_int64(q,1,now); sqlite3_bind_int64(q,2,j->account);
  sqlite3_bind_int64(q,3,id); sqlite3_bind_int64(q,4,now);
  ok = sqlite3_step(q) == SQLITE_DONE && sqlite3_changes(j->db) == 1;
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(e,1,"Outgoing operation is not due or cannot be attempted");
  return ok;
}
int RCWriteJournalRecordResult(RCWriteJournal *j, long long id, const char *state,
    int status, const char *etag, const void *body, size_t len, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int ok;
  if (!state || (strcmp(state,"uncertain") && strcmp(state,"applied") && strcmp(state,"conflict")) ||
      len > INT_MAX || (!body && len) ||
      (!strcmp(state,"applied") && status != 404 && (!RCWriteETagIsStrong(etag) || !body || !len))) {
    RCErrorSet(e,1,"Invalid outgoing write result"); return 0;
  }
  if (!outsideTransaction(j,e) || !prepare(j->db, "UPDATE write_operations SET state=?,"
      "http_status=?,result_etag=?,result_body=? WHERE account_id=? AND id=? AND state='uncertain'"
      " AND (?1!='applied' OR (kind='delete' AND ?2=404) OR (kind!='delete' AND ?2=200))", &q,e)) return 0;
  text(q,1,state); sqlite3_bind_int(q,2,status); text(q,3,etag); blob(q,4,body,len);
  sqlite3_bind_int64(q,5,j->account); sqlite3_bind_int64(q,6,id);
  ok = sqlite3_step(q) == SQLITE_DONE && sqlite3_changes(j->db) == 1;
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(e,1,"Outgoing write result cannot be recorded in this state");
  return ok;
}
static int terminal(RCWriteJournal *j, long long id, int ack, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int ok;
  if (!prepare(j->db, ack ? "UPDATE write_operations SET state='acknowledged' WHERE "
      "account_id=? AND id=? AND state IN ('applied','acknowledged')" :
      "UPDATE write_operations SET state='cancelled' WHERE account_id=? AND id=? "
      "AND state IN ('queued','conflict','cancelled')", &q,e)) return 0;
  sqlite3_bind_int64(q,1,j->account); sqlite3_bind_int64(q,2,id);
  ok = sqlite3_step(q) == SQLITE_DONE && sqlite3_changes(j->db) == 1;
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(e,1,"Outgoing operation cannot be acknowledged or cancelled in this state");
  return ok;
}
int RCWriteJournalAcknowledge(RCWriteJournal *j, long long id, RCError *e) { return terminal(j,id,1,e); }
int RCWriteJournalCancel(RCWriteJournal *j, long long id, RCError *e) { return terminal(j,id,0,e); }
