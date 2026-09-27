#ifndef RC_CALENDAR_TIME_H
#define RC_CALENDAR_TIME_H
#import <Foundation/Foundation.h>
#include "RCICalendar.h"

/* Tiger's iCal uses this public Foundation singleton as the floating-date
   marker. A system/default timezone is not interchangeable with it. */
static inline BOOL RCCalendarFloatingDate(id date)
{
  return [date isKindOfClass:[NSCalendarDate class]] &&
      [date timeZone]==[NSTimeZone localTimeZone];
}
#include "RCCalendarProjection.h"
static inline NSCalendarDate *RCCalendarWallDate(struct icaltimetype t, NSTimeZone *zone)
{
  return [NSCalendarDate dateWithYear:t.year month:t.month day:t.day
      hour:t.hour minute:t.minute second:t.second timeZone:zone];
}
/* Reverse conversion always uses the original resource's timezone rules,
   never Tiger's possibly older rules for a matching TZID string. */
static inline NSString *RCCalendarWireDate(NSDate *date, BOOL allDay,
    icalcomponent *root, icalproperty *property, RCError *error)
{
  if(![date isKindOfClass:[NSDate class]]) return nil;
  NSTimeZone *utc=[NSTimeZone timeZoneForSecondsFromGMT:0];
  if(allDay) return [date descriptionWithCalendarFormat:@"%Y%m%d" timeZone:utc locale:nil];
  const char *tz=RCICalendarTZID(property);
  const char *value=property ? icalproperty_get_value_as_string(property) : NULL;
  BOOL floating=value && *value && !tz && value[strlen(value)-1]!='Z';
  if(floating) {
    if(!RCCalendarFloatingDate(date)) { RCErrorSet(error,1,"Floating date lost its native timezone marker"); return nil; }
    return [date descriptionWithCalendarFormat:@"%Y%m%dT%H%M%S" timeZone:[NSTimeZone localTimeZone] locale:nil];
  }
  NSString *text=[date descriptionWithCalendarFormat:@"%Y%m%dT%H%M%SZ" timeZone:utc locale:nil];
  if(!tz) return text;
  icaltimezone *zone=RCCalendarSourceZone(root,property);
  if(!zone) { RCErrorSet(error,1,"Event timezone is unavailable"); return nil; }
  struct icaltimetype t=icaltime_from_string([text UTF8String]); int daylight=0;
  int offset=icaltimezone_get_utc_offset_of_utc_time(zone,&t,&daylight);
  return [date descriptionWithCalendarFormat:@"%Y%m%dT%H%M%S"
      timeZone:[NSTimeZone timeZoneForSecondsFromGMT:offset] locale:nil];
}
#endif
