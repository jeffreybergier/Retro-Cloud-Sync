#ifndef RC_CONTACT_DATES_H
#define RC_CONTACT_DATES_H
#import "RCPlatformDate.h"

/* AddressBook dates are civil dates in the native timezone. The wire graph
   represents their year/month/day at noon UTC. Never use this conversion for
   calendar events or compare dates with a +/- 24 hour tolerance.
   Returns an autoreleased date; callers keep work on the store's owner thread. */
static inline id RCContactDateInZone(id value, NSTimeZone *from,
    NSTimeZone *to)
{
  if (![value isKindOfClass:[NSDate class]]) return value;
  NSCalendar *calendar = [[[NSCalendar alloc]
      initWithCalendarIdentifier:NSGregorianCalendar] autorelease];
  [calendar setTimeZone:from];
  NSDateComponents *parts = [calendar components:
      NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit
      fromDate:value];
  NSDate *result=[RCCalendarDate dateWithYear:[parts year] month:[parts month]
      day:[parts day] hour:12 minute:0 second:0 timeZone:to];
  if(!result) return nil;
  [calendar setTimeZone:to];
  NSDateComponents *check=[calendar components:
      NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit
      fromDate:result];
  /* A timezone can skip a whole civil day (e.g. a dateline transition).
     Refuse a rounded date instead of silently changing the birthday. */
  return [parts year]==[check year] && [parts month]==[check month] &&
      [parts day]==[check day] ? result : nil;
}

static inline id RCContactDateFromNative(id value, NSTimeZone *zone)
{
  return RCContactDateInZone(value, zone,
      [NSTimeZone timeZoneForSecondsFromGMT:0]);
}

static inline id RCContactDateToNative(id value, NSTimeZone *zone)
{
  return RCContactDateInZone(value,
      [NSTimeZone timeZoneForSecondsFromGMT:0], zone);
}
#endif
