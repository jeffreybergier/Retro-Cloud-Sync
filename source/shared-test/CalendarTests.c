#include "RCCalendarStore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char series[] =
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Retro Cloud Tests//EN\r\n"
    "BEGIN:VEVENT\r\nUID:rcs-test-series\r\nDTSTAMP:20260905T000000Z\r\n"
    "DTSTART:20300603T090000Z\r\nDTEND:20300603T100000Z\r\n"
    "SUMMARY:RCS Calendar Test Weekly\r\nRRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=5\r\n"
    "EXDATE:20300617T090000Z\r\nDESCRIPTION:Line one\\nLine two\r\n"
    "ATTENDEE;CN=Test "
    "Person;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT:mailto:person@example.test\r\n"
    "X-RCS-UNKNOWN;X-RCS-PARAM=preserve:original\\,value\r\n"
    "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nDESCRIPTION:Test "
    "reminder\r\nEND:VALARM\r\n"
    "END:VEVENT\r\nBEGIN:VEVENT\r\nUID:rcs-test-series\r\nDTSTAMP:20260905T000000Z\r\n"
    "RECURRENCE-ID:20300610T090000Z\r\nDTSTART:20300610T110000Z\r\nDTEND:"
    "20300610T120000Z\r\n"
    "SUMMARY:RCS Calendar Test Moved\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
static const char allDay[] =
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Retro Cloud Tests//EN\r\n"
    "BEGIN:VEVENT\r\nUID:rcs-test-allday\r\nDTSTAMP:20260905T000000Z\r\n"
    "DTSTART;VALUE=DATE:20300620\r\nDTEND;VALUE=DATE:20300622\r\nSUMMARY:RCS Calendar "
    "Test All Day\r\n"
    "END:VEVENT\r\nEND:VCALENDAR\r\n";
static const char single[] =
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Retro Cloud Tests//EN\r\n"
    "BEGIN:VEVENT\r\nUID:rcs-test-single\r\nDTSTAMP:20260905T000000Z\r\n"
    "DTSTART:20400608T130000Z\r\nDURATION:PT1H\r\nSUMMARY:RCS Calendar Test Single\r\n"
    "END:VEVENT\r\nEND:VCALENDAR\r\n";
static const char zoned[] =
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Retro Cloud Tests//EN\r\n"
    "BEGIN:VTIMEZONE\r\nTZID:Europe/London\r\n"
    "BEGIN:STANDARD\r\nDTSTART:19701025T020000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+"
    "0000\r\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\n"
    "BEGIN:DAYLIGHT\r\nDTSTART:19700329T010000\r\nTZOFFSETFROM:+0000\r\nTZOFFSETTO:+"
    "0100\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\nEND:"
    "VTIMEZONE\r\n"
    "BEGIN:VEVENT\r\nUID:rcs-test-zone\r\nDTSTAMP:20260905T000000Z\r\n"
    "DTSTART;TZID=Europe/London:20300325T090000\r\nDTEND;TZID=Europe/"
    "London:20300325T100000\r\n"
    "RRULE:FREQ=WEEKLY;COUNT=4\r\nSUMMARY:RCS Calendar Test "
    "DST\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
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
static int fixture(RCCalendarStore *s, const char *phase, RCError *e)
{
  RCDAVCollection c = {"https://example.test/cal/", "RCS Calendar Test", NULL,
                       "#112233FF"};
  long long id;
  int ok;
  char *changed = NULL;
  if (!RCCalendarStoreBeginRun(s, e))
    return 0;
  if (!strcmp(phase, "empty"))
    return RCCalendarStoreFinishRun(s, 1, NULL, e);
  if (!RCCalendarStoreCollection(s, &c, &id, e))
    goto fail;
  changed = malloc(strlen(series) + 1);
  if (!changed)
    goto fail;
  strcpy(changed, series);
  if (!strcmp(phase, "updated") || !strcmp(phase, "malformed") ||
      !strcmp(phase, "unsupported"))
    memcpy(strstr(changed, "Test Weekly"), "Test Edited", 11);
  if (!strcmp(phase, "unsupported"))
    memcpy(strstr(changed, "FREQ=WEEKLY") + 5, "HOURLY", 6);
  if (!strcmp(phase, "missing-uid")) {
    char *uid = strstr(changed, "UID:");
    char *next = strchr(uid, '\n') + 1;
    memmove(uid, next, strlen(next) + 1);
  }
  ok = save(s, id, "https://example.test/cal/series.ics", phase,
            !strcmp(phase, "malformed") ? "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n"
                                        : changed,
            e) &&
       save(s, id, "https://example.test/cal/day.ics", "one", allDay, e) &&
       save(s, id, "https://example.test/cal/zone.ics", "one", zoned, e);
  free(changed);
  changed = NULL;
  if (!ok)
    goto fail;
  if (!strcmp(phase, "initial") &&
      !save(s, id, "https://example.test/cal/single.ics", "one", single, e))
    goto fail;
  return RCCalendarStoreFinishRun(s, 1, NULL, e);
fail:
  free(changed);
  RCCalendarStoreFinishRun(s, 0, "fixture failure", NULL);
  return 0;
}
#define CHECK(x)                                                                       \
  do {                                                                                 \
    if (!(x)) {                                                                        \
      fprintf(stderr, "Calendar test failed at line %d: %s\n", __LINE__,               \
              error.message);                                                          \
      goto done;                                                                       \
    }                                                                                  \
  } while (0)
int main(int argc, char **argv)
{
  char path[] = "/tmp/rc-calendar-test-XXXXXX";
  RCCalendarStore *s = NULL;
  RCError error;
  long long c;
  int fd, ok = 0, current;
  char *first = NULL, *again = NULL;
  RCDAVCollection collection = {"https://example.test/cal/", "RCS Calendar Test", NULL,
                                NULL};
  if (argc == 3) {
    s = RCCalendarStoreOpen(argv[2], "calendar-test", &error);
    ok = s && fixture(s, argv[1], &error);
    if (!ok)
      fprintf(stderr, "Calendar fixture: %s\n", error.message);
    RCCalendarStoreClose(s);
    return ok ? 0 : 1;
  }
  fd = mkstemp(path);
  if (fd < 0)
    return 1;
  close(fd);
  s = RCCalendarStoreOpen(path, "calendar-test", &error);
  CHECK(s);
  CHECK(fixture(s, "initial", &error));
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
  CHECK(fixture(s, "updated", &error));
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
  CHECK(fixture(s, "empty", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 0);
  CHECK(scalar(s, "SELECT count(*) FROM calendars WHERE remote_missing=1") == 1);
  CHECK(fixture(s, "initial", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 5);
  RCCalendarStoreClose(s);
  s = RCCalendarStoreOpen(path, "second-account", &error);
  CHECK(s);
  CHECK(fixture(s, "empty", &error));
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
