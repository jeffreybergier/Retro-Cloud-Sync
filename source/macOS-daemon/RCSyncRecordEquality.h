#ifndef RC_SYNC_RECORD_EQUALITY_H
#define RC_SYNC_RECORD_EQUALITY_H
#import <Foundation/Foundation.h>

/* Sync Services may omit empty properties when reconstructing a snapshot.
   Compare semantic records, while retaining the ordering of recurrence arrays
   (notably the parallel bydaydays/bydayfreq arrays). Only schema relationships
   known to be unordered are compared as sets. */
static inline BOOL RCNativeEmptyValue(id value)
{
  if ([value isKindOfClass:[NSURL class]]) return [[value absoluteString] length]==0;
  return !value || ([value respondsToSelector:@selector(length)] && [value length]==0) ||
      ([value isKindOfClass:[NSArray class]] && [value count]==0);
}
/* Defaults belong to individual schema fields. In particular, a missing
   trigger is not a zero-second trigger, and a missing record is not empty. */
static inline id RCNativeDefaultValue(NSString *entity, NSString *key)
{
  if ([entity isEqual:@"com.apple.calendars.Event"]) {
    /* The forward mapper supplies this title when SUMMARY is absent. */
    if ([key isEqual:@"summary"]) return @"Untitled event";
    if ([key isEqual:@"all day"]) return [NSNumber numberWithBool:NO];
    if ([key isEqual:@"status"]) return @"none";
    if ([key isEqual:@"classification"]) return @"public";
  } else if ([entity isEqual:@"com.apple.calendars.Attendee"]) {
    if ([key isEqual:@"rsvp"]) return [NSNumber numberWithBool:NO];
    if ([key isEqual:@"role"]) return @"requiredparticipant";
    if ([key isEqual:@"status"]) return @"needsaction";
    if ([key isEqual:@"user type"]) return @"individual";
  } else if ([entity isEqual:@"com.apple.contacts.Contact"]) {
    if ([key isEqual:@"display as company"]) return @"person";
  } else if ([entity isEqual:@"com.apple.contacts.Phone Number"] ||
      [entity isEqual:@"com.apple.contacts.Email Address"] ||
      [entity isEqual:@"com.apple.contacts.Street Address"] ||
      [entity isEqual:@"com.apple.contacts.URL"]) {
    if ([key isEqual:@"type"]) return @"other";
  }
  return nil;
}
static inline BOOL RCNativePropertyValuesEqual(NSString *entity, NSString *key, id x, id y)
{
  id defaultValue=RCNativeDefaultValue(entity,key);
  if (defaultValue) {
    if (RCNativeEmptyValue(x)) x=defaultValue;
    if (RCNativeEmptyValue(y)) y=defaultValue;
  }
  return (RCNativeEmptyValue(x) && RCNativeEmptyValue(y)) || [x isEqual:y];
}
/* Tiger NSCalendarDate hashes can differ across timezones for the same
   instant. Canonicalize dates before hashing unordered relationship values. */
static inline NSSet *RCNativeUnorderedValues(NSArray *values)
{
  NSMutableSet *result=[NSMutableSet set]; NSEnumerator *it=[values objectEnumerator]; id value;
  while ((value=[it nextObject])) {
    if ([value isKindOfClass:[NSDate class]]) value=[NSDate dateWithTimeIntervalSinceReferenceDate:[value timeIntervalSinceReferenceDate]];
    [result addObject:value];
  }
  return result;
}
static inline BOOL RCNativeRecordsEqual(NSDictionary *a, NSDictionary *b)
{
  if (!a || !b) return a==b;
  NSSet *unordered=[NSSet setWithObjects:@"phone numbers",@"email addresses",@"street addresses",@"URLs",
      @"events",@"tasks",@"detached events",@"exception dates",@"attendees",@"organizer",@"recurrences",
      @"display alarms",@"audio alarms",@"mail alarms",nil];
  NSMutableSet *keys=[NSMutableSet setWithArray:[a allKeys]];
  [keys addObjectsFromArray:[b allKeys]];
  NSEnumerator *it=[keys objectEnumerator]; NSString *key;
  NSString *entity=[a objectForKey:@"com.apple.syncservices.RecordEntityName"];
  if (![entity isEqual:[b objectForKey:@"com.apple.syncservices.RecordEntityName"]]) entity=nil;
  while ((key=[it nextObject])) {
    id x=[a objectForKey:key], y=[b objectForKey:key];
    if ([[a objectForKey:@"com.apple.syncservices.RecordEntityName"] isEqual:@"com.apple.calendars.Event"] &&
        [[b objectForKey:@"com.apple.syncservices.RecordEntityName"] isEqual:@"com.apple.calendars.Event"]) {
      /* iCal owns this bookkeeping; it is not an editable DAV property.
         Keep it in native truth, without letting it gate PUT/receipt comparisons. */
      if ([key isEqual:@"com.apple.ical.uid"] || [key isEqual:@"com.apple.ical.sequence"] ||
          [key isEqual:@"invitationId"] || [key isEqual:@"invitationSequence"] || [key isEqual:@"invitationTimestamp"]) continue;
    }
    if (RCNativePropertyValuesEqual(entity,key,x,y)) continue;
    if ([unordered containsObject:key] && [x isKindOfClass:[NSArray class]] && [y isKindOfClass:[NSArray class]]) {
      if ([RCNativeUnorderedValues(x) isEqual:RCNativeUnorderedValues(y)]) continue;
    }
    return NO;
  }
  return YES;
}
static inline BOOL RCNativeGraphsEqual(NSDictionary *a, NSDictionary *b)
{
  if (!a || !b) return a==b;
  if ([a count]!=[b count]) return NO;
  NSEnumerator *it=[a keyEnumerator]; NSString *key;
  while ((key=[it nextObject])) if (!RCNativeRecordsEqual([a objectForKey:key],[b objectForKey:key])) return NO;
  return YES;
}
#endif
