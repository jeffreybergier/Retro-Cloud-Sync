#include "RCCalendarStore.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int RCCalendarStoreSQL(RCCalendarStore *s, RCError *error, const char *format, ...)
{
  va_list args;
  char *sql, *message = NULL;
  int result;
  va_start(args, format);
  sql = sqlite3_vmprintf(format, args);
  va_end(args);
  if (!sql) {
    RCErrorSet(error, 1, "Out of memory constructing calendar SQL");
    return 0;
  }
  result = sqlite3_exec(s->db, sql, NULL, NULL, &message);
  sqlite3_free(sql);
  if (result != SQLITE_OK)
    RCErrorSet(error, result, "Calendar database: %s",
               message ? message : sqlite3_errmsg(s->db));
  sqlite3_free(message);
  return result == SQLITE_OK;
}
static long long RCScalar(RCCalendarStore *s, const char *sql)
{
  sqlite3_stmt *q = NULL;
  long long value = -1;
  if (sqlite3_prepare_v2(s->db, sql, -1, &q, NULL) == SQLITE_OK &&
      sqlite3_step(q) == SQLITE_ROW)
    value = sqlite3_column_int64(q, 0);
  sqlite3_finalize(q);
  return value;
}
static long long RCFind(RCCalendarStore *s, const char *format, ...)
{
  va_list args;
  char *sql;
  long long value;
  va_start(args, format);
  sql = sqlite3_vmprintf(format, args);
  va_end(args);
  if (!sql)
    return -1;
  value = RCScalar(s, sql);
  sqlite3_free(sql);
  return value;
}
static const char schema[] =
    "CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);"
    "INSERT INTO schema_version SELECT 3 WHERE NOT EXISTS(SELECT 1 FROM "
    "schema_version);"
    "CREATE TABLE IF NOT EXISTS accounts(id INTEGER PRIMARY KEY,username TEXT UNIQUE "
    "NOT NULL,sync_id TEXT NOT NULL,generation INTEGER NOT NULL DEFAULT "
    "0,published_generation INTEGER NOT NULL DEFAULT 0);"
    "CREATE TABLE IF NOT EXISTS sync_runs(id INTEGER PRIMARY KEY,account_id INTEGER "
    "NOT NULL REFERENCES accounts(id),started_at TEXT DEFAULT "
    "CURRENT_TIMESTAMP,finished_at TEXT,succeeded INTEGER,message TEXT);"
    "CREATE TABLE IF NOT EXISTS calendars(id INTEGER PRIMARY KEY,account_id INTEGER "
    "NOT NULL REFERENCES accounts(id),url TEXT NOT NULL,display_name TEXT,description "
    "TEXT,color TEXT,sync_id TEXT NOT NULL,seen_run INTEGER,remote_missing INTEGER NOT "
    "NULL DEFAULT 0,UNIQUE(account_id,url));"
    "CREATE TABLE IF NOT EXISTS calendar_resources(id INTEGER PRIMARY KEY,calendar_id "
    "INTEGER NOT NULL REFERENCES calendars(id),href TEXT NOT NULL,uid TEXT,etag "
    "TEXT,raw_ical BLOB NOT NULL,export_ical BLOB,export_etag TEXT,parse_error TEXT,export_error "
    "TEXT,export_status TEXT NOT NULL DEFAULT 'pending',seen_run "
    "INTEGER,remote_missing INTEGER NOT NULL DEFAULT 0,"
    "scope_excluded INTEGER NOT NULL DEFAULT 0,UNIQUE(calendar_id,href));"
    "CREATE INDEX IF NOT EXISTS resource_uid ON calendar_resources(calendar_id,uid);"
    "CREATE TABLE IF NOT EXISTS sync_record_ids(owner TEXT NOT NULL,object_key TEXT "
    "NOT NULL,sync_id TEXT NOT NULL UNIQUE,PRIMARY KEY(owner,object_key));"
    "CREATE TABLE IF NOT EXISTS ical_components(id INTEGER PRIMARY KEY,resource_id "
    "INTEGER NOT NULL REFERENCES calendar_resources(id) ON DELETE CASCADE,parent_id "
    "INTEGER REFERENCES ical_components(id) ON DELETE CASCADE,kind TEXT NOT "
    "NULL,position INTEGER NOT NULL);"
    "CREATE TABLE IF NOT EXISTS ical_properties(id INTEGER PRIMARY KEY,component_id "
    "INTEGER NOT NULL REFERENCES ical_components(id) ON DELETE CASCADE,position "
    "INTEGER NOT NULL,name TEXT NOT NULL,value TEXT,value_type TEXT,ical_text TEXT);"
    "CREATE TABLE IF NOT EXISTS ical_parameters(id INTEGER PRIMARY KEY,property_id "
    "INTEGER NOT NULL REFERENCES ical_properties(id) ON DELETE CASCADE,position "
    "INTEGER NOT NULL,name TEXT NOT NULL,value TEXT);"
    "CREATE TABLE IF NOT EXISTS events(component_id INTEGER PRIMARY KEY REFERENCES "
    "ical_components(id) ON DELETE CASCADE,resource_id INTEGER NOT NULL REFERENCES "
    "calendar_resources(id),uid TEXT NOT NULL,recurrence_id TEXT NOT NULL,summary "
    "TEXT,description TEXT,location TEXT,url TEXT,status TEXT,classification "
    "TEXT,priority INTEGER,sequence INTEGER,start_value TEXT,start_kind "
    "TEXT,start_tzid TEXT,end_value TEXT,end_kind TEXT,end_tzid TEXT,duration "
    "TEXT,all_day INTEGER NOT NULL,UNIQUE(resource_id,recurrence_id));"
    "CREATE INDEX IF NOT EXISTS properties_component ON "
    "ical_properties(component_id,name);"
    "CREATE INDEX IF NOT EXISTS components_resource ON ical_components(resource_id);"
    "CREATE VIEW IF NOT EXISTS available_events AS SELECT c.display_name AS "
    "calendar_name,e.*,r.href,r.etag,r.parse_error,r.export_error,r.export_status FROM "
    "events e JOIN calendar_resources r ON r.id=e.resource_id JOIN calendars c ON "
    "c.id=r.calendar_id WHERE r.remote_missing=0 AND c.remote_missing=0 AND r.scope_excluded=0;"
    "CREATE VIEW IF NOT EXISTS recurrence_rules AS SELECT "
    "p.component_id,p.position,p.value AS rule FROM ical_properties p WHERE "
    "p.name='RRULE';"
    "CREATE VIEW IF NOT EXISTS recurrence_dates AS SELECT "
    "p.component_id,p.position,p.name AS kind,p.value FROM ical_properties p WHERE "
    "p.name IN ('RDATE','EXDATE','RECURRENCE-ID');"
    "CREATE VIEW IF NOT EXISTS attendees AS SELECT p.id,p.component_id,p.value AS "
    "address,(SELECT a.value FROM ical_parameters a WHERE a.property_id=p.id AND "
    "a.name='CN') AS common_name,(SELECT a.value FROM ical_parameters a WHERE "
    "a.property_id=p.id AND a.name='PARTSTAT') AS participation_status,(SELECT a.value "
    "FROM ical_parameters a WHERE a.property_id=p.id AND a.name='ROLE') AS role FROM "
    "ical_properties p WHERE p.name='ATTENDEE';"
    "CREATE VIEW IF NOT EXISTS organizers AS SELECT p.id,p.component_id,p.value AS "
    "address FROM ical_properties p WHERE p.name='ORGANIZER';"
    "CREATE VIEW IF NOT EXISTS alarms AS SELECT c.id,c.parent_id AS "
    "event_component_id,(SELECT p.value FROM ical_properties p WHERE "
    "p.component_id=c.id AND p.name='ACTION') AS action,(SELECT p.value FROM "
    "ical_properties p WHERE p.component_id=c.id AND p.name='TRIGGER') AS "
    "trigger_value,(SELECT p.value FROM ical_properties p WHERE p.component_id=c.id "
    "AND p.name='DESCRIPTION') AS description FROM ical_components c WHERE "
    "c.kind='VALARM';"
    "CREATE VIEW IF NOT EXISTS timezones AS SELECT c.id,c.resource_id,(SELECT p.value "
    "FROM ical_properties p WHERE p.component_id=c.id AND p.name='TZID') AS tzid FROM "
    "ical_components c WHERE c.kind='VTIMEZONE';"
    "CREATE VIEW IF NOT EXISTS timezone_observances AS SELECT * FROM ical_components "
    "WHERE kind IN ('STANDARD','DAYLIGHT');";

/* Retry cached parse failures after codec improvements, without fetching data
   or changing inventory/generation/remote write state. Failed retries leave the
   entire resource and its last good projection untouched. */
static int RCReparseCachedResources(RCCalendarStore *s, RCError *error)
{
  sqlite3_stmt *q = NULL;
  long long last = 0;
  int step;
  for (;;) {
    int ok, seenNull;
    icalcomponent *parsed;
    RCError parseError;
    long long resource, seen;
    if (sqlite3_prepare_v2(s->db,
        "SELECT r.id,r.calendar_id,r.href,r.etag,r.raw_ical,r.seen_run "
        "FROM calendar_resources r JOIN calendars c ON c.id=r.calendar_id "
        "WHERE c.account_id=? AND r.id>? AND r.parse_error IS NOT NULL "
        "AND c.remote_missing=0 AND r.remote_missing=0 AND r.scope_excluded=0 "
        "ORDER BY r.id LIMIT 1", -1, &q, NULL) != SQLITE_OK) goto failed;
    sqlite3_bind_int64(q, 1, s->account);
    sqlite3_bind_int64(q, 2, last);
    step = sqlite3_step(q);
    if (step == SQLITE_DONE) { sqlite3_finalize(q); return 1; }
    if (step != SQLITE_ROW) goto failed;
    resource = last = sqlite3_column_int64(q, 0);
    seen = sqlite3_column_int64(q, 5);
    seenNull = sqlite3_column_type(q, 5) == SQLITE_NULL;
    parsed = RCICalendarParse(sqlite3_column_blob(q, 4), (size_t)sqlite3_column_bytes(q, 4), &parseError);
    if (!parsed) { sqlite3_finalize(q); q = NULL; continue; }
    icalcomponent_free(parsed);
    if (!RCCalendarStoreSQL(s, error, "SAVEPOINT reparse_calendar")) goto failed;
    ok = RCCalendarStoreSave(s, sqlite3_column_int64(q, 1),
        (const char *)sqlite3_column_text(q, 2), (const char *)sqlite3_column_text(q, 3),
        sqlite3_column_blob(q, 4), (size_t)sqlite3_column_bytes(q, 4), error);
    sqlite3_finalize(q); q = NULL;
    if (!ok || RCFind(s, "SELECT id FROM calendar_resources WHERE id=%lld AND parse_error IS NULL", resource) < 0) {
      if (!RCCalendarStoreSQL(s, error, "ROLLBACK TO reparse_calendar;RELEASE reparse_calendar")) goto failed;
      if (!ok) goto failed;
    } else if (!RCCalendarStoreSQL(s, error,
        "UPDATE calendar_resources SET seen_run=CASE WHEN %d THEN NULL ELSE %lld END,export_error=NULL WHERE id=%lld;"
        "RELEASE reparse_calendar", seenNull, seen, resource)) goto failed;
  }
failed:
  sqlite3_finalize(q);
  RCCalendarStoreSQL(s, NULL, "ROLLBACK TO reparse_calendar;RELEASE reparse_calendar");
  if (!error || !error->code) RCErrorSet(error, 1, "Could not reparse cached calendar resources");
  return 0;
}

RCCalendarStore *RCCalendarStoreOpen(const char *path, const char *username,
                                     RCError *error)
{
  RCCalendarStore *s;
  RCErrorClear(error);
  if (!path || !username || !*username) {
    RCErrorSet(error, 1, "Calendar database account/path is missing");
    return NULL;
  }
  s = calloc(1, sizeof(*s));
  if (!s) {
    RCErrorSet(error, 1, "Out of memory opening calendar database");
    return NULL;
  }
  if (sqlite3_open_v2(path, &s->db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) !=
      SQLITE_OK) {
    RCErrorSet(error, 1, "Could not open calendar database");
    goto fail;
  }
  if (chmod(path, S_IRUSR | S_IWUSR) != 0) {
    RCErrorSet(error, 1, "Could not restrict calendar database permissions");
    goto fail;
  }
  sqlite3_busy_timeout(s->db, 5000);
  if (sqlite3_db_config(s->db, SQLITE_DBCONFIG_LEGACY_FILE_FORMAT, 1, NULL) !=
      SQLITE_OK) {
    RCErrorSet(error, 1, "Could not enable Tiger-compatible SQLite file format");
    goto fail;
  }
  if (!RCCalendarStoreSQL(s, error, "PRAGMA foreign_keys=ON") ||
      !RCCalendarStoreSQL(s, error, "%s", schema))
    goto fail;
  if (RCScalar(s, "SELECT version FROM schema_version") == 2) {
    /* Preserve existing cache and Sync Services identities when adding scope. */
    if (!RCCalendarStoreSQL(s, error,
        "BEGIN IMMEDIATE;ALTER TABLE calendar_resources ADD COLUMN "
        "scope_excluded INTEGER NOT NULL DEFAULT 0;"
        "DROP VIEW available_events;"
        "CREATE VIEW available_events AS SELECT c.display_name AS calendar_name,e.*,"
        "r.href,r.etag,r.parse_error,r.export_error,r.export_status FROM events e "
        "JOIN calendar_resources r ON r.id=e.resource_id JOIN calendars c ON c.id=r.calendar_id "
        "WHERE r.remote_missing=0 AND c.remote_missing=0 AND r.scope_excluded=0;"
        "UPDATE schema_version SET version=3;COMMIT")) {
      RCCalendarStoreSQL(s, NULL, "ROLLBACK");
      goto fail;
    }
  }
  if (RCScalar(s, "SELECT version FROM schema_version") != 3) {
    RCErrorSet(error, 1, "Unsupported calendar database version");
    goto fail;
  }
  if (!RCWriteJournalInitialize(s->db, error)) goto fail;
  if (!RCCalendarStoreSQL(s, error,
                          "INSERT OR IGNORE INTO accounts(username,sync_id) "
                          "VALUES(%Q,lower(hex(randomblob(16))))",
                          username))
    goto fail;
  s->account = RCFind(s, "SELECT id FROM accounts WHERE username=%Q", username);
  if (s->account < 0) {
    RCErrorSet(error, 1, "Could not find calendar account");
    goto fail;
  }
  if (!RCReparseCachedResources(s, error)) goto fail;
  return s;
fail:
  RCCalendarStoreClose(s);
  return NULL;
}

RCWriteJournal RCCalendarStoreWriteJournal(RCCalendarStore *s)
{
  RCWriteJournal journal;
  journal.db = s->db; journal.account = s->account; return journal;
}

int RCCalendarStoreSnapshotWriteBases(RCCalendarStore *s, long long generation, RCError *e)
{
  if (sqlite3_get_autocommit(s->db) || generation <= 0 || s->run ||
      RCFind(s, "SELECT generation FROM accounts WHERE id=%lld", s->account) != generation) {
    RCErrorSet(e, 1, "Calendar write bases require the publication transaction"); return 0;
  }
  return RCCalendarStoreSQL(s, e,
      "DELETE FROM write_bases WHERE account_id=%lld;"
      "INSERT INTO write_bases(account_id,resource_key,href,etag,body,local_revision) "
      "SELECT c.account_id,'resource-'||r.id,r.href,r.export_etag,r.export_ical,%lld "
      "FROM calendar_resources r JOIN calendars c ON c.id=r.calendar_id WHERE "
      "c.account_id=%lld AND c.remote_missing=0 AND r.remote_missing=0 "
      "AND r.scope_excluded=0 AND r.export_ical IS NOT NULL",
      s->account, generation, s->account);
}
void RCCalendarStoreClose(RCCalendarStore *s)
{
  if (!s)
    return;
  if (s->db) {
    if (s->run)
      sqlite3_exec(s->db, "ROLLBACK", NULL, NULL, NULL);
    sqlite3_close(s->db);
  }
  free(s);
}
int RCCalendarStoreBeginRun(RCCalendarStore *s, RCError *error)
{
  return RCCalendarStoreBeginScopedRun(s, 0, error);
}

int RCCalendarStoreBeginScopedRun(RCCalendarStore *s, int scoped, RCError *error)
{
  if (s->run) {
    RCErrorSet(error, 1, "Calendar fetch already active");
    return 0;
  }
  if (!RCCalendarStoreSQL(s, error, "INSERT INTO sync_runs(account_id) VALUES(%lld)",
                          s->account))
    return 0;
  s->run = sqlite3_last_insert_rowid(s->db);
  if (!RCCalendarStoreSQL(s, error, "BEGIN IMMEDIATE")) {
    s->run = 0;
    return 0;
  }
  s->scopedRun = scoped != 0;
  return 1;
}
int RCCalendarStoreCollection(RCCalendarStore *s, const RCDAVCollection *c,
                              long long *identifier, RCError *error)
{
  if (!RCCalendarStoreSQL(s, error,
                          "INSERT OR IGNORE INTO calendars(account_id,url,sync_id) "
                          "VALUES(%lld,%Q,lower(hex(randomblob(16))))",
                          s->account, c->url) ||
      !RCCalendarStoreSQL(s, error,
                          "UPDATE calendars SET "
                          "display_name=%Q,description=%Q,color=%Q,seen_run=%lld,"
                          "remote_missing=0 WHERE account_id=%lld AND url=%Q",
                          c->displayName ? c->displayName : "Calendar", c->description,
                          c->color, s->run, s->account, c->url))
    return 0;
  *identifier = RCFind(s, "SELECT id FROM calendars WHERE account_id=%lld AND url=%Q",
                       s->account, c->url);
  return *identifier > 0;
}
int RCCalendarStoreSeen(RCCalendarStore *s, long long calendar, const char *href,
                        const char *etag, int *current, RCError *error)
{
  *current = RCFind(s,
                    "SELECT COUNT(*) FROM calendar_resources WHERE calendar_id=%lld "
                    "AND href=%Q AND etag=%Q AND length(raw_ical)>0",
                    calendar, href, etag) == 1;
  if (!*current)
    return 1;
  return RCCalendarStoreSQL(
      s, error,
      "UPDATE calendar_resources SET seen_run=%lld,remote_missing=0,scope_excluded=0 WHERE "
      "calendar_id=%lld AND href=%Q",
      s->run, calendar, href);
}
static int RCStoreComponent(RCCalendarStore *s, long long resource, long long parent,
                            int position, icalcomponent *component, RCError *error)
{
  long long id;
  icalproperty *p;
  icalcomponent *child;
  int index = 0;
  if (!RCCalendarStoreSQL(
          s, error,
          "INSERT INTO ical_components(resource_id,parent_id,kind,position) "
          "VALUES(%lld,NULLIF(%lld,0),%Q,%d)",
          resource, parent, icalcomponent_kind_to_string(icalcomponent_isa(component)),
          position))
    return 0;
  id = sqlite3_last_insert_rowid(s->db);
  for (p = icalcomponent_get_first_property(component, ICAL_ANY_PROPERTY); p;
       p = icalcomponent_get_next_property(component, ICAL_ANY_PROPERTY)) {
    icalvalue *v = icalproperty_get_value(p);
    char *line = icalproperty_as_ical_string_r(p);
    const char *value = v && icalvalue_isa(v) == ICAL_TEXT_VALUE
                            ? icalvalue_get_text(v)
                            : icalproperty_get_value_as_string(p);
    icalparameter *param;
    int pi = 0;
    long long pid;
    int ok =
        RCCalendarStoreSQL(s, error,
                           "INSERT INTO "
                           "ical_properties(component_id,position,name,value,value_"
                           "type,ical_text) VALUES(%lld,%d,%Q,%Q,%Q,%Q)",
                           id, index++, icalproperty_get_property_name(p), value,
                           v ? icalvalue_kind_to_string(icalvalue_isa(v)) : NULL, line);
    free(line);
    if (!ok)
      return 0;
    pid = sqlite3_last_insert_rowid(s->db);
    for (param = icalproperty_get_first_parameter(p, ICAL_ANY_PARAMETER); param;
         param = icalproperty_get_next_parameter(p, ICAL_ANY_PARAMETER)) {
      char *text = icalparameter_as_ical_string_r(param),
           *eq = text ? strchr(text, '=') : NULL;
      if (!eq) {
        free(text);
        RCErrorSet(error, 1, "Invalid iCalendar parameter");
        return 0;
      }
      *eq++ = 0;
      ok = RCCalendarStoreSQL(
          s, error,
          "INSERT INTO ical_parameters(property_id,position,name,value) "
          "VALUES(%lld,%d,%Q,%Q)",
          pid, pi++, text, eq);
      free(text);
      if (!ok)
        return 0;
    }
  }
  if (icalcomponent_isa(component) == ICAL_VEVENT_COMPONENT) {
    char *key = RCICalendarRecurrenceKey(component);
    struct icaltimetype start = icalcomponent_get_dtstart(component),
                        end = icalcomponent_get_dtend(component);
    const char *stz = RCICalendarTZID(
        icalcomponent_get_first_property(component, ICAL_DTSTART_PROPERTY));
    const char *etz = RCICalendarTZID(
        icalcomponent_get_first_property(component, ICAL_DTEND_PROPERTY));
    char sb[32], eb[32];
    int ok;
    RCICalendarFormatTime(start, sb, sizeof(sb));
    RCICalendarFormatTime(end, eb, sizeof(eb));
    if (!key) {
      RCErrorSet(error, 1, "Out of memory saving event identity");
      return 0;
    }
    ok = RCCalendarStoreSQL(
        s, error,
        "INSERT INTO "
        "events(component_id,resource_id,uid,recurrence_id,summary,description,"
        "location,url,status,classification,priority,sequence,start_value,start_kind,"
        "start_tzid,end_value,end_kind,end_tzid,duration,all_day) "
        "VALUES(%lld,%lld,%Q,%Q,%Q,%Q,%Q,%Q,%Q,%Q,%d,%d,%Q,%Q,%Q,%Q,%Q,%Q,%Q,%d)",
        id, resource, RCICalendarValue(component, ICAL_UID_PROPERTY), key,
        RCICalendarValue(component, ICAL_SUMMARY_PROPERTY),
        RCICalendarValue(component, ICAL_DESCRIPTION_PROPERTY),
        RCICalendarValue(component, ICAL_LOCATION_PROPERTY),
        RCICalendarValue(component, ICAL_URL_PROPERTY),
        RCICalendarValue(component, ICAL_STATUS_PROPERTY),
        RCICalendarValue(component, ICAL_CLASS_PROPERTY),
        (RCICalendarValue(component, ICAL_PRIORITY_PROPERTY)
             ? atoi(RCICalendarValue(component, ICAL_PRIORITY_PROPERTY))
             : 0),
        icalcomponent_get_sequence(component), sb, RCICalendarTimeKind(start, stz), stz,
        eb, RCICalendarTimeKind(end, etz ? etz : stz), etz ? etz : stz,
        RCICalendarValue(component, ICAL_DURATION_PROPERTY), start.is_date);
    free(key);
    if (!ok)
      return 0;
  }
  index = 0;
  for (child = icalcomponent_get_first_component(component, ICAL_ANY_COMPONENT); child;
       child = icalcomponent_get_next_component(component, ICAL_ANY_COMPONENT))
    if (!RCStoreComponent(s, resource, id, index++, child, error))
      return 0;
  return 1;
}
int RCCalendarStoreSave(RCCalendarStore *s, long long calendar, const char *href,
                        const char *etag, const unsigned char *bytes, size_t length,
                        RCError *error)
{
  RCError parseError;
  icalcomponent *root = RCICalendarParse(bytes, length, &parseError), *child;
  const char *uid = NULL;
  long long resource =
      RCFind(s, "SELECT id FROM calendar_resources WHERE calendar_id=%lld AND href=%Q",
             calendar, href);
  sqlite3_stmt *q = NULL;
  int success = 0;
  if (root) {
    for (child = icalcomponent_get_first_component(root, ICAL_ANY_COMPONENT); child;
         child = icalcomponent_get_next_component(root, ICAL_ANY_COMPONENT)) {
      const char *next;
      if (icalcomponent_isa(child) == ICAL_VTIMEZONE_COMPONENT)
        continue;
      next = RCICalendarValue(child, ICAL_UID_PROPERTY);
      if (!next || (uid && strcmp(uid, next))) {
        RCErrorSet(&parseError, 1, "Calendar resource has missing or conflicting UIDs");
        break;
      }
      uid = next;
    }
    if (!uid || parseError.code) {
      icalcomponent_free(root);
      root = NULL;
      uid = NULL;
      if (!parseError.code)
        RCErrorSet(&parseError, 1, "Calendar resource contains no event or task");
    }
  }
  if (uid) {
    long long other = RCFind(s,
                             "SELECT id FROM calendar_resources WHERE calendar_id=%lld "
                             "AND uid=%Q AND id!=%lld AND remote_missing=0",
                             calendar, uid, resource);
    if (other > 0) {
      if (resource > 0 ||
          RCFind(s, "SELECT seen_run FROM calendar_resources WHERE id=%lld", other) ==
              s->run) {
        RCErrorSet(error, 1, "Duplicate calendar UID in remote inventory");
        goto done;
      }
      resource = other; /* unambiguous rename; a second appearance aborts the run */
    }
  }
  if (resource < 0) {
    if (!RCCalendarStoreSQL(s, error,
                            "INSERT INTO calendar_resources(calendar_id,href,raw_ical) "
                            "VALUES(%lld,%Q,X'')",
                            calendar, href))
      goto done;
    resource = sqlite3_last_insert_rowid(s->db);
  }
  if (sqlite3_prepare_v2(
          s->db,
          "UPDATE calendar_resources SET "
          "href=?,etag=?,raw_ical=?,parse_error=?,uid=COALESCE(?,uid),seen_run=?,"
          "remote_missing=0,scope_excluded=0,export_status='pending' WHERE id=?",
          -1, &q, NULL) != SQLITE_OK)
    goto sql_error;
  sqlite3_bind_text(q, 1, href, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(q, 2, etag, -1, SQLITE_TRANSIENT);
  sqlite3_bind_blob(q, 3, bytes, (int)length, SQLITE_TRANSIENT);
  if (!root)
    sqlite3_bind_text(q, 4, parseError.message, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(q, 5, uid, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(q, 6, s->run);
  sqlite3_bind_int64(q, 7, resource);
  if (sqlite3_step(q) != SQLITE_DONE)
    goto sql_error;
  sqlite3_finalize(q);
  q = NULL;
  if (root &&
      (!RCCalendarStoreSQL(
           s, error, "DELETE FROM ical_components WHERE resource_id=%lld", resource) ||
       !RCStoreComponent(s, resource, 0, 0, root, error)))
    goto done;
  success = 1;
  goto done;
sql_error:
  RCErrorSet(error, 1, "Could not save calendar resource: %s", sqlite3_errmsg(s->db));
done:
  sqlite3_finalize(q);
  if (root)
    icalcomponent_free(root);
  return success;
}
int RCCalendarStoreFinishRun(RCCalendarStore *s, int success, const char *message,
                             RCError *error)
{
  long long run = s->run;
  if (!run)
    return 0;
  if (success) {
    /* A time-range query cannot establish remote deletion. Keep that distinct
       from a resource leaving the selected scope, including after a narrower run. */
    success = RCCalendarStoreSQL(s, error,
        s->scopedRun ?
        "UPDATE calendar_resources SET scope_excluded=(seen_run IS NULL OR seen_run!=%lld) "
        "WHERE calendar_id IN(SELECT id FROM calendars WHERE account_id=%lld)" :
        "UPDATE calendar_resources SET scope_excluded=0,remote_missing=(seen_run IS NULL OR seen_run!=%lld) "
        "WHERE calendar_id IN(SELECT id FROM calendars WHERE account_id=%lld)",
        run, s->account);
    if (success)
      success = RCCalendarStoreSQL(
          s, error,
          "UPDATE calendars SET remote_missing=(seen_run IS NULL OR seen_run!=%lld) "
          "WHERE account_id=%lld;UPDATE accounts SET generation=%lld WHERE id=%lld",
          run, s->account, run, s->account);
    if (success)
      success = RCCalendarStoreSQL(s, error, "COMMIT");
  }
  if (!success)
    RCCalendarStoreSQL(s, NULL, "ROLLBACK");
  s->run = 0;
  s->scopedRun = 0;
  return RCCalendarStoreSQL(
             s, error,
             "UPDATE sync_runs SET "
             "finished_at=CURRENT_TIMESTAMP,succeeded=%d,message=%Q WHERE id=%lld",
             success, message, run) &&
         success;
}

int RCCalendarStorePruneHistory(RCCalendarStore *s, RCError *error)
{
  long long freePages, pages;
  if (s->run || !sqlite3_get_autocommit(s->db) ||
      RCFind(s, "SELECT count(*) FROM accounts WHERE id=%lld AND generation>0 "
                "AND published_generation=generation", s->account) != 1) {
    RCErrorSet(error, 1, "Calendar history cleanup requires a published inventory");
    return 0;
  }
  /* Retain small identity rows so widening the window reuses the same records.
     Never discard data needed by an outgoing operation awaiting resolution. */
  if (!RCCalendarStoreSQL(s, error,
      "BEGIN IMMEDIATE;"
      "CREATE TEMP TABLE IF NOT EXISTS calendar_prune_ids(id INTEGER PRIMARY KEY);"
      "DELETE FROM calendar_prune_ids;"
      "INSERT INTO calendar_prune_ids SELECT r.id FROM calendar_resources r "
      "JOIN calendars c ON c.id=r.calendar_id WHERE c.account_id=%lld AND r.scope_excluded=1 "
      "AND r.export_status!='outside history window' "
      "AND NOT EXISTS(SELECT 1 FROM write_operations w WHERE w.account_id=c.account_id "
      "AND (w.resource_key='resource-'||r.id OR w.href=r.href) "
      "AND w.state NOT IN ('acknowledged','cancelled'));"
      "DELETE FROM ical_components WHERE resource_id IN(SELECT id FROM calendar_prune_ids);"
      "DELETE FROM write_bases WHERE account_id=%lld AND resource_key IN "
      "(SELECT 'resource-'||id FROM calendar_prune_ids);"
      "UPDATE calendar_resources SET raw_ical=X'',export_ical=NULL,export_etag=NULL,etag=NULL,"
      "parse_error=NULL,export_error=NULL,export_status='outside history window' "
      "WHERE id IN(SELECT id FROM calendar_prune_ids);"
      "DROP TABLE calendar_prune_ids;COMMIT", s->account, s->account)) {
    RCCalendarStoreSQL(s, NULL, "ROLLBACK");
    return 0;
  }
  /* DELETE makes pages reusable but does not shrink the file. Avoid rewriting
     the database on every poll; compact only when significant space is free. */
  freePages = RCScalar(s, "PRAGMA freelist_count");
  pages = RCScalar(s, "PRAGMA page_count");
  if (freePages >= 256 && pages > 0 && freePages > pages / 5)
    return RCCalendarStoreSQL(s, error, "VACUUM");
  return 1;
}
char *RCCalendarStoreIdentity(RCCalendarStore *s, const char *owner, const char *key,
                              RCError *error)
{
  sqlite3_stmt *q = NULL;
  char *result = NULL;
  if (!RCCalendarStoreSQL(
          s, error,
          "INSERT OR IGNORE INTO sync_record_ids(owner,object_key,sync_id) "
          "VALUES(%Q,%Q,lower(hex(randomblob(16))))",
          owner, key))
    return NULL;
  if (sqlite3_prepare_v2(
          s->db, "SELECT sync_id FROM sync_record_ids WHERE owner=? AND object_key=?",
          -1, &q, NULL) == SQLITE_OK) {
    sqlite3_bind_text(q, 1, owner, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(q, 2, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(q) == SQLITE_ROW) {
      const char *v = (const char *)sqlite3_column_text(q, 0);
      if (v) {
        result = malloc(strlen(v) + 1);
        if (result)
          strcpy(result, v);
      }
    }
  }
  sqlite3_finalize(q);
  if (!result)
    RCErrorSet(error, 1, "Could not allocate calendar record identity");
  return result;
}
