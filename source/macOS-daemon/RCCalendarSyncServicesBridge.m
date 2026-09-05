#import "RCCalendarSyncServicesBridge.h"
#import "RCCalendarSyncClient.h"
#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static NSString *const testIdentifier = @"com.retrocloudsync.calendars.test.v1";
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
                                            forKey:ISyncRecordEntityNameKey];
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
  icaltimezone *zone;
  if (icaltime_is_utc(t))
    return icaltimezone_get_utc_timezone();
  if (!tz)
    return NULL;
  zone = icalcomponent_get_timezone(root, tz);
  if (!zone)
    zone = icaltimezone_get_builtin_timezone(tz);
  return zone;
}
/* Dates are constructed from calendar fields, never through 32-bit time_t. */
static NSCalendarDate *Date(icalcomponent *root, icalproperty *p, struct icaltimetype t,
                            BOOL recurring, RCError *error)
{
  NSTimeZone *native;
  icaltimezone *zone;
  const char *tz = RCICalendarTZID(p);
  int offset, daylight = 0;
  NSCalendarDate *date;
  if (icaltime_is_null_time(t) || !icaltime_is_valid_time(t)) {
    RCErrorSet(error, 1, "Event contains a missing or invalid date");
    return nil;
  }
  if (t.is_date)
    return [NSCalendarDate dateWithYear:t.year
                                  month:t.month
                                    day:t.day
                                   hour:12
                                 minute:0
                                 second:0
                               timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
  zone = RCEventZone(root, p, t);
  if (!zone) {
    RCErrorSet(error, 1,
               tz ? "Event timezone is unavailable"
                  : "Floating timed events are not yet supported by the Tiger mapper");
    return nil;
  }
  offset = icaltimezone_get_utc_offset(zone, &t, &daylight);
  native = icaltime_is_utc(t) ? [NSTimeZone timeZoneForSecondsFromGMT:0]
                              : [NSTimeZone timeZoneWithName:String(tz)];
  date = [NSCalendarDate dateWithYear:t.year
                                month:t.month
                                  day:t.day
                                 hour:t.hour
                               minute:t.minute
                               second:t.second
                             timeZone:[NSTimeZone timeZoneForSecondsFromGMT:offset]];
  if (!recurring)
    return date;
  if (!native || [native secondsFromGMTForDate:date] != offset) {
    RCErrorSet(error, 1, "Recurring event timezone cannot be represented by Tiger");
    return nil;
  }
  /* Check both sides of each season. Old system zone rules must not silently
     change recurrence wall time. Unmatched custom/changed zones stay in SQL. */
  {
    int year, month;
    for (year = t.year; year <= t.year + 5; year++)
      for (month = 1; month <= 12; month++) {
        struct icaltimetype probe = t;
        NSCalendarDate *nd;
        probe.year = year;
        probe.month = month;
        probe.day = 15;
        probe.hour = 12;
        offset = icaltimezone_get_utc_offset(zone, &probe, &daylight);
        nd =
            [NSCalendarDate dateWithYear:year
                                   month:month
                                     day:15
                                    hour:12
                                  minute:0
                                  second:0
                                timeZone:[NSTimeZone timeZoneForSecondsFromGMT:offset]];
        if ([native secondsFromGMTForDate:nd] != offset) {
          RCErrorSet(error, 1, "Tiger timezone rules differ from the recurring event");
          return nil;
        }
      }
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
    NSCalendarDate *until = Date(root, p, r.until, NO, error);
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
      NSCalendarDate *date = Date(root, p, trigger.time, NO, error);
      if (!date)
        return 0;
      [a setObject:date forKey:@"triggerdate"];
    } else
      [a setObject:[NSNumber numberWithInt:icaldurationtype_as_int(trigger.duration)]
            forKey:@"triggerduration"];
    Text(a, @"description", RCICalendarValue(alarm, ICAL_DESCRIPTION_PROPERTY));
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
static NSMutableDictionary *MapResource(RCCalendarStore *store, long long resource,
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
    BOOL recurring = icalcomponent_count_properties(event, ICAL_RRULE_PROPERTY) > 0;
    struct icaltimetype start = icalcomponent_get_dtstart(event),
                        end = icalcomponent_get_dtend(event);
    NSCalendarDate *startDate, *endDate;
    NSMutableArray *exceptions = [NSMutableArray array];
    free(key);
    if (!id)
      goto done;
    if (event != master) {
      NSCalendarDate *original;
      p = icalcomponent_get_first_property(event, ICAL_RECURRENCEID_PROPERTY);
      if (icalproperty_get_first_parameter(p, ICAL_RANGE_PARAMETER)) {
        RCErrorSet(error, 1, "Ranged recurrence exceptions are not yet supported");
        goto done;
      }
      original = Date(root, p, icalproperty_get_recurrenceid(p), NO, error);
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
      NSCalendarDate *date = Date(root, p, icalproperty_get_exdate(p), NO, error);
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

int RCSyncServicesPushCalendars(RCCalendarStore *store, const char *descriptionPath,
                                int testClient, long *count, RCError *error)
{
  ISyncSession *session = nil;
  sqlite3_stmt *q = NULL;
  NSMutableDictionary *records = [NSMutableDictionary dictionary],
                      *calendarRecords = [NSMutableDictionary dictionary];
  NSMutableArray *updates = [NSMutableArray array];
  NSString *clientID = nil;
  long long generation = 0;
  int success = 0, step = SQLITE_DONE;
  RCErrorClear(error);
  if (count)
    *count = 0;
  @try {
    if (sqlite3_prepare_v2(store->db,
                           "SELECT sync_id,generation FROM accounts WHERE id=?", -1, &q,
                           NULL) != SQLITE_OK)
      goto sqlError;
    sqlite3_bind_int64(q, 1, store->account);
    if (sqlite3_step(q) != SQLITE_ROW)
      goto sqlError;
    clientID =
        testClient
            ? testIdentifier
            : RCCalendarSyncClientIdentifier(
                  String((const char *)sqlite3_column_text(q, 0)));
    generation = sqlite3_column_int64(q, 1);
    sqlite3_finalize(q);
    q = NULL;
    if (!generation) {
      RCErrorSet(error, 1, "Calendar mirror has no complete inventory yet");
      goto done;
    }
    if (sqlite3_prepare_v2(store->db,
                           "SELECT id,sync_id,display_name,description FROM calendars "
                           "WHERE account_id=? AND remote_missing=0 ORDER BY id",
                           -1, &q, NULL) != SQLITE_OK)
      goto sqlError;
    sqlite3_bind_int64(q, 1, store->account);
    while ((step = sqlite3_step(q)) == SQLITE_ROW) {
      NSString *id = [@"calendar-"
          stringByAppendingString:String((const char *)sqlite3_column_text(q, 1))];
      NSMutableDictionary *record = Record(@"Calendar");
      NSString *title = String((const char *)sqlite3_column_text(q, 2));
      /* Calendar identity is title + read-only in Tiger. Include a stable short
         suffix so equal remote titles cannot merge with each other. */
      [record
          setObject:[NSString stringWithFormat:@"%@ (iCloud %@)",
                                               title ? title : @"Calendar",
                                               [id substringFromIndex:[id length] - 6]]
             forKey:@"title"];
      Text(record, @"notes", (const char *)sqlite3_column_text(q, 3));
      /* iCal turns imported calendars into writable local calendars. Declaring
         read-only here changes its identity on the next iCal sync and duplicates
         the calendar. One-way behavior is enforced by the push-only client. */
      [record setObject:[NSNumber numberWithBool:NO] forKey:@"read only"];
      [record setObject:[NSMutableArray array] forKey:@"events"];
      Link(record, @"tasks", nil);
      [calendarRecords
          setObject:id
             forKey:[NSNumber numberWithLongLong:sqlite3_column_int64(q, 0)]];
      [records setObject:record forKey:id];
    }
    if (step != SQLITE_DONE)
      goto sqlError;
    sqlite3_finalize(q);
    q = NULL;
    if (sqlite3_prepare_v2(
            store->db,
            "SELECT r.id,r.calendar_id,r.raw_ical,r.export_ical,r.parse_error FROM "
            "calendar_resources r JOIN calendars c ON "
            "c.id=r.calendar_id WHERE c.account_id=? AND "
            "c.remote_missing=0 AND r.remote_missing=0 ORDER BY r.id",
            -1, &q, NULL) != SQLITE_OK)
      goto sqlError;
    sqlite3_bind_int64(q, 1, store->account);
    while ((step = sqlite3_step(q)) == SQLITE_ROW) {
      long long resource = sqlite3_column_int64(q, 0);
      NSString *calendarID = [calendarRecords
          objectForKey:[NSNumber numberWithLongLong:sqlite3_column_int64(q, 1)]];
      RCError mappingError;
      NSMutableDictionary *mapped = nil;
      NSMutableDictionary *update = [NSMutableDictionary
          dictionaryWithObject:[NSNumber numberWithLongLong:resource]
                        forKey:@"resource"];
      RCErrorClear(&mappingError);
      if (sqlite3_column_type(q, 4) != SQLITE_NULL)
        RCErrorSet(&mappingError, 1, "%s", sqlite3_column_text(q, 4));
      else
        mapped = MapResource(store, resource, calendarID, sqlite3_column_blob(q, 2),
                             (size_t)sqlite3_column_bytes(q, 2), &mappingError);
      if (mapped) {
        [update setObject:[NSData dataWithBytes:sqlite3_column_blob(q, 2)
                                         length:(NSUInteger)sqlite3_column_bytes(q, 2)]
                   forKey:@"raw"];
        [update setObject:@"exported" forKey:@"status"];
      } else {
        [update setObject:String(mappingError.message) forKey:@"error"];
        if (sqlite3_column_type(q, 3) != SQLITE_NULL) {
          RCError oldError;
          mapped = MapResource(store, resource, calendarID, sqlite3_column_blob(q, 3),
                               (size_t)sqlite3_column_bytes(q, 3), &oldError);
          if (!mapped) {
            RCErrorSet(
                error, 1,
                "Could not reconstruct previously exported calendar resource %lld",
                resource);
            goto done;
          }
        }
        [update setObject:mapped ? @"retained previous" : @"unsupported"
                   forKey:@"status"];
        NSLog(@"Calendar resource %lld: %s (%@)", resource, mappingError.message,
              [update objectForKey:@"status"]);
      }
      [updates addObject:update];
      if (mapped) {
        NSEnumerator *keys = [mapped keyEnumerator];
        NSString *key;
        while ((key = [keys nextObject])) {
          NSDictionary *r = [mapped objectForKey:key];
          if ([[r objectForKey:ISyncRecordEntityNameKey] isEqual:Entity(@"Event")])
            [[[records objectForKey:calendarID] objectForKey:@"events"] addObject:key];
          [records setObject:r forKey:key];
        }
      }
    }
    if (step != SQLITE_DONE)
      goto sqlError;
    sqlite3_finalize(q);
    q = NULL;
    {
      ISyncManager *manager = [ISyncManager sharedManager];
      NSDictionary *description =
          [NSDictionary dictionaryWithContentsOfFile:String(descriptionPath)];
      NSArray *entities = [[description objectForKey:@"Entities"] allKeys];
      ISyncClient *client;
      NSEnumerator *keys;
      NSString *key;
      NSMutableArray *pull = [NSMutableArray array];
      if (![manager isEnabled] || ![entities count]) {
        RCErrorSet(error, 1,
                   "Calendar Sync Services or its client description is unavailable");
        goto done;
      }
      client = [manager registerClientWithIdentifier:clientID
                                 descriptionFilePath:String(descriptionPath)];
      if (!client) {
        RCErrorSet(error, 1, "Could not register calendar Sync Services client");
        goto done;
      }
      [client setEnabled:YES forEntityNames:entities];
      session = [ISyncSession
          beginSessionWithClient:client
                     entityNames:entities
                      beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
      if (!session) {
        RCErrorSet(error, 1, "Could not begin calendar Sync Services session");
        goto done;
      }
      [session clientWantsToPushAllRecordsForEntityNames:entities];
      keys = [records keyEnumerator];
      while ((key = [keys nextObject])) {
        NSDictionary *record = [records objectForKey:key];
        if (![session shouldPushChangesForEntityName:
                          [record objectForKey:ISyncRecordEntityNameKey]]) {
          RCErrorSet(error, 1, "Sync Services did not permit the calendar push");
          goto done;
        }
        [session pushChangesFromRecord:record withIdentifier:key];
      }
      keys = [entities objectEnumerator];
      while ((key = [keys nextObject]))
        if ([session shouldPullChangesForEntityName:key])
          [pull addObject:key];
      /* Push-only sessions still have to enter mingling before finishing. */
      if (![session
              prepareToPullChangesForEntityNames:pull
                                      beforeDate:
                                          [NSDate dateWithTimeIntervalSinceNow:60]]) {
        RCErrorSet(error, 1, "Calendar Sync Services could not mingle records");
        goto done;
      }
      if ([pull count]) {
        ISyncChange *change;
        NSEnumerator *changes;
        changes = [session changeEnumeratorForEntityNames:pull];
        while ((change = [changes nextObject]))
          if ([change type] != ISyncChangeTypeDelete)
            [session
                clientRefusedChangesForRecordWithIdentifier:[change recordIdentifier]];
        [session clientCommittedAcceptedChanges];
      }
      [session finishSyncing];
      session = nil;
    }
    /* IDs already live in SQLite before the session. If this commit fails,
       replay reconstructs exactly the same graph on the next attempt. */
    if (!RCCalendarStoreSQL(store, error, "BEGIN IMMEDIATE"))
      goto done;
    {
      NSEnumerator *it = [updates objectEnumerator];
      NSDictionary *update;
      if (sqlite3_prepare_v2(store->db,
                             "UPDATE calendar_resources SET "
                             "export_ical=COALESCE(?,export_ical),export_status=?,"
                             "export_error=? WHERE id=?",
                             -1, &q, NULL) != SQLITE_OK)
        goto sqlError;
      while ((update = [it nextObject])) {
        NSData *raw = [update objectForKey:@"raw"];
        sqlite3_reset(q);
        sqlite3_clear_bindings(q);
        if (raw)
          sqlite3_bind_blob(q, 1, [raw bytes], (int)[raw length], SQLITE_TRANSIENT);
        sqlite3_bind_text(q, 2, [[update objectForKey:@"status"] UTF8String], -1,
                          SQLITE_TRANSIENT);
        sqlite3_bind_text(q, 3, [[update objectForKey:@"error"] UTF8String], -1,
                          SQLITE_TRANSIENT);
        sqlite3_bind_int64(q, 4, [[update objectForKey:@"resource"] longLongValue]);
        if (sqlite3_step(q) != SQLITE_DONE)
          goto sqlError;
      }
      sqlite3_finalize(q);
      q = NULL;
    }
    if (!RCCalendarStoreSQL(
            store, error,
            "UPDATE accounts SET published_generation=%lld WHERE id=%lld;COMMIT",
            generation, store->account))
      goto done;
    if (count)
      *count = (long)[records count];
    success = 1;
    goto done;
  sqlError:
    RCErrorSet(error, 1, "Calendar export database error: %s",
               sqlite3_errmsg(store->db));
  } @catch (NSException *exception) {
    RCErrorSet(error, 1, "Calendar Sync Services: %s", [[exception reason] UTF8String]);
  }
done:
  sqlite3_finalize(q);
  if (session) {
    @try {
      [session cancelSyncing];
    } @catch (NSException *exception) {
      NSLog(@"Calendar session cancellation: %@", [exception reason]);
    }
  }
  if (!success && !sqlite3_get_autocommit(store->db))
    RCCalendarStoreSQL(store, NULL, "ROLLBACK");
  return success;
}
int RCSyncServicesUnregisterCalendarTestClient(RCError *error)
{
  @try {
    ISyncManager *manager = [ISyncManager sharedManager];
    ISyncClient *client = [manager clientWithIdentifier:testIdentifier];
    if (client)
      [manager unregisterClient:client];
    return 1;
  } @catch (NSException *exception) {
    RCErrorSet(error, 1, "Could not unregister calendar test client: %s",
               [[exception reason] UTF8String]);
  }
  return 0;
}
