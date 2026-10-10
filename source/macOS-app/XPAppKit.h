#import <AppKit/AppKit.h>

@interface NSWindow (RCDisplayCompatibility)
- (CGFloat)XP_backingScaleFactor;
@end

/* Floating-point messages to nil are undefined on the legacy Objective-C ABI. */
static inline CGFloat RCWindowBackingScale(NSWindow *window)
{
  return window != nil ? [window XP_backingScaleFactor] : 1.0;
}
