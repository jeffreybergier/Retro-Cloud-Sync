#ifndef RC_NATIVE_GRAPH_CHANGES_H
#define RC_NATIVE_GRAPH_CHANGES_H
#import "RCSyncRecordEquality.h"

static inline NSDictionary *RCChangedGraph(NSDictionary *base,NSDictionary *snapshot,NSDictionary *current)
{
  /* Native stores normalize images, default labels, timezones and empty values.
     Compare against their readback, then apply only real edits to the wire graph. */
  NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:base];
  NSMutableSet *ids=[NSMutableSet setWithArray:[snapshot allKeys]]; [ids addObjectsFromArray:[current allKeys]];
  NSEnumerator *it=[ids objectEnumerator]; NSString *key;
  while((key=[it nextObject])) {
    NSDictionary *old=[snapshot objectForKey:key], *now=[current objectForKey:key];
    if(!now) { [result removeObjectForKey:key]; continue; }
    if(!old) { [result setObject:now forKey:key]; continue; }
    /* A native-only default is part of the readback baseline, not the wire
       graph. Its unchanged presence must not manufacture a cloud alarm. */
    if(![base objectForKey:key] && RCNativeRecordsEqual(old,now)) continue;
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:[base objectForKey:key] ?: old];
    NSMutableSet *fields=[NSMutableSet setWithArray:[old allKeys]]; [fields addObjectsFromArray:[now allKeys]];
    NSEnumerator *f=[fields objectEnumerator]; NSString *field;
    while((field=[f nextObject])) {
      id a=[old objectForKey:field],b=[now objectForKey:field];
      if(a==b || [a isEqual:b]) continue;
      if(([field isEqual:@"display alarms"] || [field isEqual:@"audio alarms"]) && [b isKindOfClass:[NSArray class]]) {
        NSMutableArray *wire=[NSMutableArray array];
        NSEnumerator *children=[b objectEnumerator]; NSString *child;
        while((child=[children nextObject])) {
          NSDictionary *prior=[snapshot objectForKey:child], *value=[current objectForKey:child];
          if(![base objectForKey:child] && prior && RCNativeRecordsEqual(prior,value)) continue;
          [wire addObject:child];
        }
        b=wire;
      }
      if(b) [record setObject:b forKey:field];
      else [record removeObjectForKey:field];
    }
    [result setObject:record forKey:key];
  }
  return result;
}
#endif
