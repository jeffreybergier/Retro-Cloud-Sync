#include "RCCalendarProjection.h"
#include "../fixtures/calendars/CalendarTimeFixtures.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s (%s)\n",__LINE__,#x,error.message); exit(1); } } while (0)
static RCError error;
static icalcomponent *Parse(const char *text)
{
  icalcomponent *root=RCICalendarParse((const unsigned char *)text,strlen(text),&error); CHECK(root); return root;
}
static int MatchingOffset(void *context,const char *name,struct icaltimetype utc,int *offset)
{
  icaltimezone *zone=icalcomponent_get_timezone(context,name); int dst=0;
  *offset=icaltimezone_get_utc_offset_of_utc_time(zone,&utc,&dst); return 1;
}
static void Dates(void)
{
  int day;
  CHECK(RCRecurrenceDay(icaltime_from_string("20240228T090000"),icaltime_from_string("20240301T090000"),&day) && day==2);
  CHECK(RCRecurrenceDay(icaltime_from_string("20991231T090000"),icaltime_from_string("21000301T090000"),&day) && day==60);
  CHECK(!RCRecurrenceDay(icaltime_from_string("20260301T090000"),icaltime_from_string("20260302T100000"),&day));
  CHECK(!RCRecurrenceDay(icaltime_from_string("20260301"),icaltime_from_string("20260228"),&day));
  CHECK(!RCRecurrenceDay(icaltime_from_string("20260301"),icaltime_from_string("20370301"),&day));
  icalcomponent *root=Parse(RC_TIME_DATES), *event=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);
  CHECK(RCCalendarPrepareProjection(root,NULL,NULL,&error));
  CHECK(!icalcomponent_count_properties(event,ICAL_RDATE_PROPERTY));
  CHECK(icalproperty_get_rrule(icalcomponent_get_first_property(event,ICAL_RRULE_PROPERTY)).count==6);
  int excluded[7]={0}; icalproperty *p;
  for(p=icalcomponent_get_first_property(event,ICAL_EXDATE_PROPERTY);p;p=icalcomponent_get_next_property(event,ICAL_EXDATE_PROPERTY)) {
    struct icaltimetype t=icalproperty_get_exdate(p); CHECK(t.day>=1 && t.day<=6); excluded[t.day]=1;
  }
  CHECK(!excluded[1] && excluded[2] && !excluded[3] && excluded[4] && excluded[5] && !excluded[6]);
  icalcomponent_free(root);
  root=Parse(RC_TIME_FLOAT); char *before=icalcomponent_as_ical_string_r(root);
  CHECK(RCCalendarPrepareProjection(root,NULL,NULL,&error));
  char *after=icalcomponent_as_ical_string_r(root); CHECK(!strcmp(before,after)); free(before); free(after); icalcomponent_free(root);
  root=Parse("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:finite\r\nDTSTART:20260301T090000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nEXRULE:FREQ=DAILY;INTERVAL=2;COUNT=3\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n");
  event=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);
  CHECK(RCCalendarPrepareProjection(root,NULL,NULL,&error));
  CHECK(!icalcomponent_count_properties(event,ICAL_EXRULE_PROPERTY) && icalcomponent_count_properties(event,ICAL_EXDATE_PROPERTY)==3);
  icalcomponent_free(root);
}
static void Timezones(void)
{
  icalcomponent *root=Parse(RC_TIME_CUSTOM), *event=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);
  CHECK(!RCCalendarNeedsUTCProjection(root,event,MatchingOffset,root));
  CHECK(RCCalendarNeedsUTCProjection(root,event,NULL,NULL));
  CHECK(RCCalendarPrepareProjection(root,NULL,NULL,&error));
  struct icaltimetype start=icalcomponent_get_dtstart(event);
  CHECK(icaltime_is_utc(start) && start.hour==7 && start.minute==30);
  CHECK(icalcomponent_count_components(root,ICAL_VEVENT_COMPONENT)>1);
  /* Check every occurrence against the original authoritative timezone, with
     detached instances replacing their envelope occurrence exactly once. */
  icalcomponent *original=Parse(RC_TIME_CUSTOM), *source=icalcomponent_get_first_component(original,ICAL_VEVENT_COMPONENT);
  icaltimezone *zone=icalcomponent_get_timezone(original,"Europe/London");
  icalrecur_iterator *it=icalrecur_iterator_new(icalproperty_get_rrule(icalcomponent_get_first_property(source,ICAL_RRULE_PROPERTY)),icalcomponent_get_dtstart(source));
  struct icaltimetype t; int count=0;
  while(!icaltime_is_null_time(t=icalrecur_iterator_next(it))) {
    int dst=0, offset=icaltimezone_get_utc_offset(zone,&t,&dst), day;
    CHECK(RCRecurrenceDay(icalcomponent_get_dtstart(source),t,&day));
    struct icaltimetype expected=t, envelope=start, actual;
    icaltime_adjust(&expected,0,0,0,-offset); expected.zone=icaltimezone_get_utc_timezone();
    icaltime_adjust(&envelope,day,0,0,0); actual=envelope;
    icalcomponent *detached;
    for(detached=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);detached;detached=icalcomponent_get_next_component(root,ICAL_VEVENT_COMPONENT)) {
      icalproperty *rid=icalcomponent_get_first_property(detached,ICAL_RECURRENCEID_PROPERTY);
      if(rid && !icaltime_compare(icalproperty_get_recurrenceid(rid),envelope)) actual=icalcomponent_get_dtstart(detached);
    }
    CHECK(!icaltime_compare(actual,expected)); count++;
  }
  CHECK(count==40); icalrecur_iterator_free(it); icalcomponent_free(original); icalcomponent_free(root);
  root=Parse(RC_TIME_CUSTOM); event=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);
  icalproperty *p=icalcomponent_get_first_property(event,ICAL_RRULE_PROPERTY);
  icalproperty_set_rrule(p,icalrecurrencetype_from_string("FREQ=WEEKLY"));
  CHECK(!RCCalendarPrepareProjection(root,NULL,NULL,&error));
  icalcomponent_free(root);
  root=Parse(RC_TIME_DATES); event=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);
  p=icalcomponent_get_first_property(event,ICAL_RDATE_PROPERTY);
  struct icaldatetimeperiodtype r=icalproperty_get_rdate(p); r.time.hour=10; icalproperty_set_rdate(p,r);
  CHECK(!RCCalendarPrepareProjection(root,NULL,NULL,&error)); icalcomponent_free(root);
}
int main(void) { Dates(); Timezones(); puts("Portable finite recurrence and authoritative timezone projection passed."); return 0; }
