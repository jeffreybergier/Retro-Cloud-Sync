#include "RCContactStore.h"

#include <AltivecCore/sqlite3.h>

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

struct RCContactStore {
  sqlite3 *database;
};

static int RCStoreError(RCContactStore *store, RCError *error,
                        const char *operation)
{
  RCErrorSet(error, sqlite3_errcode(store->database), "%s: %s", operation,
             sqlite3_errmsg(store->database));
  return 0;
}

static int RCExecute(RCContactStore *store, const char *sql, RCError *error)
{
  char *message = NULL;
  int result = sqlite3_exec(store->database, sql, NULL, NULL, &message);
  if (result != SQLITE_OK) {
    RCErrorSet(error, result, "SQLite error: %s",
               message != NULL ? message : sqlite3_errmsg(store->database));
    sqlite3_free(message);
    return 0;
  }
  return 1;
}

static int RCPrepare(RCContactStore *store, const char *sql,
                     sqlite3_stmt **statement, RCError *error)
{
  if (sqlite3_prepare_v2(store->database, sql, -1, statement, NULL) !=
      SQLITE_OK) {
    return RCStoreError(store, error, "Could not prepare database statement");
  }
  return 1;
}

static void RCBindText(sqlite3_stmt *statement, int index, const char *value)
{
  if (value == NULL) {
    sqlite3_bind_null(statement, index);
  } else {
    sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT);
  }
}

static const char kRCSchema[] =
  "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);"
  "INSERT INTO schema_version(version) SELECT 1 "
    "WHERE NOT EXISTS (SELECT 1 FROM schema_version);"
  "CREATE TABLE IF NOT EXISTS sync_runs ("
    "id INTEGER PRIMARY KEY, started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
    "finished_at TEXT, succeeded INTEGER, message TEXT);"
  "CREATE TABLE IF NOT EXISTS collections ("
    "id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, display_name TEXT,"
    "last_complete_run_id INTEGER);"
  "CREATE TABLE IF NOT EXISTS contacts ("
    "id INTEGER PRIMARY KEY, collection_id INTEGER NOT NULL, href TEXT NOT NULL,"
    "uid TEXT, etag TEXT, vcard_version TEXT, formatted_name TEXT,"
    "given_name TEXT, family_name TEXT, organization TEXT, title TEXT,"
    "birthday TEXT, raw_vcard BLOB NOT NULL, seen_run_id INTEGER NOT NULL,"
    "remote_missing INTEGER NOT NULL DEFAULT 0,"
    "UNIQUE(collection_id, href),"
    "FOREIGN KEY(collection_id) REFERENCES collections(id));"
  "CREATE TABLE IF NOT EXISTS contact_properties ("
    "id INTEGER PRIMARY KEY, contact_id INTEGER NOT NULL, position INTEGER NOT NULL,"
    "group_name TEXT, property_name TEXT NOT NULL, decoded_value TEXT,"
    "original_value TEXT, value_type TEXT,"
    "FOREIGN KEY(contact_id) REFERENCES contacts(id) ON DELETE CASCADE);"
  "CREATE TABLE IF NOT EXISTS contact_parameters ("
    "id INTEGER PRIMARY KEY, property_id INTEGER NOT NULL, position INTEGER NOT NULL,"
    "parameter_name TEXT NOT NULL, parameter_value TEXT NOT NULL,"
    "FOREIGN KEY(property_id) REFERENCES contact_properties(id) ON DELETE CASCADE);"
  "CREATE TABLE IF NOT EXISTS contact_value_parts ("
    "id INTEGER PRIMARY KEY, property_id INTEGER NOT NULL, component INTEGER NOT NULL,"
    "position INTEGER NOT NULL, decoded_value TEXT,"
    "FOREIGN KEY(property_id) REFERENCES contact_properties(id) ON DELETE CASCADE);"
  "CREATE INDEX IF NOT EXISTS contacts_collection_seen "
    "ON contacts(collection_id, seen_run_id);"
  "CREATE INDEX IF NOT EXISTS properties_contact "
    "ON contact_properties(contact_id, position);";

RCContactStore *RCContactStoreOpen(const char *path, RCError *error)
{
  RCContactStore *store;
  int version = 0;

  RCErrorClear(error);
  if (path == NULL) {
    RCErrorSet(error, 1, "Database path is missing");
    return NULL;
  }
  store = (RCContactStore *)calloc(1, sizeof(*store));
  if (store == NULL) {
    RCErrorSet(error, 1, "Out of memory opening contact database");
    return NULL;
  }
  if (sqlite3_open_v2(path, &store->database,
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) !=
      SQLITE_OK) {
    RCStoreError(store, error, "Could not open contact database");
    RCContactStoreClose(store);
    return NULL;
  }
  if (chmod(path, S_IRUSR | S_IWUSR) != 0) {
    RCErrorSet(error, 1, "Could not restrict contact database permissions");
    RCContactStoreClose(store);
    return NULL;
  }
  sqlite3_busy_timeout(store->database, 5000);
  if (!RCExecute(store, "PRAGMA foreign_keys=ON;", error) ||
      !RCExecute(store, kRCSchema, error)) {
    RCContactStoreClose(store);
    return NULL;
  }
  {
    sqlite3_stmt *statement = NULL;
    if (!RCPrepare(store, "SELECT version FROM schema_version LIMIT 1",
                   &statement, error) || sqlite3_step(statement) != SQLITE_ROW) {
      sqlite3_finalize(statement);
      RCContactStoreClose(store);
      return NULL;
    }
    version = sqlite3_column_int(statement, 0);
    sqlite3_finalize(statement);
  }
  if (version != 1) {
    RCErrorSet(error, 1, "Unsupported contact database schema version %d",
               version);
    RCContactStoreClose(store);
    return NULL;
  }
  return store;
}

void RCContactStoreClose(RCContactStore *store)
{
  if (store == NULL) return;
  if (store->database != NULL) sqlite3_close(store->database);
  free(store);
}

int RCContactStoreBeginRun(RCContactStore *store, long long *runIdentifier,
                           RCError *error)
{
  if (!RCExecute(store, "INSERT INTO sync_runs DEFAULT VALUES", error)) return 0;
  *runIdentifier = sqlite3_last_insert_rowid(store->database);
  return 1;
}

int RCContactStoreGetCollection(RCContactStore *store, const char *url,
                                const char *displayName,
                                long long *collectionIdentifier,
                                RCError *error)
{
  sqlite3_stmt *statement = NULL;
  int result;

  if (!RCPrepare(store,
      "INSERT OR IGNORE INTO collections(url, display_name) VALUES(?, ?)",
      &statement, error)) return 0;
  RCBindText(statement, 1, url);
  RCBindText(statement, 2, displayName);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  if (result != SQLITE_DONE) return RCStoreError(store, error,
                                                  "Could not add collection");

  if (!RCPrepare(store,
      "UPDATE collections SET display_name=COALESCE(?, display_name) WHERE url=?",
      &statement, error)) return 0;
  RCBindText(statement, 1, displayName);
  RCBindText(statement, 2, url);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  if (result != SQLITE_DONE) return RCStoreError(store, error,
                                                  "Could not update collection");

  if (!RCPrepare(store, "SELECT id FROM collections WHERE url=?", &statement,
                 error)) return 0;
  RCBindText(statement, 1, url);
  result = sqlite3_step(statement);
  if (result == SQLITE_ROW) *collectionIdentifier = sqlite3_column_int64(statement, 0);
  sqlite3_finalize(statement);
  if (result != SQLITE_ROW) return RCStoreError(store, error,
                                                 "Could not find collection");
  return 1;
}

int RCContactStoreResourceIsCurrent(RCContactStore *store,
                                    long long collectionIdentifier,
                                    const char *href, const char *etag,
                                    int *isCurrent, RCError *error)
{
  sqlite3_stmt *statement = NULL;
  int result;

  *isCurrent = 0;
  if (!RCPrepare(store,
      "SELECT etag FROM contacts WHERE collection_id=? AND href=?", &statement,
      error)) return 0;
  sqlite3_bind_int64(statement, 1, collectionIdentifier);
  RCBindText(statement, 2, href);
  result = sqlite3_step(statement);
  if (result == SQLITE_ROW && etag != NULL && sqlite3_column_type(statement, 0) !=
      SQLITE_NULL) {
    const char *stored = (const char *)sqlite3_column_text(statement, 0);
    *isCurrent = stored != NULL && strcmp(stored, etag) == 0;
  }
  sqlite3_finalize(statement);
  if (result != SQLITE_ROW && result != SQLITE_DONE) {
    return RCStoreError(store, error, "Could not inspect contact ETag");
  }
  return 1;
}

int RCContactStoreMarkSeen(RCContactStore *store,
                           long long collectionIdentifier, const char *href,
                           long long runIdentifier, RCError *error)
{
  sqlite3_stmt *statement = NULL;
  int result;
  if (!RCPrepare(store,
      "UPDATE contacts SET seen_run_id=?, remote_missing=0 "
      "WHERE collection_id=? AND href=?", &statement, error)) return 0;
  sqlite3_bind_int64(statement, 1, runIdentifier);
  sqlite3_bind_int64(statement, 2, collectionIdentifier);
  RCBindText(statement, 3, href);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  return result == SQLITE_DONE ? 1 :
      RCStoreError(store, error, "Could not mark contact as seen");
}

static int RCInsertProperties(RCContactStore *store, long long contactIdentifier,
                              const RCVCardDocument *document, RCError *error)
{
  sqlite3_stmt *propertyStatement = NULL;
  sqlite3_stmt *parameterStatement = NULL;
  sqlite3_stmt *partStatement = NULL;
  size_t propertyIndex;
  int success = 0;

  if (!RCPrepare(store,
      "INSERT INTO contact_properties(contact_id, position, group_name, "
      "property_name, decoded_value, original_value, value_type) "
      "VALUES(?, ?, ?, ?, ?, ?, ?)", &propertyStatement, error) ||
      !RCPrepare(store,
      "INSERT INTO contact_parameters(property_id, position, parameter_name, "
      "parameter_value) VALUES(?, ?, ?, ?)", &parameterStatement, error) ||
      !RCPrepare(store,
      "INSERT INTO contact_value_parts(property_id, component, position, "
      "decoded_value) VALUES(?, ?, ?, ?)", &partStatement, error)) goto finished;

  for (propertyIndex = 0; propertyIndex < document->propertyCount;
       propertyIndex++) {
    const RCVCardProperty *property = &document->properties[propertyIndex];
    long long propertyIdentifier;
    size_t index;
    sqlite3_bind_int64(propertyStatement, 1, contactIdentifier);
    sqlite3_bind_int(propertyStatement, 2, property->position);
    RCBindText(propertyStatement, 3, property->group);
    RCBindText(propertyStatement, 4, property->name);
    RCBindText(propertyStatement, 5, property->decodedValue);
    RCBindText(propertyStatement, 6, property->originalValue);
    RCBindText(propertyStatement, 7, property->valueType);
    if (sqlite3_step(propertyStatement) != SQLITE_DONE) goto database_error;
    propertyIdentifier = sqlite3_last_insert_rowid(store->database);
    sqlite3_reset(propertyStatement);
    sqlite3_clear_bindings(propertyStatement);

    for (index = 0; index < property->parameterCount; index++) {
      const RCVCardParameter *parameter = &property->parameters[index];
      sqlite3_bind_int64(parameterStatement, 1, propertyIdentifier);
      sqlite3_bind_int(parameterStatement, 2, parameter->position);
      RCBindText(parameterStatement, 3, parameter->name);
      RCBindText(parameterStatement, 4, parameter->value);
      if (sqlite3_step(parameterStatement) != SQLITE_DONE) goto database_error;
      sqlite3_reset(parameterStatement);
      sqlite3_clear_bindings(parameterStatement);
    }
    for (index = 0; index < property->partCount; index++) {
      const RCVCardValuePart *part = &property->parts[index];
      sqlite3_bind_int64(partStatement, 1, propertyIdentifier);
      sqlite3_bind_int(partStatement, 2, part->component);
      sqlite3_bind_int(partStatement, 3, part->position);
      RCBindText(partStatement, 4, part->value);
      if (sqlite3_step(partStatement) != SQLITE_DONE) goto database_error;
      sqlite3_reset(partStatement);
      sqlite3_clear_bindings(partStatement);
    }
  }
  success = 1;
  goto finished;

database_error:
  RCStoreError(store, error, "Could not store parsed vCard property");
finished:
  sqlite3_finalize(propertyStatement);
  sqlite3_finalize(parameterStatement);
  sqlite3_finalize(partStatement);
  return success;
}

int RCContactStoreSaveVCard(RCContactStore *store,
                            long long collectionIdentifier,
                            long long runIdentifier, const char *href,
                            const char *etag, const unsigned char *rawVCard,
                            size_t rawVCardLength,
                            const RCVCardDocument *document, RCError *error)
{
  sqlite3_stmt *statement = NULL;
  long long contactIdentifier = 0;
  int result;
  int success = 0;

  if (!RCExecute(store, "BEGIN IMMEDIATE", error)) return 0;
  if (!RCPrepare(store,
      "INSERT OR IGNORE INTO contacts(collection_id, href, raw_vcard, seen_run_id) "
      "VALUES(?, ?, ?, ?)", &statement, error)) goto finished;
  sqlite3_bind_int64(statement, 1, collectionIdentifier);
  RCBindText(statement, 2, href);
  sqlite3_bind_blob(statement, 3, rawVCard, (int)rawVCardLength, SQLITE_TRANSIENT);
  sqlite3_bind_int64(statement, 4, runIdentifier);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  statement = NULL;
  if (result != SQLITE_DONE) {
    RCStoreError(store, error, "Could not create contact row");
    goto finished;
  }
  if (!RCPrepare(store,
      "UPDATE contacts SET uid=?, etag=?, vcard_version=?, formatted_name=?, "
      "given_name=?, family_name=?, organization=?, title=?, birthday=?, "
      "raw_vcard=?, seen_run_id=?, remote_missing=0 "
      "WHERE collection_id=? AND href=?", &statement, error)) goto finished;
  RCBindText(statement, 1, document->uid);
  RCBindText(statement, 2, etag);
  RCBindText(statement, 3, document->version);
  RCBindText(statement, 4, document->formattedName);
  RCBindText(statement, 5, document->givenName);
  RCBindText(statement, 6, document->familyName);
  RCBindText(statement, 7, document->organization);
  RCBindText(statement, 8, document->title);
  RCBindText(statement, 9, document->birthday);
  sqlite3_bind_blob(statement, 10, rawVCard, (int)rawVCardLength, SQLITE_TRANSIENT);
  sqlite3_bind_int64(statement, 11, runIdentifier);
  sqlite3_bind_int64(statement, 12, collectionIdentifier);
  RCBindText(statement, 13, href);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  statement = NULL;
  if (result != SQLITE_DONE) {
    RCStoreError(store, error, "Could not update contact row");
    goto finished;
  }
  if (!RCPrepare(store,
      "SELECT id FROM contacts WHERE collection_id=? AND href=?", &statement,
      error)) goto finished;
  sqlite3_bind_int64(statement, 1, collectionIdentifier);
  RCBindText(statement, 2, href);
  if (sqlite3_step(statement) != SQLITE_ROW) {
    RCStoreError(store, error, "Could not locate stored contact");
    goto finished;
  }
  contactIdentifier = sqlite3_column_int64(statement, 0);
  sqlite3_finalize(statement);
  statement = NULL;
  if (!RCPrepare(store, "DELETE FROM contact_properties WHERE contact_id=?",
                 &statement, error)) goto finished;
  sqlite3_bind_int64(statement, 1, contactIdentifier);
  if (sqlite3_step(statement) != SQLITE_DONE) {
    RCStoreError(store, error, "Could not replace parsed contact properties");
    goto finished;
  }
  sqlite3_finalize(statement);
  statement = NULL;
  if (!RCInsertProperties(store, contactIdentifier, document, error)) goto finished;
  success = RCExecute(store, "COMMIT", error);
  return success;

finished:
  sqlite3_finalize(statement);
  RCExecute(store, "ROLLBACK", NULL);
  return 0;
}

int RCContactStoreFinishCollection(RCContactStore *store,
                                   long long collectionIdentifier,
                                   long long runIdentifier, RCError *error)
{
  sqlite3_stmt *statement = NULL;
  int result;
  if (!RCExecute(store, "BEGIN IMMEDIATE", error)) return 0;
  if (!RCPrepare(store,
      "UPDATE contacts SET remote_missing=CASE WHEN seen_run_id=? THEN 0 ELSE 1 END "
      "WHERE collection_id=?", &statement, error)) goto failed;
  sqlite3_bind_int64(statement, 1, runIdentifier);
  sqlite3_bind_int64(statement, 2, collectionIdentifier);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  statement = NULL;
  if (result != SQLITE_DONE || !RCPrepare(store,
      "UPDATE collections SET last_complete_run_id=? WHERE id=?", &statement,
      error)) goto failed;
  sqlite3_bind_int64(statement, 1, runIdentifier);
  sqlite3_bind_int64(statement, 2, collectionIdentifier);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  if (result != SQLITE_DONE) goto failed_no_statement;
  return RCExecute(store, "COMMIT", error);

failed:
  sqlite3_finalize(statement);
failed_no_statement:
  if (error != NULL && error->code == 0) {
    RCStoreError(store, error, "Could not finish collection inventory");
  }
  RCExecute(store, "ROLLBACK", NULL);
  return 0;
}

int RCContactStoreFinishRun(RCContactStore *store, long long runIdentifier,
                            int succeeded, const char *message, RCError *error)
{
  sqlite3_stmt *statement = NULL;
  int result;
  if (!RCPrepare(store,
      "UPDATE sync_runs SET finished_at=CURRENT_TIMESTAMP, succeeded=?, message=? "
      "WHERE id=?", &statement, error)) return 0;
  sqlite3_bind_int(statement, 1, succeeded ? 1 : 0);
  RCBindText(statement, 2, message);
  sqlite3_bind_int64(statement, 3, runIdentifier);
  result = sqlite3_step(statement);
  sqlite3_finalize(statement);
  return result == SQLITE_DONE ? 1 : RCStoreError(store, error,
                                                   "Could not finish sync run");
}

int RCContactStoreGetStatistics(RCContactStore *store,
                                RCContactStoreStatistics *statistics,
                                RCError *error)
{
  sqlite3_stmt *statement = NULL;
  int result;
  memset(statistics, 0, sizeof(*statistics));
  if (!RCPrepare(store,
      "SELECT COUNT(*), SUM(CASE WHEN remote_missing=0 THEN 1 ELSE 0 END), "
      "SUM(CASE WHEN remote_missing=1 THEN 1 ELSE 0 END) FROM contacts",
      &statement, error)) return 0;
  result = sqlite3_step(statement);
  if (result == SQLITE_ROW) {
    statistics->resourceCount = (long)sqlite3_column_int64(statement, 0);
    statistics->availableCount = (long)sqlite3_column_int64(statement, 1);
    statistics->missingCount = (long)sqlite3_column_int64(statement, 2);
  }
  sqlite3_finalize(statement);
  return result == SQLITE_ROW ? 1 : RCStoreError(store, error,
                                                  "Could not read statistics");
}
