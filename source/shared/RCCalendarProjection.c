#include "RCCalendarProjection.h"
#include <stdlib.h>
#include <string.h>

icaltimezone *RCCalendarSourceZone(icalcomponent *root, icalproperty *p)
{
  const char *tz=RCICalendarTZID(p);
  if(!tz) return NULL;
  icaltimezone *zone=icalcomponent_get_timezone(root,tz);
  if(!zone) zone=icaltimezone_get_builtin_timezone(tz);
  if(!zone || zone==icaltimezone_get_utc_timezone()) return zone;
  icalcomponent *definition=icaltimezone_get_component(zone), *part; int count=0;
  for(part=icalcomponent_get_first_component(definition,ICAL_ANY_COMPONENT);part;
      part=icalcomponent_get_next_component(definition,ICAL_ANY_COMPONENT)) {
    struct icaltimetype start=icalcomponent_get_dtstart(part);
    if(!icalcomponent_get_first_property(part,ICAL_TZOFFSETFROM_PROPERTY) ||
        !icalcomponent_get_first_property(part,ICAL_TZOFFSETTO_PROPERTY) ||
        icaltime_is_null_time(start) || !icaltime_is_valid_time(start)) return NULL;
    count++;
  }
  return count ? zone : NULL;
}
/* Gregorian civil days avoid host timezone, DST and 32-bit time_t limits. */
static long CivilDay(struct icaltimetype t)
{
  long y=t.year-1;
  return 365*y+y/4-y/100+y/400+icaltime_day_of_year(t);
}
int RCRecurrenceDay(struct icaltimetype start, struct icaltimetype date, int *day)
{
  long days;
  if(icaltime_is_null_time(date) || !icaltime_is_valid_time(date) ||
      !icaltime_is_valid_time(start) || start.is_date!=date.is_date ||
      start.hour!=date.hour || start.minute!=date.minute || start.second!=date.second) return 0;
  days=CivilDay(date)-CivilDay(start);
  if(days<0 || days>3660) return 0;
  *day=(int)days; return 1;
}
int RCExpandFiniteRecurrence(icalcomponent *event, RCError *error)
{
  if(!icalcomponent_count_properties(event,ICAL_RDATE_PROPERTY) &&
      !icalcomponent_count_properties(event,ICAL_EXRULE_PROPERTY)) return 1;
  icalproperty *basis=icalcomponent_get_first_property(event,ICAL_DTSTART_PROPERTY), *p;
  struct icaltimetype start=icalcomponent_get_dtstart(event);
  const char *tz=RCICalendarTZID(basis);
  unsigned char days[3661]={1};
  int last=0, day, budget=0;
  for(p=icalcomponent_get_first_property(event,ICAL_RDATE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_RDATE_PROPERTY)) {
    struct icaldatetimeperiodtype r=icalproperty_get_rdate(p); const char *rtz=RCICalendarTZID(p);
    if((tz || rtz) && (!tz || !rtz || strcmp(tz,rtz))) goto unsupported;
    if(icaltime_is_utc(start)!=icaltime_is_utc(r.time) || !RCRecurrenceDay(start,r.time,&day)) goto unsupported;
    days[day]=1; if(day>last) last=day;
  }
  for(p=icalcomponent_get_first_property(event,ICAL_RRULE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_RRULE_PROPERTY)) {
    struct icalrecurrencetype rule=icalproperty_get_rrule(p);
    if(!rule.count && icaltime_is_null_time(rule.until)) goto unsupported;
    icalrecur_iterator *it=icalrecur_iterator_new(rule,start); if(!it) goto unsupported;
    struct icaltimetype t;
    while(!icaltime_is_null_time(t=icalrecur_iterator_next(it))) {
      if(++budget>10000 || !RCRecurrenceDay(start,t,&day)) { icalrecur_iterator_free(it); goto unsupported; }
      days[day]=1; if(day>last) last=day;
    }
    icalrecur_iterator_free(it);
  }
  for(p=icalcomponent_get_first_property(event,ICAL_EXRULE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_EXRULE_PROPERTY)) {
    icalrecur_iterator *it=icalrecur_iterator_new(icalproperty_get_exrule(p),start); if(!it) goto unsupported;
    struct icaltimetype t, limit=start; icaltime_adjust(&limit,last,0,0,0);
    while(!icaltime_is_null_time(t=icalrecur_iterator_next(it)) && icaltime_compare(t,limit)<=0) {
      if(++budget>10000 || !RCRecurrenceDay(start,t,&day)) { icalrecur_iterator_free(it); goto unsupported; }
      days[day]=0;
    }
    icalrecur_iterator_free(it);
  }
  icalproperty_kind remove[]={ICAL_RRULE_PROPERTY,ICAL_RDATE_PROPERTY,ICAL_EXRULE_PROPERTY}; int k;
  for(k=0;k<3;k++) while((p=icalcomponent_get_first_property(event,remove[k]))) {
    icalcomponent_remove_property(event,p); icalproperty_free(p);
  }
  struct icalrecurrencetype rule=icalrecurrencetype_from_string("FREQ=DAILY"); rule.count=last+1;
  icalcomponent_add_property(event,icalproperty_new_rrule(rule));
  for(day=0;day<=last;day++) if(!days[day]) {
    struct icaltimetype t=start; icaltime_adjust(&t,day,0,0,0);
    p=icalproperty_new_exdate(t);
    if(tz) icalproperty_add_parameter(p,icalparameter_new_tzid(tz));
    icalcomponent_add_property(event,p);
  }
  return 1;
unsupported:
  RCErrorSet(error,1,"RDATE/EXRULE requires a finite set within ten years at the DTSTART wall time and timezone");
  return 0;
}

int RCSourceZoneIsFixed(icaltimezone *zone, int offset)
{
  icalcomponent *definition=icaltimezone_get_component(zone), *part;
  int count=0;
  for(part=icalcomponent_get_first_component(definition,ICAL_ANY_COMPONENT);part;
      part=icalcomponent_get_next_component(definition,ICAL_ANY_COMPONENT)) {
    icalproperty *from=icalcomponent_get_first_property(part,ICAL_TZOFFSETFROM_PROPERTY),
        *to=icalcomponent_get_first_property(part,ICAL_TZOFFSETTO_PROPERTY);
    if(!from || !to || icalproperty_get_tzoffsetfrom(from)!=offset || icalproperty_get_tzoffsetto(to)!=offset) return 0;
    count++;
  }
  return count>0;
}
int RCCalendarNeedsUTCProjection(icalcomponent *root, icalcomponent *event,
    RCCalendarNativeOffset nativeOffset, void *context)
{
  icalproperty *p=icalcomponent_get_first_property(event,ICAL_DTSTART_PROPERTY);
  struct icaltimetype start=icalcomponent_get_dtstart(event), t;
  icaltimezone *source;
  int dst=0, offset, native;
  if(start.is_date || !RCICalendarTZID(p) || !icalcomponent_count_properties(event,ICAL_RRULE_PROPERTY)) return 0;
  source=RCCalendarSourceZone(root,p); if(!source) return 0;
  offset=icaltimezone_get_utc_offset(source,&start,&dst);
  if(RCSourceZoneIsFixed(source,offset)) return 0;
  t=start; t.month=1; t.day=1; t.hour=12;
  while(t.year<=start.year+5) {
    struct icaltimetype utc=t;
    offset=icaltimezone_get_utc_offset(source,&t,&dst);
    icaltime_adjust(&utc,0,0,0,-offset); utc.zone=icaltimezone_get_utc_timezone();
    if(!nativeOffset || !nativeOffset(context,RCICalendarTZID(p),utc,&native) || native!=offset) return 1;
    icaltime_adjust(&t,1,0,0,0);
  }
  return 0;
}
static void RemoveProperties(icalcomponent *event,icalproperty_kind kind)
{
  icalproperty *p;
  while((p=icalcomponent_get_first_property(event,kind))) { icalcomponent_remove_property(event,p); icalproperty_free(p); }
}
static struct icaltimetype UTC(struct icaltimetype wall, int offset)
{
  icaltime_adjust(&wall,0,0,0,-offset); wall.zone=icaltimezone_get_utc_timezone(); return wall;
}
/* Exact bounded envelope and detached occurrences. No platform dates, system
   timezone database, network calls or native sessions are used here. */
static int ProjectTimezone(icalcomponent *root,icalcomponent *event,
    RCCalendarNativeOffset nativeOffset,void *context,RCError *error)
{
  icalcomponent *other, *alarm, *template=NULL;
  struct icaltimetype *occurrences=NULL;
  if(!RCCalendarNeedsUTCProjection(root,event,nativeOffset,context)) return 1;
  for(other=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);other;
      other=icalcomponent_get_next_component(root,ICAL_VEVENT_COMPONENT))
    if(icalcomponent_count_properties(other,ICAL_RECURRENCEID_PROPERTY)) goto unsupported;
  for(alarm=icalcomponent_get_first_component(event,ICAL_VALARM_COMPONENT);alarm;
      alarm=icalcomponent_get_next_component(event,ICAL_VALARM_COMPONENT)) {
    icalproperty *trigger=icalcomponent_get_first_property(alarm,ICAL_TRIGGER_PROPERTY);
    if(trigger && !icaltime_is_null_time(icalproperty_get_trigger(trigger).time)) goto unsupported;
  }
  icalproperty *basis=icalcomponent_get_first_property(event,ICAL_DTSTART_PROPERTY),
      *ruleProperty=icalcomponent_get_first_property(event,ICAL_RRULE_PROPERTY), *p;
  icaltimezone *zone=RCCalendarSourceZone(root,basis);
  struct icaltimetype start=icalcomponent_get_dtstart(event);
  struct icalrecurrencetype rule=icalproperty_get_rrule(ruleProperty);
  if(icalcomponent_count_properties(event,ICAL_RRULE_PROPERTY)!=1 ||
      (!rule.count && icaltime_is_null_time(rule.until)) || start.year>2037) goto unsupported;
  int dst=0, initialOffset=icaltimezone_get_utc_offset(zone,&start,&dst);
  struct icaltimetype first=UTC(start,initialOffset);
  struct icaldurationtype duration=icalcomponent_get_duration(event);
  int seconds=icaldurationtype_as_int(duration);
  if(icalcomponent_get_dtend(event).year>2037 || seconds<0 || seconds>86400 || icalcomponent_count_properties(event,ICAL_DURATION_PROPERTY)) goto unsupported;
  int last=0, day, budget=0;
  occurrences=calloc(3661,sizeof(*occurrences)); if(!occurrences) goto unsupported;
  icalrecur_iterator *it=icalrecur_iterator_new(rule,start); if(!it) goto unsupported;
  struct icaltimetype t;
  occurrences[0]=first;
  while(!icaltime_is_null_time(t=icalrecur_iterator_next(it))) {
    if(++budget>10000 || t.year>2037 || icaltime_add(t,duration).year>2037 || !RCRecurrenceDay(start,t,&day)) { icalrecur_iterator_free(it); goto unsupported; }
    int offset=icaltimezone_get_utc_offset(zone,&t,&dst);
    occurrences[day]=UTC(t,offset);
    if(day>last) last=day;
  }
  icalrecur_iterator_free(it);
  for(p=icalcomponent_get_first_property(event,ICAL_EXDATE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_EXDATE_PROPERTY)) {
    t=icalproperty_get_exdate(p);
    icaltimezone *from=icaltime_is_utc(t) ? icaltimezone_get_utc_timezone() : RCCalendarSourceZone(root,p);
    if(!from || t.is_date) goto unsupported;
    icaltimezone_convert_time(&t,from,zone);
    if(RCRecurrenceDay(start,t,&day)) occurrences[day]=icaltime_null_time();
  }
  template=icalcomponent_new_clone(event); if(!template) goto unsupported;
  icalproperty_kind remove[]={ICAL_RRULE_PROPERTY,ICAL_RDATE_PROPERTY,ICAL_EXRULE_PROPERTY,ICAL_EXDATE_PROPERTY,
      ICAL_DTSTART_PROPERTY,ICAL_DTEND_PROPERTY}; int k;
  for(k=0;k<6;k++) RemoveProperties(event,remove[k]);
  icalcomponent_add_property(event,icalproperty_new_dtstart(first));
  t=first; icaltime_adjust(&t,0,0,0,seconds);
  icalcomponent_add_property(event,icalproperty_new_dtend(t));
  rule=icalrecurrencetype_from_string("FREQ=DAILY"); rule.count=last+1;
  icalcomponent_add_property(event,icalproperty_new_rrule(rule));
  for(day=0;day<=last;day++) {
    struct icaltimetype baseline=first, actual=occurrences[day];
    icaltime_adjust(&baseline,day,0,0,0);
    if(icaltime_is_null_time(actual)) { icalcomponent_add_property(event,icalproperty_new_exdate(baseline)); continue; }
    if(!icaltime_compare(actual,baseline)) continue;
    icalcomponent *detached=icalcomponent_new_clone(template);
    if(!detached) goto unsupported;
    for(k=0;k<6;k++) RemoveProperties(detached,remove[k]);
    icalcomponent_add_property(detached,icalproperty_new_recurrenceid(baseline));
    icalcomponent_add_property(detached,icalproperty_new_dtstart(actual));
    icaltime_adjust(&actual,0,0,0,seconds);
    icalcomponent_add_property(detached,icalproperty_new_dtend(actual));
    icalcomponent_add_component(root,detached);
  }
  icalcomponent_free(template); free(occurrences); return 1;
unsupported:
  if(template) icalcomponent_free(template);
  free(occurrences);
  RCErrorSet(error,1,"Changed timezone rules require a finite series ending by 2037, spanning at most ten years, without existing detached instances, absolute reminders or DURATION");
  return 0;
}
int RCCalendarPrepareProjection(icalcomponent *root,RCCalendarNativeOffset nativeOffset,
    void *context,RCError *error)
{
  size_t count=icalcomponent_count_components(root,ICAL_VEVENT_COMPONENT), n=0;
  icalcomponent **events=count ? malloc(count*sizeof(*events)) : NULL, *event;
  if(count && !events) { RCErrorSet(error,1,"Could not allocate calendar projection"); return 0; }
  /* Snapshot originals: projection can append detached components to root. */
  for(event=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);event;
      event=icalcomponent_get_next_component(root,ICAL_VEVENT_COMPONENT)) events[n++]=event;
  for(n=0;n<count;n++) if(!RCExpandFiniteRecurrence(events[n],error)) { free(events); return 0; }
  for(n=0;n<count;n++) if(!ProjectTimezone(root,events[n],nativeOffset,context,error)) { free(events); return 0; }
  free(events); return 1;
}
