#include "CalendarFixtures.h"
#include <stdlib.h>
#include <string.h>

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
    "Test All Day\r\nURL;VALUE=URI:\r\n"
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
static int save(RCCalendarStore *s, long long c, const char *href, const char *etag,
                const char *body, RCError *e)
{
  return RCCalendarStoreSave(s, c, href, etag, (const unsigned char *)body,
                             strlen(body), e);
}
int RCCalendarFixturePopulate(RCCalendarStore *s, const char *phase, RCError *e)
{
  RCDAVCollection c = {"https://example.test/cal/", "RCS Calendar Test", NULL,
                       "#112233FF", NULL, 0};
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
