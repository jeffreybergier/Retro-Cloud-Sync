#import "XPAppKit.h"

@implementation NSWindow (RCDisplayCompatibility)
- (CGFloat)XP_backingScaleFactor;
{
  SEL selector=NSSelectorFromString(@"backingScaleFactor");
  if(![self respondsToSelector:selector]) return 1.0;
  NSMethodSignature *signature=[self methodSignatureForSelector:selector];
  if(!signature) return 1.0;
  NSInvocation *invocation=[NSInvocation invocationWithMethodSignature:signature];
  CGFloat scale=1.0;
  [invocation setTarget:self]; [invocation setSelector:selector];
  [invocation invoke]; [invocation getReturnValue:&scale];
  return scale>0.0 ? scale : 1.0;
}
@end
