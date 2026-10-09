#import "RCPlatformDate.h"
#ifndef RC_SYNC_RECORD_EQUALITY_H
#define RC_SYNC_RECORD_EQUALITY_H
#import <Foundation/Foundation.h>
#include "RCSyncPolicy.h"

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
  RCFieldDefault value=RCSyncFieldDefault([entity UTF8String],[key UTF8String]);
  if(!value.present) return nil;
  return value.text ? (id)[NSString stringWithUTF8String:value.text] : (id)[NSNumber numberWithInt:value.number];
}
static inline BOOL RCNativeFloatingDate(id value)
{
  return [value isKindOfClass:[RCCalendarDate class]] && [value timeZone]==[NSTimeZone localTimeZone];
}
static inline NSString *RCNativeFloatingWallTime(NSDate *value)
{
  return [value rc_descriptionWithCalendarFormat:@"%Y%m%dT%H%M%S" timeZone:[NSTimeZone localTimeZone] locale:nil];
}
static inline BOOL RCNativePropertyValuesEqual(NSString *entity, NSString *key, id x, id y)
{
  if([entity hasPrefix:@"com.apple.calendars."] && (RCNativeFloatingDate(x) || RCNativeFloatingDate(y)))
    return RCNativeFloatingDate(x) && RCNativeFloatingDate(y) &&
        [RCNativeFloatingWallTime(x) isEqual:RCNativeFloatingWallTime(y)];
  id defaultValue=RCNativeDefaultValue(entity,key);
  if (defaultValue) {
    if (RCNativeEmptyValue(x)) x=defaultValue;
    if (RCNativeEmptyValue(y)) y=defaultValue;
  }
  return (RCNativeEmptyValue(x) && RCNativeEmptyValue(y)) || [x isEqual:y];
}
/* Tiger RCCalendarDate hashes can differ across timezones for the same
   instant. Canonicalize dates before hashing unordered relationship values. */
static inline NSSet *RCNativeUnorderedValues(NSArray *values)
{
  NSMutableSet *result=[NSMutableSet set]; NSEnumerator *it=[values objectEnumerator]; id value;
  while ((value=[it nextObject])) {
    if (RCNativeFloatingDate(value)) value=[@"floating:" stringByAppendingString:RCNativeFloatingWallTime(value)];
    else if ([value isKindOfClass:[NSDate class]]) value=[NSDate dateWithTimeIntervalSinceReferenceDate:[value timeIntervalSinceReferenceDate]];
    [result addObject:value];
  }
  return result;
}
static inline NSDictionary *RCNativeScopedRecord(NSDictionary *record, NSArray *fields)
{
  if (!record || !fields) return record;
  NSMutableDictionary *result=[NSMutableDictionary dictionary];
  NSEnumerator *it=[fields objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) if ([record objectForKey:key])
    [result setObject:[record objectForKey:key] forKey:key];
  if ([record objectForKey:@"com.apple.syncservices.RecordEntityName"])
    [result setObject:[record objectForKey:@"com.apple.syncservices.RecordEntityName"] forKey:@"com.apple.syncservices.RecordEntityName"];
  return result;
}
static inline BOOL RCNativeRecordsEqual(NSDictionary *a, NSDictionary *b);
static size_t RCRecordCount(RCRecord r) { return [(id)r count]; }
static void *RCRecordKeys(RCRecord r) { return [(id)r keyEnumerator]; }
static RCRecord RCRecordNext(void *it) { return [(id)it nextObject]; }
static RCRecord RCRecordGet(RCRecord r,RCRecord key) { return [(id)r objectForKey:(id)key]; }
static const char *RCRecordText(RCRecord r) { return [(id)r UTF8String]; }
static const char *RCRecordEntity(RCRecord r) { return [[(id)r objectForKey:@"com.apple.syncservices.RecordEntityName"] UTF8String]; }
static int RCRecordPropertyEqual(const char *entity,const char *key,RCRecord a,RCRecord b)
{
  return RCNativePropertyValuesEqual(entity ? [NSString stringWithUTF8String:entity] : nil,
      [NSString stringWithUTF8String:key],(id)a,(id)b);
}
static int RCRecordUnorderedEqual(RCRecord a,RCRecord b)
{
  return [(id)a isKindOfClass:[NSArray class]] && [(id)b isKindOfClass:[NSArray class]] &&
      [RCNativeUnorderedValues((id)a) isEqual:RCNativeUnorderedValues((id)b)];
}
static int RCRecordAlarmEqual(RCRecord a,RCRecord b)
{
  BOOL av,bv; NSURL *as=RCNativeAlarmSound((id)a,&av), *bs=RCNativeAlarmSound((id)b,&bv);
  if(!av || !bv) return -1;
  return (!as && !bs) || [as isEqual:bs];
}
static int RCRecordTombstone(RCRecord r) { return (id)r==[NSNull null]; }
static int RCRecordScopedEqual(RCRecord a,RCRecord b,RCRecord fields)
{
  return RCNativeRecordsEqual(RCNativeScopedRecord((id)a,(id)fields),RCNativeScopedRecord((id)b,(id)fields));
}
static inline const RCRecordAccess *RCNativeRecordAccess(void)
{
  static const RCRecordAccess access={RCRecordCount,RCRecordKeys,RCRecordNext,RCRecordGet,
      RCRecordText,RCRecordEntity,RCRecordPropertyEqual,RCRecordUnorderedEqual,RCRecordAlarmEqual,
      RCRecordTombstone,RCRecordScopedEqual};
  return &access;
}
static inline BOOL RCNativeRecordsEqual(NSDictionary *a, NSDictionary *b)
{
  return RCRecordsEqual(a,b,RCNativeRecordAccess());
}
static inline BOOL RCNativeGraphsEqual(NSDictionary *a, NSDictionary *b)
{
  return RCGraphsEqual(a,b,RCNativeRecordAccess());
}
#endif
