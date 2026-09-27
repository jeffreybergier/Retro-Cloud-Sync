#include "RCDAVStaging.h"
#include <limits.h>

static int Failed(RCError *error)
{
  RCErrorSet(error, 1, "Could not stage DAV inventory");
  return 0;
}
sqlite3 *RCDAVStageOpen(RCError *error)
{
  sqlite3 *db = NULL;
  /* SQLite's empty filename creates a private, automatically deleted disk
     database. Do not use :memory: for potentially large contact/photo mirrors. */
  if (sqlite3_open("", &db) == SQLITE_OK &&
      sqlite3_exec(db, "CREATE TABLE resources(sequence INTEGER PRIMARY KEY,"
          "collection INTEGER NOT NULL,action INTEGER NOT NULL,href TEXT NOT NULL,"
          "etag TEXT,body BLOB);CREATE INDEX resource_lookup ON resources(collection,href)",
          NULL, NULL, NULL) == SQLITE_OK) return db;
  sqlite3_close(db); Failed(error); return NULL;
}
int RCDAVStageReset(sqlite3 *db, long long collection, RCError *error)
{
  sqlite3_stmt *q = NULL;
  int ok = sqlite3_prepare_v2(db, "DELETE FROM resources WHERE collection=?", -1, &q, NULL) == SQLITE_OK;
  if (ok) { sqlite3_bind_int64(q, 1, collection); ok = sqlite3_step(q) == SQLITE_DONE; }
  sqlite3_finalize(q); return ok ? 1 : Failed(error);
}
int RCDAVStageHasResource(sqlite3 *db, long long collection, const char *href,
                          int *present, RCError *error)
{
  sqlite3_stmt *q = NULL; int step = SQLITE_ERROR;
  if (sqlite3_prepare_v2(db, "SELECT 1 FROM resources WHERE collection=? AND href=? LIMIT 1", -1, &q, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(q, 1, collection); sqlite3_bind_text(q, 2, href, -1, SQLITE_STATIC);
    step = sqlite3_step(q);
  }
  *present = step == SQLITE_ROW;
  sqlite3_finalize(q); return step == SQLITE_ROW || step == SQLITE_DONE ? 1 : Failed(error);
}
int RCDAVStageSave(sqlite3 *db, long long collection, int action, const char *href,
                   const char *etag, const void *body, size_t length, RCError *error)
{
  sqlite3_stmt *q = NULL; int ok = 0;
  if (length > INT_MAX) return Failed(error);
  if (sqlite3_prepare_v2(db, "INSERT INTO resources(collection,action,href,etag,body) VALUES(?,?,?,?,?)", -1, &q, NULL) == SQLITE_OK) {
    ok = sqlite3_bind_int64(q, 1, collection) == SQLITE_OK &&
        sqlite3_bind_int(q, 2, action) == SQLITE_OK &&
        sqlite3_bind_text(q, 3, href, -1, SQLITE_STATIC) == SQLITE_OK &&
        sqlite3_bind_text(q, 4, etag, -1, SQLITE_STATIC) == SQLITE_OK &&
        sqlite3_bind_blob(q, 5, body, (int)length, SQLITE_STATIC) == SQLITE_OK &&
        sqlite3_step(q) == SQLITE_DONE;
  }
  sqlite3_finalize(q); return ok ? 1 : Failed(error);
}
int RCDAVStageApply(sqlite3 *db, long long collection, RCDAVStageCallback apply,
                    void *context, RCError *error)
{
  sqlite3_stmt *q = NULL; int step = SQLITE_ERROR;
  if (sqlite3_prepare_v2(db, "SELECT action,href,etag,body FROM resources WHERE collection=? ORDER BY sequence", -1, &q, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(q, 1, collection);
    while ((step = sqlite3_step(q)) == SQLITE_ROW) {
      if (RCCheckCancellation(error) || !apply(sqlite3_column_int(q, 0),
          (const char *)sqlite3_column_text(q, 1), (const char *)sqlite3_column_text(q, 2),
          sqlite3_column_blob(q, 3), (size_t)sqlite3_column_bytes(q, 3), context, error)) {
        sqlite3_finalize(q); return 0;
      }
    }
  }
  sqlite3_finalize(q); return step == SQLITE_DONE ? 1 : Failed(error);
}
int RCDAVMirrorResourceCurrent(sqlite3 *db, long long account, int calendar,
    const char *collection, const char *href, const char *etag, int *current, RCError *error)
{
  sqlite3_stmt *q = NULL; int step = SQLITE_ERROR;
  const char *sql = calendar ?
      "SELECT 1 FROM calendar_resources r JOIN calendars c ON c.id=r.calendar_id WHERE c.account_id=? AND c.url=? AND r.href=? AND r.etag=? AND length(r.raw_ical)>0" :
      "SELECT 1 FROM contacts r JOIN collections c ON c.id=r.collection_id WHERE c.account_id=? AND c.url=? AND r.href=? AND r.etag=?";
  if (sqlite3_prepare_v2(db, sql, -1, &q, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(q, 1, account); sqlite3_bind_text(q, 2, collection, -1, SQLITE_STATIC);
    sqlite3_bind_text(q, 3, href, -1, SQLITE_STATIC); sqlite3_bind_text(q, 4, etag, -1, SQLITE_STATIC);
    step = sqlite3_step(q);
  }
  *current = step == SQLITE_ROW;
  sqlite3_finalize(q);
  if (step == SQLITE_ROW || step == SQLITE_DONE) return 1;
  RCErrorSet(error, 1, "Could not read mirror resource version"); return 0;
}
