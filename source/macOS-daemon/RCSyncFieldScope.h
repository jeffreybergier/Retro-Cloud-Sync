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
#endif
