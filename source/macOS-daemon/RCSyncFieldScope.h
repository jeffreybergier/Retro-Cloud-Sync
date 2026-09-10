#ifndef RC_SYNC_FIELD_SCOPE_H
#define RC_SYNC_FIELD_SCOPE_H
#import "RCSyncRecordEquality.h"

/* A journaled scope describes the fields actually represented by an upload.
   Missing scopes are legacy whole-record receipts. An empty scope retains a
   read-only record on the server without acknowledging any local changes. */
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
static inline BOOL RCNativeScopeMatches(NSDictionary *current, NSDictionary *receipt, NSDictionary *scopes)
{
  NSEnumerator *it=[receipt keyEnumerator]; NSString *identifier;
  while ((identifier=[it nextObject])) {
    id expected=[receipt objectForKey:identifier];
    NSDictionary *record=[current objectForKey:identifier];
    NSArray *fields=[scopes objectForKey:identifier];
    if (expected==[NSNull null]) { if (record) return NO; continue; }
    if (fields && ![fields count]) continue;
    if (!record || !RCNativeRecordsEqual(RCNativeScopedRecord(record,fields),RCNativeScopedRecord(expected,fields))) return NO;
  }
  return YES;
}
/* Older contact receipts predate PHOTO import. Newly visible server images
   were never part of those receipts; do not strand a verified pre-upgrade
   write because its raw, previously opaque PHOTO is now mapped. An image
   present in the receipt or its scope still requires exact verification. */
static inline BOOL RCNativeUploadedGraphMatches(NSDictionary *current, NSDictionary *receipt, NSDictionary *scopes)
{
  NSMutableDictionary *represented=[NSMutableDictionary dictionaryWithDictionary:current];
  NSEnumerator *it=[receipt keyEnumerator]; NSString *identifier;
  while ((identifier=[it nextObject])) {
    NSDictionary *expected=[receipt objectForKey:identifier];
    if ([[expected objectForKey:@"com.apple.syncservices.RecordEntityName"] isEqual:@"com.apple.contacts.Contact"] &&
        ![expected objectForKey:@"image"] && ![[scopes objectForKey:identifier] containsObject:@"image"] &&
        [[represented objectForKey:identifier] objectForKey:@"image"]) {
      NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:[represented objectForKey:identifier]];
      [record removeObjectForKey:@"image"]; [represented setObject:record forKey:identifier];
    }
  }
  return RCNativeGraphsEqual(represented,receipt);
}
#endif
