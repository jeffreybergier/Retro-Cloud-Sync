#include "RCDAVSyncState.h"
#include <stdlib.h>
#include <string.h>

static int fail(RCDAVSyncState *s, RCError *e)
{
  RCErrorSet(e, 1, "DAV sync state: %s", sqlite3_errmsg(s->db));
  return 0;
}
static int prepare(RCDAVSyncState *s, const char *sql, sqlite3_stmt **q, RCError *e)
{
  if (sqlite3_get_autocommit(s->db)) {
    RCErrorSet(e, 1, "DAV sync state requires the mirror transaction"); return 0;
  }
  /* Additive metadata upgrade: no resource tables or identities are rebuilt. */
  if (sqlite3_exec(s->db, "CREATE TABLE IF NOT EXISTS dav_sync_state("
      "account_id INTEGER NOT NULL REFERENCES accounts(id),collection_url TEXT NOT NULL,"
      "token TEXT,scope TEXT NOT NULL,seen_run INTEGER NOT NULL,"
      "PRIMARY KEY(account_id,collection_url))", NULL, NULL, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(s->db, sql, -1, q, NULL) != SQLITE_OK) return fail(s, e);
  sqlite3_bind_int64(*q, 1, s->account);
  return 1;
}
static char *copy(const unsigned char *text)
{
  char *result;
  if (!text) return NULL;
  result = malloc(strlen((const char *)text) + 1);
  if (result) strcpy(result, (const char *)text);
  return result;
}
int RCDAVSyncStateLoad(RCDAVSyncState *s, const char *url, char **token,
                       char **scope, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int step, ok = 1;
  *token = NULL; *scope = NULL;
  /* Reads precede network work and must not open a write transaction or create
     metadata. An older mirror has no token until its first complete commit. */
  if (sqlite3_prepare_v2(s->db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='dav_sync_state'", -1, &q, NULL) != SQLITE_OK) return fail(s, e);
  step = sqlite3_step(q); sqlite3_finalize(q); q = NULL;
  if (step == SQLITE_DONE) return 1;
  if (step != SQLITE_ROW || sqlite3_prepare_v2(s->db,
      "SELECT token,scope FROM dav_sync_state WHERE account_id=?1 AND collection_url=?2",
      -1, &q, NULL) != SQLITE_OK) return fail(s, e);
  sqlite3_bind_int64(q, 1, s->account);
  sqlite3_bind_text(q, 2, url, -1, SQLITE_TRANSIENT);
  step = sqlite3_step(q);
  if (step == SQLITE_ROW) {
    *token = copy(sqlite3_column_text(q, 0));
    *scope = copy(sqlite3_column_text(q, 1));
    ok = *scope != NULL && (sqlite3_column_type(q, 0) == SQLITE_NULL || *token != NULL);
  } else if (step != SQLITE_DONE) ok = 0;
  sqlite3_finalize(q);
  if (!ok) {
    free(*token); free(*scope); *token = NULL; *scope = NULL;
    RCErrorSet(e, 1, "Could not read durable DAV sync state");
  }
  return ok;
}
int RCDAVSyncStateSave(RCDAVSyncState *s, const char *url, const char *token,
                       const char *scope, long long run, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int step;
  if (!prepare(s, "INSERT OR REPLACE INTO dav_sync_state"
      "(account_id,collection_url,token,scope,seen_run) VALUES(?1,?2,?3,?4,?5)", &q, e)) return 0;
  sqlite3_bind_text(q, 2, url, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(q, 3, token, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(q, 4, scope ? scope : "", -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(q, 5, run);
  step = sqlite3_step(q); sqlite3_finalize(q);
  return step == SQLITE_DONE ? 1 : fail(s, e);
}
int RCDAVSyncStateFinish(RCDAVSyncState *s, long long run, RCError *e)
{
  sqlite3_stmt *q = NULL;
  int step;
  if (!prepare(s, "DELETE FROM dav_sync_state WHERE account_id=?1 AND seen_run!=?2", &q, e)) return 0;
  sqlite3_bind_int64(q, 2, run);
  step = sqlite3_step(q); sqlite3_finalize(q);
  return step == SQLITE_DONE ? 1 : fail(s, e);
}
