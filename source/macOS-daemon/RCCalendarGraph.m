#import "RCPlatformDate.h"
#import "RCRecordGraph.h"
#import "RCAutorelease.h"
#import "RCLogger.h"
#import "RCCalendarGraph.h"
#import "RCCalendarSyncClient.h"
#import "RCTwoWaySync.h"
#import "RCCalendarTime.h"
#import "RCCalendarRecurrence.h"
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static NSString *String(const char *s)
{
  return s ? [NSString stringWithUTF8String:s] : nil;
}
static NSString *Entity(NSString *s)
{
  return [@"com.apple.calendars." stringByAppendingString:s];
}
static void Text(NSMutableDictionary *d, NSString *key, const char *value)
{
  NSString *s = String(value);
  if (s)
    [d setObject:s forKey:key];
}
static NSMutableDictionary *Record(NSString *entity)
{
  return [NSMutableDictionary dictionaryWithObject:Entity(entity)
                                            forKey:RCRecordEntityNameKey];
}
static void Link(NSMutableDictionary *d, NSString *key, NSString *id)
{
  [d setObject:id ? [NSArray arrayWithObject:id] : [NSArray array] forKey:key];
}
static NSString *Identity(RCCalendarStore *s, NSString *owner, NSString *key,
                          RCError *error)
{
  char *id = RCCalendarStoreIdentity(s, [owner UTF8String], [key UTF8String], error);
  NSString *result = id ? [@"cal-" stringByAppendingString:String(id)] : nil;
  free(id);
  return result;
}
static icaltimezone *RCEventZone(icalcomponent *root, icalproperty *p,
                                 struct icaltimetype t)
{
  const char *tz = RCICalendarTZID(p);
  if (icaltime_is_utc(t))
    return icaltimezone_get_utc_timezone();
  if (!tz)
    return NULL;
  return RCCalendarSourceZone(root,p);
}
/* Dates are constructed from calendar fields, never through 32-bit time_t. */
static RCCalendarDate *Date(icalcomponent *root, icalproperty *p, struct icaltimetype t,
                            icalcomponent *recurring, RCError *error)
{
  NSTimeZone *native;
  icaltimezone *zone;
  const char *tz = RCICalendarTZID(p);
  int offset, daylight = 0;
  RCCalendarDate *date;
  if (icaltime_is_null_time(t) || !icaltime_is_valid_time(t)) {
    RCErrorSet(error, 1, "Event contains a missing or invalid date");
    return nil;
  }
  if (t.is_date)
    return [RCCalendarDate dateWithYear:t.year
                                  month:t.month
                                    day:t.day
                                   hour:12
                                 minute:0
                                 second:0
                               timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
  zone = RCEventZone(root, p, t);
  if (!zone && !tz && !icaltime_is_utc(t)) {
    date=RCCalendarWallDate(t,[NSTimeZone localTimeZone]);
    if([date yearOfCommonEra]!=t.year || [date monthOfYear]!=t.month || [date dayOfMonth]!=t.day ||
        [date hourOfDay]!=t.hour || [date minuteOfHour]!=t.minute || [date secondOfMinute]!=t.second) {
      RCErrorSet(error,1,"Floating time falls in a local clock gap that Tiger cannot represent"); return nil;
    }
    return date;
  }
  if (!zone) {
    RCErrorSet(error, 1, "Event timezone is unavailable");
    return nil;
  }
  offset = icaltimezone_get_utc_offset(zone, &t, &daylight);
  native = icaltime_is_utc(t) ? [NSTimeZone timeZoneForSecondsFromGMT:0]
                              : [NSTimeZone timeZoneWithName:String(tz)];
  date=RCCalendarWallDate(t,[NSTimeZone timeZoneForSecondsFromGMT:offset]);
  if (!recurring || icaltime_is_utc(t)) return date;
  BOOL matches=native && [native secondsFromGMTForDate:date]==offset;
  /* The projection pass checks the master's zone daily. Retain the original
     seasonal check here as well for a separately zoned DTEND. */
  struct icaltimetype probe=t; probe.month=1; probe.day=15; probe.hour=12;
  while(matches && probe.year<=t.year+5) {
    int expected=icaltimezone_get_utc_offset(zone,&probe,&daylight);
    RCCalendarDate *nd=RCCalendarWallDate(probe,[NSTimeZone timeZoneForSecondsFromGMT:expected]);
    matches=[native secondsFromGMTForDate:nd]==expected;
    if(++probe.month>12) { probe.month=1; probe.year++; }
  }
  if(!matches && RCSourceZoneIsFixed(zone,offset)) { native=[NSTimeZone timeZoneForSecondsFromGMT:offset]; matches=YES; }
  if(!matches) {
    RCErrorSet(error,1,"Recurring timezone requires a finite UTC projection"); return nil;
  }
  [date setTimeZone:native];
  return date;
}
static NSArray *Numbers(short *values, size_t capacity)
{
  NSMutableArray *a = [NSMutableArray array];
  size_t i;
  for (i = 0; i < capacity && values[i] != ICAL_RECURRENCE_ARRAY_MAX; i++)
    [a addObject:[NSNumber numberWithInt:values[i]]];
  return a;
}
static NSString *Weekday(int day)
{
  static NSString *names[] = {@"",          @"sunday",   @"monday", @"tuesday",
                              @"wednesday", @"thursday", @"friday", @"saturday"};
  return day >= 1 && day <= 7 ? names[day] : nil;
}
static int Recurrence(RCCalendarStore *store, icalcomponent *root, icalcomponent *event,
                      NSString *eventID, NSMutableDictionary *record,
                      NSMutableDictionary *records, RCError *error)
{
  icalproperty *p = icalcomponent_get_first_property(event, ICAL_RRULE_PROPERTY);
  struct icalrecurrencetype r;
  NSMutableDictionary *rule;
  NSString *id;
  size_t i;
  if (!p) {
    Link(record, @"recurrences", nil);
    return 1;
  }
  if (icalcomponent_count_properties(event, ICAL_RRULE_PROPERTY) != 1 ||
      icalcomponent_count_properties(event, ICAL_RDATE_PROPERTY) ||
      icalcomponent_count_properties(event, ICAL_EXRULE_PROPERTY)) {
    RCErrorSet(error, 1,
               "Multiple rules, RDATE, or EXRULE require a richer recurrence mapper");
    return 0;
  }
  r = icalproperty_get_rrule(p);
  if (r.freq < ICAL_DAILY_RECURRENCE || r.freq > ICAL_YEARLY_RECURRENCE ||
      r.by_second[0] != ICAL_RECURRENCE_ARRAY_MAX ||
      r.by_minute[0] != ICAL_RECURRENCE_ARRAY_MAX ||
      r.by_hour[0] != ICAL_RECURRENCE_ARRAY_MAX || r.rscale) {
    RCErrorSet(error, 1, "Recurrence rule is outside the Tiger schema");
    return 0;
  }
  id = Identity(store, eventID, @"recurrence", error);
  if (!id)
    return 0;
  rule = Record(@"Recurrence");
  Link(rule, @"owner", eventID);
  [rule setObject:[String(icalrecur_freq_to_string(r.freq)) lowercaseString]
           forKey:@"frequency"];
  [rule setObject:[NSNumber numberWithInt:r.interval] forKey:@"interval"];
  if (r.count)
    [rule setObject:[NSNumber numberWithInt:r.count] forKey:@"count"];
  if (!icaltime_is_null_time(r.until)) {
    icalproperty *basis=icalcomponent_get_first_property(event,ICAL_DTSTART_PROPERTY);
    RCCalendarDate *until = Date(root, icaltime_is_utc(r.until) ? p : basis, r.until, NULL, error);
    if (!until)
      return 0;
    [rule setObject:until forKey:@"until"];
  }
#define BY(field, key)                                                                 \
  do {                                                                                 \
    NSArray *values = Numbers(r.field, sizeof(r.field) / sizeof(r.field[0]));          \
    if ([values count])                                                                \
      [rule setObject:values forKey:key];                                              \
  } while (0)
  BY(by_month, @"bymonth");
  BY(by_month_day, @"bymonthday");
  BY(by_year_day, @"byyearday");
  BY(by_week_no, @"byweeknumber");
  BY(by_set_pos, @"bysetpos");
#undef BY
  {
    NSMutableArray *days = [NSMutableArray array], *positions = [NSMutableArray array];
    for (i = 0; i < sizeof(r.by_day) / sizeof(r.by_day[0]) &&
                r.by_day[i] != ICAL_RECURRENCE_ARRAY_MAX;
         i++) {
      NSString *day = Weekday(icalrecurrencetype_day_day_of_week(r.by_day[i]));
      if (!day) {
        RCErrorSet(error, 1, "Invalid recurrence weekday");
        return 0;
      }
      [days addObject:day];
      [positions addObject:[NSNumber numberWithInt:icalrecurrencetype_day_position(
                                                       r.by_day[i])]];
    }
    if ([days count]) {
      [rule setObject:days forKey:@"bydaydays"];
      [rule setObject:positions forKey:@"bydayfreq"];
    }
  }
  if (Weekday(r.week_start))
    [rule setObject:Weekday(r.week_start) forKey:@"weekstartday"];
  Link(record, @"recurrences", id);
  [records setObject:rule forKey:id];
  return 1;
}
static NSString *Token(const char *value)
{
  NSString *s = [String(value) lowercaseString];
  return [[s componentsSeparatedByString:@"-"] componentsJoinedByString:@""];
}
static int People(RCCalendarStore *store, icalcomponent *event, NSString *owner,
                  NSMutableDictionary *record, NSMutableDictionary *records,
                  RCError *error)
{
  int k;
  for (k = 0; k < 2; k++) {
    icalproperty_kind kind = k ? ICAL_ORGANIZER_PROPERTY : ICAL_ATTENDEE_PROPERTY;
    icalproperty *p;
    NSMutableArray *ids = [NSMutableArray array];
    for (p = icalcomponent_get_first_property(event, kind); p;
         p = icalcomponent_get_next_property(event, kind)) {
      const char *address = icalproperty_get_value_as_string(p);
      NSString *key, *id;
      NSMutableDictionary *person;
      icalparameter *param;
      if (!address || strncasecmp(address, "mailto:", 7))
        continue;
      key = [NSString stringWithFormat:@"%d:%@", k, [String(address) lowercaseString]];
      id = Identity(store, owner, key, error);
      if (!id)
        return 0;
      if ([ids containsObject:id]) {
        RCErrorSet(error, 1, "Duplicate calendar participant");
        return 0;
      }
      person = Record(k ? @"Organizer" : @"Attendee");
      Link(person, @"owner", owner);
      Text(person, @"email", address + 7);
      param = icalproperty_get_first_parameter(p, ICAL_CN_PARAMETER);
      if (param)
        Text(person, @"common name", icalparameter_get_cn(param));
      if (!k) {
        param = icalproperty_get_first_parameter(p, ICAL_ROLE_PARAMETER);
        [person setObject:param ? Token(icalparameter_enum_to_string(
                                      icalparameter_get_role(param)))
                                : @"requiredparticipant"
                   forKey:@"role"];
        /* iCalendar REQ/OPT-PARTICIPANT names differ from Apple's enums. */
        if ([[person objectForKey:@"role"] isEqual:@"reqparticipant"])
          [person setObject:@"requiredparticipant" forKey:@"role"];
        if ([[person objectForKey:@"role"] isEqual:@"optparticipant"])
          [person setObject:@"optionalparticipant" forKey:@"role"];
        param = icalproperty_get_first_parameter(p, ICAL_PARTSTAT_PARAMETER);
        [person setObject:param ? Token(icalparameter_enum_to_string(
                                      icalparameter_get_partstat(param)))
                                : @"needsaction"
                   forKey:@"status"];
        param = icalproperty_get_first_parameter(p, ICAL_CUTYPE_PARAMETER);
        [person setObject:param ? Token(icalparameter_enum_to_string(
                                      icalparameter_get_cutype(param)))
                                : @"individual"
                   forKey:@"user type"];
        param = icalproperty_get_first_parameter(p, ICAL_RSVP_PARAMETER);
        [person
            setObject:[NSNumber numberWithBool:param && icalparameter_get_rsvp(param) ==
                                                            ICAL_RSVP_TRUE]
               forKey:@"rsvp"];
      }
      [ids addObject:id];
      [records setObject:person forKey:id];
    }
    if (k && [ids count] > 1) {
      RCErrorSet(error, 1, "Multiple event organizers");
      return 0;
    }
    [record setObject:ids forKey:k ? @"organizer" : @"attendees"];
  }
  return 1;
}
static int Alarms(RCCalendarStore *store, icalcomponent *root, icalcomponent *event,
                  NSString *owner, NSMutableDictionary *record,
                  NSMutableDictionary *records, RCError *error)
{
  icalcomponent *alarm;
  NSMutableArray *display = [NSMutableArray array], *audio = [NSMutableArray array];
  NSMutableDictionary *duplicates = [NSMutableDictionary dictionary];
  for (alarm = icalcomponent_get_first_component(event, ICAL_VALARM_COMPONENT); alarm;
       alarm = icalcomponent_get_next_component(event, ICAL_VALARM_COMPONENT)) {
    const char *action = RCICalendarValue(alarm, ICAL_ACTION_PROPERTY);
    icalproperty *p = icalcomponent_get_first_property(alarm, ICAL_TRIGGER_PROPERTY);
    struct icaltriggertype trigger;
    NSMutableDictionary *a;
    NSString *key, *id, *base;
    int occurrence;
    if (!action || (strcmp(action, "DISPLAY") && strcmp(action, "AUDIO")))
      continue;
    if (!p) {
      RCErrorSet(error, 1, "Alarm has no trigger");
      return 0;
    }
    if (icalproperty_get_first_parameter(p, ICAL_RELATED_PARAMETER) &&
        icalparameter_get_related(icalproperty_get_first_parameter(
            p, ICAL_RELATED_PARAMETER)) == ICAL_RELATED_END) {
      RCErrorSet(error, 1, "End-relative alarms are not yet mapped");
      return 0;
    }
    base = [NSString
        stringWithFormat:@"alarm:%s:%s", action, icalproperty_get_value_as_string(p)];
    occurrence = [[duplicates objectForKey:base] intValue];
    [duplicates setObject:[NSNumber numberWithInt:occurrence + 1] forKey:base];
    key = [NSString stringWithFormat:@"%@:%d", base, occurrence];
    id = Identity(store, owner, key, error);
    if (!id)
      return 0;
    a = Record(!strcmp(action, "DISPLAY") ? @"DisplayAlarm" : @"AudioAlarm");
    Link(a, @"owner", owner);
    trigger = icalproperty_get_trigger(p);
    if (!icaltime_is_null_time(trigger.time)) {
      if(!icaltime_is_utc(trigger.time)) { RCErrorSet(error,1,"Absolute reminders must use UTC"); return 0; }
      RCCalendarDate *date = Date(root, p, trigger.time, NULL, error);
      if (!date)
        return 0;
      [a setObject:date forKey:@"triggerdate"];
    } else
      [a setObject:[NSNumber numberWithInt:icaldurationtype_as_int(trigger.duration)]
            forKey:@"triggerduration"];
    Text(a, @"description", RCICalendarValue(alarm, ICAL_DESCRIPTION_PROPERTY));
    /* Tiger's sound field is a URL. Only a single URI attachment has a
       lossless native representation; embedded/multiple attachments stay raw. */
    if (!strcmp(action,"AUDIO") && icalcomponent_count_properties(alarm,ICAL_ATTACH_PROPERTY)==1) {
      icalattach *attachment=icalproperty_get_attach(icalcomponent_get_first_property(alarm,ICAL_ATTACH_PROPERTY));
      if (attachment && icalattach_get_is_url(attachment)) {
        NSURL *sound=[NSURL URLWithString:String(icalattach_get_url(attachment))];
        if (sound) [a setObject:sound forKey:@"com.apple.ical.sound"];
      }
    }
    p = icalcomponent_get_first_property(alarm, ICAL_REPEAT_PROPERTY);
    if (p)
      [a setObject:[NSNumber numberWithInt:icalproperty_get_repeat(p)]
            forKey:@"repeat count"];
    p = icalcomponent_get_first_property(alarm, ICAL_DURATION_PROPERTY);
    if (p)
      [a setObject:[NSNumber numberWithInt:icaldurationtype_as_int(
                                               icalproperty_get_duration(p))]
            forKey:@"repeat interval"];
    [records setObject:a forKey:id];
    [!strcmp(action, "DISPLAY") ? display : audio addObject:id];
  }
  [record setObject:display forKey:@"display alarms"];
  [record setObject:audio forKey:@"audio alarms"];
  [record setObject:[NSArray array] forKey:@"mail alarms"];
  return 1;
}
NSMutableDictionary *RCCalendarResourceGraph(RCCalendarStore *store, long long resource,
                                        NSString *calendarID,
                                        const unsigned char *bytes, size_t length,
                                        RCError *error)
{
  icalcomponent *root = RCICalendarParse(bytes, length, error), *component,
                *master = NULL;
  NSMutableDictionary *records = [NSMutableDictionary dictionary],
                      *identifiers = [NSMutableDictionary dictionary];
  NSMutableArray *events = [NSMutableArray array], *detached = [NSMutableArray array],
                 *cancelled = [NSMutableArray array];
  NSString *owner = [NSString stringWithFormat:@"resource-%lld", resource],
           *masterID = nil;
  NSEnumerator *iterator;
  NSValue *value;
  int success = 0;
  if (!root)
    return nil;
  if(!RCPrepareCalendarProjection(root,error)) goto done;
  for (component = icalcomponent_get_first_component(root, ICAL_ANY_COMPONENT);
       component;
       component = icalcomponent_get_next_component(root, ICAL_ANY_COMPONENT)) {
    char *key;
    NSString *id;
    if (icalcomponent_isa(component) == ICAL_VTIMEZONE_COMPONENT)
      continue;
    if (icalcomponent_isa(component) != ICAL_VEVENT_COMPONENT) {
      RCErrorSet(error, 1, "Only VEVENT resources are exported to iCal");
      goto done;
    }
    key = RCICalendarRecurrenceKey(component);
    if (!key) {
      RCErrorSet(error, 1, "Could not allocate recurrence identity");
      goto done;
    }
    if ([identifiers objectForKey:String(key)]) {
      free(key);
      RCErrorSet(error, 1, "Duplicate recurrence identity");
      goto done;
    }
    id = Identity(
        store, owner,
        [NSString stringWithFormat:@"%s:%s",
                                   RCICalendarValue(component, ICAL_UID_PROPERTY), key],
        error);
    if (!id) {
      free(key);
      goto done;
    }
    [identifiers setObject:id forKey:String(key)];
    if (!*key) {
      master = component;
      masterID = id;
    }
    free(key);
    [events addObject:[NSValue valueWithPointer:component]];
  }
  if (!master || ![events count]) {
    RCErrorSet(error, 1,
               "A detached recurrence set without a master is not yet supported");
    goto done;
  }
  iterator = [events objectEnumerator];
  while ((value = [iterator nextObject])) {
    icalcomponent *event = [value pointerValue];
    char *key = RCICalendarRecurrenceKey(event);
    NSString *id = key ? [identifiers objectForKey:String(key)] : nil;
    NSMutableDictionary *record = Record(@"Event");
    icalproperty *startProperty =
                     icalcomponent_get_first_property(event, ICAL_DTSTART_PROPERTY),
                 *endProperty =
                     icalcomponent_get_first_property(event, ICAL_DTEND_PROPERTY),
                 *p;
    icalcomponent *recurring = icalcomponent_count_properties(event, ICAL_RRULE_PROPERTY) > 0 ? event : NULL;
    struct icaltimetype start = icalcomponent_get_dtstart(event),
                        end = icalcomponent_get_dtend(event);
    RCCalendarDate *startDate, *endDate;
    NSMutableArray *exceptions = [NSMutableArray array];
    free(key);
    if (!id)
      goto done;
    if (event != master) {
      RCCalendarDate *original;
      p = icalcomponent_get_first_property(event, ICAL_RECURRENCEID_PROPERTY);
      if (icalproperty_get_first_parameter(p, ICAL_RANGE_PARAMETER)) {
        RCErrorSet(error, 1, "Ranged recurrence exceptions are not yet supported");
        goto done;
      }
      original = Date(root, p, icalproperty_get_recurrenceid(p), NULL, error);
      if (!original)
        goto done;
      if (icalcomponent_get_status(event) == ICAL_STATUS_CANCELLED) {
        [cancelled addObject:original];
        continue;
      }
      [record setObject:original forKey:@"original date"];
      Link(record, @"main event", masterID);
      [detached addObject:id];
    } else
      Link(record, @"main event", nil);
    if (icalcomponent_count_properties(event, ICAL_RDATE_PROPERTY) ||
        icalcomponent_count_properties(event, ICAL_EXRULE_PROPERTY)) {
      RCErrorSet(error, 1, "RDATE/EXRULE are not yet supported by the Tiger mapper");
      goto done;
    }
    if (icaltime_is_null_time(end)) {
      end = start;
      if (start.is_date)
        icaltime_adjust(&end, 1, 0, 0, 0);
    }
    startDate = Date(root, startProperty, start, recurring, error);
    endDate =
        Date(root, endProperty ? endProperty : startProperty, end, recurring, error);
    if (!startDate || !endDate)
      goto done;
    if ([endDate compare:startDate] == NSOrderedAscending ||
        start.is_date != end.is_date) {
      RCErrorSet(error, 1, "Event end precedes start or has a different date type");
      goto done;
    }
    [record setObject:startDate forKey:@"start date"];
    [record setObject:endDate forKey:@"end date"];
    [record setObject:[NSNumber numberWithBool:start.is_date] forKey:@"all day"];
    Link(record, @"calendar", calendarID);
    Link(record, @"detached events", nil);
    Text(record, @"summary",
         RCICalendarValue(event, ICAL_SUMMARY_PROPERTY)
             ? RCICalendarValue(event, ICAL_SUMMARY_PROPERTY)
             : "Untitled event");
    Text(record, @"description", RCICalendarValue(event, ICAL_DESCRIPTION_PROPERTY));
    Text(record, @"location", RCICalendarValue(event, ICAL_LOCATION_PROPERTY));
    {
      const char *url = RCICalendarValue(event, ICAL_URL_PROPERTY),
                 *status = RCICalendarValue(event, ICAL_STATUS_PROPERTY),
                 *classification = RCICalendarValue(event, ICAL_CLASS_PROPERTY);
      NSURL *u = url ? [NSURL URLWithString:String(url)] : nil;
      if (u)
        [record setObject:u forKey:@"url"];
      [record setObject:status ? [String(status) lowercaseString] : @"none"
                 forKey:@"status"];
      [record setObject:classification ? [String(classification) lowercaseString]
                                       : @"public"
                 forKey:@"classification"];
    }
    for (p = icalcomponent_get_first_property(event, ICAL_EXDATE_PROPERTY); p;
         p = icalcomponent_get_next_property(event, ICAL_EXDATE_PROPERTY)) {
      RCCalendarDate *date = Date(root, p, icalproperty_get_exdate(p), NULL, error);
      if (!date)
        goto done;
      [exceptions addObject:date];
    }
    [record setObject:exceptions forKey:@"exception dates"];
    if (!Recurrence(store, root, event, id, record, records, error) ||
        !People(store, event, id, record, records, error) ||
        !Alarms(store, root, event, id, record, records, error))
      goto done;
    [records setObject:record forKey:id];
  }
  [[records objectForKey:masterID] setObject:detached forKey:@"detached events"];
  [[[records objectForKey:masterID] objectForKey:@"exception dates"]
      addObjectsFromArray:cancelled];
  success = 1;
done:
  icalcomponent_free(root);
  return success ? records : nil;
}

NSDictionary *RCCalendarNativeGraph(RCCalendarStore *store, long long identifier,
    NSString *calendar, NSData *body, RCError *error)
{
  return RCCalendarResourceGraph(store,identifier,calendar,[body bytes],[body length],error);
}
