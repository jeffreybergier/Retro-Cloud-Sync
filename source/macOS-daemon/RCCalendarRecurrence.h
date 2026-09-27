#ifndef RC_CALENDAR_RECURRENCE_H
#define RC_CALENDAR_RECURRENCE_H
#import "RCCalendarTime.h"
static int RCNativeZoneOffset(void *context, const char *name, struct icaltimetype utc, int *offset)
{
  (void)context;
  NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
  NSTimeZone *zone=[NSTimeZone timeZoneWithName:[NSString stringWithUTF8String:name]];
  if(zone) *offset=[zone secondsFromGMTForDate:RCCalendarWallDate(utc,[NSTimeZone timeZoneForSecondsFromGMT:0])];
  int found=zone!=nil;
  [pool release]; return found;
}
static inline BOOL RCNeedsUTCProjection(icalcomponent *root, icalcomponent *event)
{
  return RCCalendarNeedsUTCProjection(root,event,RCNativeZoneOffset,NULL);
}
static inline BOOL RCPrepareCalendarProjection(icalcomponent *root, RCError *error)
{
  return RCCalendarPrepareProjection(root,RCNativeZoneOffset,NULL,error);
}
#endif
