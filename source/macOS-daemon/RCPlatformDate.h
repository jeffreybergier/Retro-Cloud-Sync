#ifndef RC_PLATFORM_DATE_H
#define RC_PLATFORM_DATE_H
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
/* NSDate plus the timezone/floating marker that SyncServices graphs retain.
   iOS has no NSCalendarDate. Persist the marker explicitly across restarts. */
@interface RCCalendarDate : NSDate {
  NSTimeInterval instant_;
  NSTimeZone *zone_;
}
+ (id)dateWithYear:(NSInteger)y month:(NSUInteger)m day:(NSUInteger)d hour:(NSUInteger)h minute:(NSUInteger)n second:(NSUInteger)s timeZone:(NSTimeZone *)zone;
+ (id)dateWithString:(NSString *)text calendarFormat:(NSString *)format;
- (NSTimeZone *)timeZone;
- (void)setTimeZone:(NSTimeZone *)zone;
- (NSInteger)yearOfCommonEra;
- (NSInteger)monthOfYear;
- (NSInteger)dayOfMonth;
- (NSInteger)hourOfDay;
- (NSInteger)minuteOfHour;
- (NSInteger)secondOfMinute;
@end
#else
@compatibility_alias RCCalendarDate NSCalendarDate;
#endif
@interface NSDate (RCPlatformFormatting)
- (NSString *)rc_descriptionWithCalendarFormat:(NSString *)format timeZone:(NSTimeZone *)zone locale:(id)locale;
@end
#endif
