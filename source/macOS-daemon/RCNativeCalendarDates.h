#ifndef RC_NATIVE_CALENDAR_DATES_H
#define RC_NATIVE_CALENDAR_DATES_H
#import <Foundation/Foundation.h>
#import "RCTwoWaySync.h"
#import <TargetConditionals.h>
#include <math.h>
/* Mavericks persists recurrence ends as signed 32-bit seconds from 2001,
   even in its 64-bit EventKit API. The in-memory object does not round-trip
   through that storage until a fresh read. Do not truncate or clamp dates. */
static inline BOOL RCNativeRecurrenceEndFits32Bits(NSDate *date)
{
  if(!date) return YES;
  double seconds=[date timeIntervalSinceReferenceDate];
  return isfinite(seconds) && seconds>=-2147483648.0 && seconds<=2147483647.0;
}
/* Diagnose only the exact overflow signature. This never authorizes a save,
   clears attention, or treats unrelated local differences as unchanged. */
static inline BOOL RCNativeCalendarRecurrenceOverflow(NSDictionary *before,
    NSDictionary *after,NSString *root)
{
  NSMutableDictionary *normalized=[NSMutableDictionary dictionaryWithDictionary:after];
  BOOL found=NO;
  for(NSString *key in [[before objectForKey:root] objectForKey:@"recurrences"]) {
    NSDictionary *old=[before objectForKey:key], *now=[after objectForKey:key];
    NSDate *wanted=[old objectForKey:@"until"], *actual=[now objectForKey:@"until"];
    if(wanted && actual && !RCNativeRecurrenceEndFits32Bits(wanted) &&
        [actual timeIntervalSinceReferenceDate]==-2147483648.0) {
      NSMutableDictionary *rule=[NSMutableDictionary dictionaryWithDictionary:now];
      [rule setObject:wanted forKey:@"until"]; [normalized setObject:rule forKey:key]; found=YES;
    }
  }
  return found && RCTwoWayGraphsEqual(before,normalized);
}
/* Check persisted dates before acknowledging a native save. Other projection
   differences (e.g. implicit default alarms) have their own guarded handling. */
static inline BOOL RCNativeCalendarDatesEqual(NSDictionary *before,
    NSDictionary *after,NSString *root)
{
  NSDictionary *old=[before objectForKey:root], *now=[after objectForKey:root];
  if(!old || !now) return NO;
  for(NSString *key in [NSArray arrayWithObjects:@"start date",@"end date",nil])
    if(![[old objectForKey:key] isEqual:[now objectForKey:key]]) return NO;
  NSArray *rules=[old objectForKey:@"recurrences"];
  if(![rules isEqual:[now objectForKey:@"recurrences"]]) return NO;
  for(NSString *key in before) {
    for(NSString *field in [NSArray arrayWithObjects:@"until",@"triggerdate",nil]) {
      id a=[[before objectForKey:key] objectForKey:field], b=[[after objectForKey:key] objectForKey:field];
      if(a!=b && ![a isEqual:b]) return NO;
    }
  }
  return YES;
}
#endif
