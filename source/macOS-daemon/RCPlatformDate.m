#import "RCPlatformDate.h"
#if TARGET_OS_IPHONE
static NSDateFormatter *Formatter(NSString *format,NSTimeZone *zone)
{
  NSDictionary *formats=[NSDictionary dictionaryWithObjectsAndKeys:
      @"yyyy-MM-dd",@"%Y-%m-%d",@"yyyyMMdd",@"%Y%m%d",
      @"yyyyMMdd'T'HHmmss",@"%Y%m%dT%H%M%S",@"yyyyMMdd'T'HHmmss'Z'",@"%Y%m%dT%H%M%SZ",nil];
  NSString *pattern=[formats objectForKey:format];
  if(!pattern) [NSException raise:NSInvalidArgumentException format:@"Unsupported wire date format"];
  NSDateFormatter *f=[[[NSDateFormatter alloc] init] autorelease];
  [f setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
  [f setCalendar:[[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease]];
  [f setTimeZone:zone ?: [NSTimeZone defaultTimeZone]];
  [f setDateFormat:pattern]; [f setLenient:NO]; return f;
}
@implementation RCCalendarDate
- (id)initWithTimeIntervalSinceReferenceDate:(NSTimeInterval)t {
  self=[super init]; if(self) { instant_=t; zone_=[[NSTimeZone defaultTimeZone] retain]; } return self;
}
- (NSTimeInterval)timeIntervalSinceReferenceDate { return instant_; }
- (void)dealloc { [zone_ release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone {
  RCCalendarDate *d=[[RCCalendarDate allocWithZone:zone] initWithTimeIntervalSinceReferenceDate:instant_];
  [d setTimeZone:zone_]; return d;
}
- (Class)classForCoder { return [RCCalendarDate class]; }
- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeDouble:instant_ forKey:@"instant"];
  [coder encodeBool:zone_==[NSTimeZone localTimeZone] forKey:@"floating"];
  [coder encodeObject:zone_ forKey:@"zone"];
}
- (id)initWithCoder:(NSCoder *)coder {
  self=[super init];
  if(self) instant_=[coder decodeDoubleForKey:@"instant"];
  if(self) [self setTimeZone:[coder decodeBoolForKey:@"floating"] ? [NSTimeZone localTimeZone] : [coder decodeObjectForKey:@"zone"]];
  return self;
}
- (NSTimeZone *)timeZone { return zone_; }
- (void)setTimeZone:(NSTimeZone *)zone { [zone retain]; [zone_ release]; zone_=zone; }
+ (id)dateWithYear:(NSInteger)y month:(NSUInteger)m day:(NSUInteger)d hour:(NSUInteger)h minute:(NSUInteger)n second:(NSUInteger)s timeZone:(NSTimeZone *)zone {
  NSCalendar *c=[[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease]; [c setTimeZone:zone];
  NSDateComponents *parts=[[[NSDateComponents alloc] init] autorelease];
  [parts setYear:y]; [parts setMonth:m]; [parts setDay:d]; [parts setHour:h]; [parts setMinute:n]; [parts setSecond:s];
  NSDate *date=[c dateFromComponents:parts]; if(!date) return nil;
  RCCalendarDate *result=[[[self alloc] initWithTimeIntervalSinceReferenceDate:[date timeIntervalSinceReferenceDate]] autorelease];
  [result setTimeZone:zone]; return result;
}
+ (id)dateWithString:(NSString *)text calendarFormat:(NSString *)format {
  NSDate *date=[Formatter(format,nil) dateFromString:text];
  return date ? [[[self alloc] initWithTimeIntervalSinceReferenceDate:[date timeIntervalSinceReferenceDate]] autorelease] : nil;
}
- (NSDateComponents *)parts {
  NSCalendar *c=[[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease]; [c setTimeZone:zone_];
  return [c components:NSYearCalendarUnit|NSMonthCalendarUnit|NSDayCalendarUnit|NSHourCalendarUnit|NSMinuteCalendarUnit|NSSecondCalendarUnit fromDate:self];
}
- (NSInteger)yearOfCommonEra { return [[self parts] year]; }
- (NSInteger)monthOfYear { return [[self parts] month]; }
- (NSInteger)dayOfMonth { return [[self parts] day]; }
- (NSInteger)hourOfDay { return [[self parts] hour]; }
- (NSInteger)minuteOfHour { return [[self parts] minute]; }
- (NSInteger)secondOfMinute { return [[self parts] second]; }
@end
#endif
@implementation NSDate (RCPlatformFormatting)
- (NSString *)rc_descriptionWithCalendarFormat:(NSString *)format timeZone:(NSTimeZone *)zone locale:(id)locale {
#if TARGET_OS_IPHONE
  (void)locale; return [Formatter(format,zone) stringFromDate:self];
#else
  return [self descriptionWithCalendarFormat:format timeZone:zone locale:locale];
#endif
}
@end
