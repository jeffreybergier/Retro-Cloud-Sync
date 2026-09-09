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
/* Leopard exposes system sound names, Tiger exposes attachment URLs. Keep
   this normalization shared by encoding, validation and acknowledgement. Never
   invent a default for an absent sound or reinterpret custom attachment URLs. */
static inline NSURL *RCNativeLocalSoundURL(NSURL *url)
{
  NSString *value=[url absoluteString];
  if ([value hasPrefix:@"file://localhost/"])
    return [NSURL URLWithString:[@"file://" stringByAppendingString:[value substringFromIndex:16]]];
  return url;
}
static inline NSURL *RCNativeAlarmSound(NSDictionary *record, BOOL *valid)
{
  id url=[record objectForKey:@"com.apple.ical.sound"], name=[record objectForKey:@"sound"];
  *valid=YES;
  if (RCNativeEmptyValue(url)) url=nil;
  if (RCNativeEmptyValue(name)) name=nil;
  if (url && (![url isKindOfClass:[NSURL class]] ||
      [[url absoluteString] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location!=NSNotFound)) {
    *valid=NO; return nil;
  }
  url=RCNativeLocalSoundURL(url);
  if (name) {
    if (![name isKindOfClass:[NSString class]] || [name isEqual:@"."] || [name isEqual:@".."] ||
        [name rangeOfString:@"/"].location!=NSNotFound ||
        [name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location!=NSNotFound) {
      *valid=NO; return nil;
    }
    /* iCal also echoes ATTACH;VALUE=URI:Basso as an NSURL containing
       "Basso" plus the Leopard string "Basso". Preserve that relative URI;
       expanding it to a system path would change the wire representation and
       incorrectly reject the matching pair during validation. */
    if (url && ![url scheme] && ![url baseURL] && [[url absoluteString] isEqual:name]) return url;
    NSURL *named=[NSURL fileURLWithPath:[@"/System/Library/Sounds" stringByAppendingPathComponent:[name stringByAppendingString:@".aiff"]]];
    named=RCNativeLocalSoundURL(named);
    if (url && ![url isEqual:named]) { *valid=NO; return nil; }
    url=named;
  }
  return url;
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
  if ([entity isEqual:@"com.apple.calendars.AudioAlarm"]) {
    BOOL av,bv; NSURL *as=RCNativeAlarmSound(a,&av), *bs=RCNativeAlarmSound(b,&bv);
    if (av && bv) {
      if (!((!as && !bs) || [as isEqual:bs])) return NO;
      [keys removeObject:@"sound"]; [keys removeObject:@"com.apple.ical.sound"];
      it=[keys objectEnumerator];
    }
  }
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
