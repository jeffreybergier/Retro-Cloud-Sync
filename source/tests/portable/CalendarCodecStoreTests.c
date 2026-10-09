#include "../fixtures/calendars/CalendarFixtures.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int testTimezoneTruncation(void)
{
  const char *starts[] = { "20100101T000000", "20160101T000000" };
  size_t i;
  for (i = 0; i < sizeof(starts) / sizeof(starts[0]); i++) {
    char body[512];
    icalcomponent *zone, *standard;
    icalproperty *property;
    int ok;
    snprintf(body, sizeof(body),
             "BEGIN:VTIMEZONE\r\nTZID:Fixture\r\nBEGIN:STANDARD\r\n"
             "DTSTART:%s\r\nTZNAME:Fixture\r\nTZOFFSETFROM:+0000\r\n"
             "TZOFFSETTO:+0000\r\nRRULE:FREQ=YEARLY\r\n"
             "END:STANDARD\r\nEND:VTIMEZONE\r\n", starts[i]);
    zone = icalparser_parse_string(body);
    if (!zone) return 0;
    /* Retain the last onset before the exclusive window close, either as
       RRULE UNTIL or as RDATE for a rule spanning only one year. */
    icaltimezone_truncate_vtimezone(zone, icaltime_null_time(),
                                   icaltime_from_string("20180101T000000Z"), 0);
    standard = icalcomponent_get_first_component(zone, ICAL_XSTANDARD_COMPONENT);
    property = standard ? icalcomponent_get_first_property(
      standard, i ? ICAL_RDATE_PROPERTY : ICAL_RRULE_PROPERTY) : NULL;
    ok = property && !icaltime_compare(
      i ? icalproperty_get_rdate(property).time : icalproperty_get_rrule(property).until,
      icaltime_from_string("20170101T000000Z"));
    if (i && standard && icalcomponent_get_first_property(standard, ICAL_RRULE_PROPERTY))
      ok = 0;
    icalcomponent_free(zone);
    if (!ok) return 0;
  }
  return 1;
}

static long long scalar(RCCalendarStore *s, const char *sql)
{
  sqlite3_stmt *q = NULL;
  long long n = -1;
  if (sqlite3_prepare_v2(s->db, sql, -1, &q, NULL) == SQLITE_OK &&
      sqlite3_step(q) == SQLITE_ROW)
    n = sqlite3_column_int64(q, 0);
  sqlite3_finalize(q);
  return n;
}
static int save(RCCalendarStore *s, long long c, const char *href, const char *etag,
                const char *body, RCError *e)
{
  return RCCalendarStoreSave(s, c, href, etag, (const unsigned char *)body,
                             strlen(body), e);
}
#define CHECK(x)                                                                       \
  do {                                                                                 \
    if (!(x)) {                                                                        \
      fprintf(stderr, "Calendar test failed at line %d: %s\n", __LINE__,               \
              error.message);                                                          \
      goto done;                                                                       \
    }                                                                                  \
  } while (0)
int main(void)
{
  char path[] = "/tmp/rc-calendar-test-XXXXXX";
  RCCalendarStore *s = NULL;
  RCError error;
  long long c;
  int fd, ok = 0, current;
  char *first = NULL, *again = NULL;
  RCDAVCollection collection = {"https://example.test/cal/", "RCS Calendar Test", NULL,
                                NULL, NULL, 0};
  RCErrorClear(&error);
  CHECK(testTimezoneTruncation());
  /* Only empty URLs with valid supported parameters are tolerated; unrelated parser errors still fail. */
  {
    const char *valid = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:empty-url\r\nDTSTART:20300620T090000Z\r\nurl:\r\nuRl;vAlUe=uRi:\r\nURL:https://example.test/keep\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const char *invalid = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:bad-date\r\nURL:\r\nDTSTART:not-a-date\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    const char *folded = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:folded\nDTSTART:20300620T090000Z\nURL:\n https://example.test/folded\nEND:VEVENT\nEND:VCALENDAR\n";
    const char *invalidURL = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:bad-url\r\nDTSTART:20300620T090000Z\r\nURL;VALUE=DATE:\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    icalcomponent *root = RCICalendarParse((const unsigned char *)valid, strlen(valid), &error);
    CHECK(root);
    CHECK(!strcmp(RCICalendarValue(icalcomponent_get_first_component(root, ICAL_VEVENT_COMPONENT), ICAL_URL_PROPERTY), "https://example.test/keep"));
    icalcomponent_free(root);
    CHECK(!RCICalendarParse((const unsigned char *)invalid, strlen(invalid), &error));
    CHECK(!RCICalendarParse((const unsigned char *)invalidURL, strlen(invalidURL), &error));
    root = RCICalendarParse((const unsigned char *)folded, strlen(folded), &error);
    CHECK(root);
    CHECK(!strcmp(RCICalendarValue(icalcomponent_get_first_component(root, ICAL_VEVENT_COMPONENT), ICAL_URL_PROPERTY), "https://example.test/folded"));
    icalcomponent_free(root);
  }
  /* Empty categories do not invalidate an event or alter its original bytes.
     Preserve real categories, including folded values, and reject bad dates. */
  {
    const char *properties[] = {
      "CATEGORIES:\r\n", "categories:\n", "CATEGORIES:Work\r\n",
      "CATEGORIES:\r\n Work\r\n", "CATEGORIES:\n\tWork\n"
    };
    unsigned int i;
    for (i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
      char input[512], original[512];
      icalcomponent *root, *event;
      const char *categories;
      snprintf(input, sizeof(input),
          "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n"
          "UID:empty-categories\r\nDTSTART:20241218T094500Z\r\n%s"
          "END:VEVENT\r\nEND:VCALENDAR\r\n", properties[i]);
      strcpy(original, input);
      root = RCICalendarParse((const unsigned char *)input, strlen(input), &error);
      CHECK(root);
      CHECK(!strcmp(input, original));
      event = icalcomponent_get_first_component(root, ICAL_VEVENT_COMPONENT);
      categories = RCICalendarValue(event, ICAL_CATEGORIES_PROPERTY);
      CHECK(i < 2 ? categories == NULL : categories && !strcmp(categories, "Work"));
      icalcomponent_free(root);
    }
    {
      const char *invalid = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
          "BEGIN:VEVENT\r\nUID:bad-date\r\nCATEGORIES:\r\n"
          "DTSTART:not-a-date\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
      CHECK(!RCICalendarParse((const unsigned char *)invalid, strlen(invalid), &error));
    }
  }
  fd = mkstemp(path);
  if (fd < 0)
    return 1;
  close(fd);
  /* Upgrade an actual v2 resource table without rebuilding resource identities. */
  {
    sqlite3 *legacy = NULL;
    int status = sqlite3_open(path, &legacy);
    if (status == SQLITE_OK) status = sqlite3_exec(legacy,
        "CREATE TABLE schema_version(version INTEGER NOT NULL);INSERT INTO schema_version VALUES(2);"
        "CREATE TABLE calendar_resources(id INTEGER PRIMARY KEY,calendar_id INTEGER NOT NULL REFERENCES calendars(id),"
        "href TEXT NOT NULL,uid TEXT,etag TEXT,raw_ical BLOB NOT NULL,export_ical BLOB,export_etag TEXT,"
        "parse_error TEXT,export_error TEXT,export_status TEXT NOT NULL DEFAULT 'pending',seen_run INTEGER,"
        "remote_missing INTEGER NOT NULL DEFAULT 0,UNIQUE(calendar_id,href));"
        "INSERT INTO calendar_resources(id,calendar_id,href,uid,raw_ical) VALUES(4242,1,'legacy','legacy',X'010203')",
        NULL, NULL, NULL);
    sqlite3_close(legacy);
    CHECK(status == SQLITE_OK);
  }
  s = RCCalendarStoreOpen(path, "calendar-test", &error);
  CHECK(s);
  CHECK(scalar(s, "SELECT version FROM schema_version") == 3);
  CHECK(scalar(s, "SELECT length(raw_ical) FROM calendar_resources WHERE id=4242 AND scope_excluded=0") == 3);
  CHECK(RCCalendarStoreSQL(s, &error, "DELETE FROM calendar_resources WHERE id=4242"));
  CHECK(RCCalendarFixturePopulate(s, "initial", &error));
  CHECK(scalar(s, "SELECT count(*) FROM events") == 5);
  CHECK(scalar(s, "SELECT count(*) FROM alarms") == 1);
  CHECK(
      scalar(s,
             "SELECT count(*) FROM attendees WHERE participation_status='ACCEPTED'") ==
      1);
  CHECK(scalar(s, "SELECT count(*) FROM timezones") == 1);
  CHECK(
      scalar(s,
             "SELECT count(*) FROM events WHERE start_value='2040-06-08T13:00:00Z'") ==
      1);
  CHECK(scalar(s, "SELECT count(*) FROM ical_properties WHERE name='X-RCS-UNKNOWN'") ==
        1);
  first = RCCalendarStoreIdentity(s, "test-owner", "test-key", &error);
  CHECK(first);
  CHECK(RCCalendarFixturePopulate(s, "updated", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 4);
  CHECK(scalar(s, "SELECT count(*) FROM available_events WHERE summary='RCS Calendar "
                  "Test Edited'") == 1);
  again = RCCalendarStoreIdentity(s, "test-owner", "test-key", &error);
  CHECK(again && !strcmp(first, again));
  free(again);
  again = NULL;
  /* A failed complete run rolls back bodies and absence together. */
  CHECK(RCCalendarStoreBeginRun(s, &error));
  CHECK(RCCalendarStoreCollection(s, &collection, &c, &error));
  CHECK(save(s, c, "https://example.test/cal/day.ics", "bad",
             "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n", &error));
  CHECK(!RCCalendarStoreFinishRun(s, 0, "simulated interruption", &error));
  CHECK(
      scalar(s,
             "SELECT count(*) FROM calendar_resources WHERE parse_error IS NOT NULL") ==
      0);
  /* Successfully downloaded malformed data is retained; prior normalized data
     remains explicitly marked stale, and other resource presence is preserved. */
  CHECK(RCCalendarStoreBeginRun(s, &error));
  CHECK(RCCalendarStoreCollection(s, &collection, &c, &error));
  CHECK(save(s, c, "https://example.test/cal/day.ics", "bad",
             "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n", &error));
  CHECK(RCCalendarStoreSeen(s, c, "https://example.test/cal/series.ics", "updated",
                            &current, &error) &&
        current);
  CHECK(RCCalendarStoreSeen(s, c, "https://example.test/cal/zone.ics", "one", &current,
                            &error) &&
        current);
  CHECK(RCCalendarStoreFinishRun(s, 1, NULL, &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 4);
  CHECK(
      scalar(s,
             "SELECT count(*) FROM calendar_resources WHERE parse_error IS NOT NULL") ==
      1);
  RCCalendarStoreClose(s);
  s = RCCalendarStoreOpen(path, "calendar-test", &error);
  CHECK(s);
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 4);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources WHERE parse_error IS NOT NULL") == 1);
  CHECK(RCCalendarFixturePopulate(s, "empty", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 0);
  CHECK(scalar(s, "SELECT count(*) FROM calendars WHERE remote_missing=1") == 1);
  CHECK(RCCalendarFixturePopulate(s, "initial", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 5);
  /* Simulate the old codec's rejection; reopening repairs only normalization.
     Raw bytes, ETags, generation, presence, and stable resource IDs survive. */
  CHECK(RCCalendarStoreSQL(s, &error,
      "UPDATE calendar_resources SET parse_error='iCalendar contains invalid properties or values',"
      "export_status='unsupported',export_error='old parser' WHERE href='https://example.test/cal/day.ics';"
      "DELETE FROM ical_components WHERE resource_id IN (SELECT id FROM calendar_resources WHERE href='https://example.test/cal/day.ics');"
      "CREATE TABLE reparse_baseline AS SELECT r.id,r.raw_ical,r.etag,r.seen_run,a.generation "
      "FROM calendar_resources r JOIN calendars c ON c.id=r.calendar_id JOIN accounts a ON a.id=c.account_id"));
  RCCalendarStoreClose(s);
  s = RCCalendarStoreOpen(path, "calendar-test", &error);
  CHECK(s);
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 5);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources WHERE parse_error IS NOT NULL") == 0);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources r JOIN reparse_baseline b ON b.id=r.id JOIN calendars c ON c.id=r.calendar_id JOIN accounts a ON a.id=c.account_id WHERE r.raw_ical=b.raw_ical AND r.etag=b.etag AND r.seen_run IS b.seen_run AND a.generation=b.generation") == 4);
  CHECK(scalar(s, "SELECT count(*) FROM calendar_resources WHERE instr(CAST(raw_ical AS TEXT),'URL;VALUE=URI:')>0") == 1);
  RCCalendarStoreClose(s);
  s = RCCalendarStoreOpen(path, "second-account", &error);
  CHECK(s);
  CHECK(RCCalendarFixturePopulate(s, "empty", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 5);
  CHECK(scalar(s, "SELECT count(*) FROM accounts") == 2);
  ok = 1;
  puts("Calendar codec/store tests passed.");
done:
  free(first);
  free(again);
  RCCalendarStoreClose(s);
  unlink(path);
  return ok ? 0 : 1;
}
