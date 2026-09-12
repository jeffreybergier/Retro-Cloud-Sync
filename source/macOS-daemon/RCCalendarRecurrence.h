#ifndef RC_CALENDAR_RECURRENCE_H
#define RC_CALENDAR_RECURRENCE_H
#import "RCCalendarTime.h"
/* Exact projection of a finite set at a single wall-clock time. The raw DAV
   body is untouched: only the disposable parsed tree receives a daily rule
   with exclusions. Reverse mapping protects this synthesized structure. */
static inline BOOL RCRecurrenceDay(struct icaltimetype start, struct icaltimetype date, int *day)
{
  if(icaltime_is_null_time(date) || start.is_date!=date.is_date ||
      start.hour!=date.hour || start.minute!=date.minute || start.second!=date.second) return NO;
  NSTimeZone *utc=[NSTimeZone timeZoneForSecondsFromGMT:0];
  double days=[RCCalendarWallDate(date,utc) timeIntervalSinceDate:RCCalendarWallDate(start,utc)]/86400.0;
  if(days<0 || days>3660 || days!=(int)days) return NO;
  *day=(int)days; return YES;
}
static inline BOOL RCExpandFiniteRecurrence(icalcomponent *event, RCError *error)
{
  if(!icalcomponent_count_properties(event,ICAL_RDATE_PROPERTY) &&
      !icalcomponent_count_properties(event,ICAL_EXRULE_PROPERTY)) return YES;
  icalproperty *basis=icalcomponent_get_first_property(event,ICAL_DTSTART_PROPERTY), *p;
  struct icaltimetype start=icalcomponent_get_dtstart(event);
  const char *tz=RCICalendarTZID(basis);
  NSMutableSet *days=[NSMutableSet setWithObject:[NSNumber numberWithInt:0]];
  int last=0, day, budget=0;
  for(p=icalcomponent_get_first_property(event,ICAL_RDATE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_RDATE_PROPERTY)) {
    struct icaldatetimeperiodtype r=icalproperty_get_rdate(p); const char *rtz=RCICalendarTZID(p);
    if((tz || rtz) && (!tz || !rtz || strcmp(tz,rtz))) goto unsupported;
    if(icaltime_is_utc(start)!=icaltime_is_utc(r.time) || !RCRecurrenceDay(start,r.time,&day)) goto unsupported;
    [days addObject:[NSNumber numberWithInt:day]]; if(day>last) last=day;
  }
  for(p=icalcomponent_get_first_property(event,ICAL_RRULE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_RRULE_PROPERTY)) {
    struct icalrecurrencetype rule=icalproperty_get_rrule(p);
    if(!rule.count && icaltime_is_null_time(rule.until)) goto unsupported;
    icalrecur_iterator *it=icalrecur_iterator_new(rule,start); if(!it) goto unsupported;
    struct icaltimetype t;
    while(!icaltime_is_null_time(t=icalrecur_iterator_next(it))) {
      if(++budget>10000 || !RCRecurrenceDay(start,t,&day)) { icalrecur_iterator_free(it); goto unsupported; }
      [days addObject:[NSNumber numberWithInt:day]]; if(day>last) last=day;
    }
    icalrecur_iterator_free(it);
  }
  for(p=icalcomponent_get_first_property(event,ICAL_EXRULE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_EXRULE_PROPERTY)) {
    icalrecur_iterator *it=icalrecur_iterator_new(icalproperty_get_exrule(p),start); if(!it) goto unsupported;
    struct icaltimetype t, limit=start; icaltime_adjust(&limit,last,0,0,0);
    while(!icaltime_is_null_time(t=icalrecur_iterator_next(it)) && icaltime_compare(t,limit)<=0) {
      if(++budget>10000 || !RCRecurrenceDay(start,t,&day)) { icalrecur_iterator_free(it); goto unsupported; }
      [days removeObject:[NSNumber numberWithInt:day]];
    }
    icalrecur_iterator_free(it);
  }
  icalproperty_kind remove[]={ICAL_RRULE_PROPERTY,ICAL_RDATE_PROPERTY,ICAL_EXRULE_PROPERTY}; int k;
  for(k=0;k<3;k++) while((p=icalcomponent_get_first_property(event,remove[k]))) {
    icalcomponent_remove_property(event,p); icalproperty_free(p);
  }
  struct icalrecurrencetype rule=icalrecurrencetype_from_string("FREQ=DAILY"); rule.count=last+1;
  icalcomponent_add_property(event,icalproperty_new_rrule(rule));
  for(day=0;day<=last;day++) if(![days containsObject:[NSNumber numberWithInt:day]]) {
    struct icaltimetype t=start; icaltime_adjust(&t,day,0,0,0);
    p=icalproperty_new_exdate(t);
    if(tz) icalproperty_add_parameter(p,icalparameter_new_tzid(tz));
    icalcomponent_add_property(event,p);
  }
  return YES;
unsupported:
  RCErrorSet(error,1,"RDATE/EXRULE requires a finite set within ten years at the DTSTART wall time and timezone");
  return NO;
}

static inline BOOL RCSourceZoneIsFixed(icaltimezone *zone, int offset)
{
  icalcomponent *definition=icaltimezone_get_component(zone), *part;
  int count=0;
  for(part=icalcomponent_get_first_component(definition,ICAL_ANY_COMPONENT);part;
      part=icalcomponent_get_next_component(definition,ICAL_ANY_COMPONENT)) {
    icalproperty *from=icalcomponent_get_first_property(part,ICAL_TZOFFSETFROM_PROPERTY),
        *to=icalcomponent_get_first_property(part,ICAL_TZOFFSETTO_PROPERTY);
    if(!from || !to || icalproperty_get_tzoffsetfrom(from)!=offset || icalproperty_get_tzoffsetto(to)!=offset) return NO;
    count++;
  }
  return count>0;
}
static inline BOOL RCNeedsUTCProjection(icalcomponent *root, icalcomponent *event)
{
  icalproperty *p=icalcomponent_get_first_property(event,ICAL_DTSTART_PROPERTY);
  struct icaltimetype start=icalcomponent_get_dtstart(event);
  if(start.is_date || !RCICalendarTZID(p) || !icalcomponent_count_properties(event,ICAL_RRULE_PROPERTY)) return NO;
  icaltimezone *source=RCCalendarSourceZone(root,p); if(!source) return NO;
  int dst=0, offset=icaltimezone_get_utc_offset(source,&start,&dst);
  if(RCSourceZoneIsFixed(source,offset)) return NO;
  NSTimeZone *native=[NSTimeZone timeZoneWithName:[NSString stringWithUTF8String:RCICalendarTZID(p)]];
  if(!native) return YES;
  BOOL matches=YES; struct icaltimetype t=start; t.month=1; t.day=1; t.hour=12;
  NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init]; int samples=0;
  while(matches && t.year<=start.year+5) {
    offset=icaltimezone_get_utc_offset(source,&t,&dst);
    matches=[native secondsFromGMTForDate:RCCalendarWallDate(t,[NSTimeZone timeZoneForSecondsFromGMT:offset])]==offset;
    icaltime_adjust(&t,1,0,0,0);
    if(++samples%366==0) { [pool release]; pool=[[NSAutoreleasePool alloc] init]; }
  }
  [pool release]; return !matches;
}
static inline void RCRemoveCalendarProperties(icalcomponent *event,icalproperty_kind kind)
{
  icalproperty *p;
  while((p=icalcomponent_get_first_property(event,kind))) { icalcomponent_remove_property(event,p); icalproperty_free(p); }
}
static inline struct icaltimetype RCUTCTime(NSDate *date)
{
  return icaltime_from_string([[date descriptionWithCalendarFormat:@"%Y%m%dT%H%M%SZ"
      timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0] locale:nil] UTF8String]);
}
/* iCal discards unfamiliar NSTimeZone data when processing a sync record.
   A bounded series instead uses a UTC daily envelope, explicit exclusions,
   and detached occurrences wherever the authoritative offset differs. This
   is an exact finite projection, not a rolling or truncated expansion. */
static inline BOOL RCProjectTimezone(icalcomponent *root,icalcomponent *event,RCError *error)
{
  if(!RCNeedsUTCProjection(root,event)) return YES;
  icalcomponent *other;
  for(other=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);other;
      other=icalcomponent_get_next_component(root,ICAL_VEVENT_COMPONENT))
    if(icalcomponent_count_properties(other,ICAL_RECURRENCEID_PROPERTY)) goto unsupported;
  icalcomponent *alarm;
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
  NSDate *first=RCCalendarWallDate(start,[NSTimeZone timeZoneForSecondsFromGMT:initialOffset]);
  struct icaldurationtype duration=icalcomponent_get_duration(event);
  int seconds=icaldurationtype_as_int(duration);
  if(icalcomponent_get_dtend(event).year>2037 || seconds<0 || seconds>86400 || icalcomponent_count_properties(event,ICAL_DURATION_PROPERTY)) goto unsupported;
  NSMutableDictionary *occurrences=[NSMutableDictionary dictionary]; int last=0, day, budget=0;
  icalrecur_iterator *it=icalrecur_iterator_new(rule,start); if(!it) goto unsupported;
  struct icaltimetype t;
  /* DTSTART belongs to the set even if it does not match the rule filters. */
  [occurrences setObject:first forKey:[NSNumber numberWithInt:0]];
  while(!icaltime_is_null_time(t=icalrecur_iterator_next(it))) {
    if(++budget>10000 || t.year>2037 || icaltime_add(t,duration).year>2037 || !RCRecurrenceDay(start,t,&day)) { icalrecur_iterator_free(it); goto unsupported; }
    int offset=icaltimezone_get_utc_offset(zone,&t,&dst);
    [occurrences setObject:RCCalendarWallDate(t,[NSTimeZone timeZoneForSecondsFromGMT:offset]) forKey:[NSNumber numberWithInt:day]];
    if(day>last) last=day;
  }
  icalrecur_iterator_free(it);
  for(p=icalcomponent_get_first_property(event,ICAL_EXDATE_PROPERTY);p;
      p=icalcomponent_get_next_property(event,ICAL_EXDATE_PROPERTY)) {
    t=icalproperty_get_exdate(p);
    icaltimezone *from=icaltime_is_utc(t) ? icaltimezone_get_utc_timezone() : RCCalendarSourceZone(root,p);
    if(!from || t.is_date) goto unsupported;
    icaltimezone_convert_time(&t,from,zone);
    if(RCRecurrenceDay(start,t,&day)) [occurrences removeObjectForKey:[NSNumber numberWithInt:day]];
  }
  icalcomponent *template=icalcomponent_new_clone(event); if(!template) goto unsupported;
  icalproperty_kind remove[]={ICAL_RRULE_PROPERTY,ICAL_RDATE_PROPERTY,ICAL_EXRULE_PROPERTY,ICAL_EXDATE_PROPERTY,
      ICAL_DTSTART_PROPERTY,ICAL_DTEND_PROPERTY}; int k;
  for(k=0;k<6;k++) RCRemoveCalendarProperties(event,remove[k]);
  icalcomponent_add_property(event,icalproperty_new_dtstart(RCUTCTime(first)));
  icalcomponent_add_property(event,icalproperty_new_dtend(RCUTCTime([NSDate dateWithTimeIntervalSinceReferenceDate:[first timeIntervalSinceReferenceDate]+seconds])));
  rule=icalrecurrencetype_from_string("FREQ=DAILY"); rule.count=last+1;
  icalcomponent_add_property(event,icalproperty_new_rrule(rule));
  for(day=0;day<=last;day++) {
    NSDate *baseline=[NSDate dateWithTimeIntervalSinceReferenceDate:[first timeIntervalSinceReferenceDate]+day*86400.0];
    NSDate *actual=[occurrences objectForKey:[NSNumber numberWithInt:day]];
    if(!actual) { icalcomponent_add_property(event,icalproperty_new_exdate(RCUTCTime(baseline))); continue; }
    if([actual isEqual:baseline]) continue;
    icalcomponent *detached=icalcomponent_new_clone(template);
    if(!detached) { icalcomponent_free(template); goto unsupported; }
    for(k=0;k<6;k++) RCRemoveCalendarProperties(detached,remove[k]);
    icalcomponent_add_property(detached,icalproperty_new_recurrenceid(RCUTCTime(baseline)));
    icalcomponent_add_property(detached,icalproperty_new_dtstart(RCUTCTime(actual)));
    icalcomponent_add_property(detached,icalproperty_new_dtend(RCUTCTime([NSDate dateWithTimeIntervalSinceReferenceDate:[actual timeIntervalSinceReferenceDate]+seconds])));
    icalcomponent_add_component(root,detached);
  }
  icalcomponent_free(template); return YES;
unsupported:
  RCErrorSet(error,1,"Changed timezone rules require a finite series ending by 2037, spanning at most ten years, without existing detached instances, absolute reminders or DURATION");
  return NO;
}
static inline BOOL RCPrepareCalendarProjection(icalcomponent *root,RCError *error)
{
  NSMutableArray *events=[NSMutableArray array]; icalcomponent *event;
  for(event=icalcomponent_get_first_component(root,ICAL_VEVENT_COMPONENT);event;
      event=icalcomponent_get_next_component(root,ICAL_VEVENT_COMPONENT)) [events addObject:[NSValue valueWithPointer:event]];
  NSEnumerator *it=[events objectEnumerator]; NSValue *value;
  while((value=[it nextObject])) if(!RCExpandFiniteRecurrence([value pointerValue],error)) return NO;
  it=[events objectEnumerator];
  while((value=[it nextObject])) if(!RCProjectTimezone(root,[value pointerValue],error)) return NO;
  return YES;
}
#endif
