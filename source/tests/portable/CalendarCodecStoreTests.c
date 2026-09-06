#include "../fixtures/calendars/CalendarFixtures.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
                                NULL};
  fd = mkstemp(path);
  if (fd < 0)
    return 1;
  close(fd);
  s = RCCalendarStoreOpen(path, "calendar-test", &error);
  CHECK(s);
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
  CHECK(RCCalendarFixturePopulate(s, "empty", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 0);
  CHECK(scalar(s, "SELECT count(*) FROM calendars WHERE remote_missing=1") == 1);
  CHECK(RCCalendarFixturePopulate(s, "initial", &error));
  CHECK(scalar(s, "SELECT count(*) FROM available_events") == 5);
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
