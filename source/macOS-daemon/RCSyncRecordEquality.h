#ifndef RC_SYNC_RECORD_EQUALITY_H
#define RC_SYNC_RECORD_EQUALITY_H
#import <Foundation/Foundation.h>

/* Sync Services may omit empty properties when reconstructing a snapshot.
   Compare semantic records, while retaining the ordering of recurrence arrays
   (notably the parallel bydaydays/bydayfreq arrays). Only schema relationships
   known to be unordered are compared as sets. */
static inline BOOL RCNativeEmptyValue(id value)
{
  return !value || ([value respondsToSelector:@selector(length)] && [value length]==0) ||
      ([value isKindOfClass:[NSArray class]] && [value count]==0);
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
  while ((key=[it nextObject])) {
    id x=[a objectForKey:key], y=[b objectForKey:key];
    if ([[a objectForKey:@"com.apple.syncservices.RecordEntityName"] isEqual:@"com.apple.calendars.Event"] &&
        [[b objectForKey:@"com.apple.syncservices.RecordEntityName"] isEqual:@"com.apple.calendars.Event"]) {
      /* iCal owns this bookkeeping; it is not an editable DAV property.
         Keep it in native truth, without letting it gate PUT/receipt comparisons. */
      if ([key isEqual:@"com.apple.ical.uid"] || [key isEqual:@"com.apple.ical.sequence"] ||
          [key isEqual:@"invitationSequence"] || [key isEqual:@"invitationTimestamp"]) continue;
      id defaultValue=[key isEqual:@"all day"] ? (id)[NSNumber numberWithBool:NO] :
          [key isEqual:@"status"] ? @"none" : [key isEqual:@"classification"] ? @"public" : nil;
      if (defaultValue) { if (!x) x=defaultValue; if (!y) y=defaultValue; }
    }
    if (RCNativeEmptyValue(x) && RCNativeEmptyValue(y)) continue;
    if ([unordered containsObject:key] && [x isKindOfClass:[NSArray class]] && [y isKindOfClass:[NSArray class]]) {
      if ([[NSSet setWithArray:x] isEqual:[NSSet setWithArray:y]]) continue;
    } else if ([x isEqual:y]) continue;
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
