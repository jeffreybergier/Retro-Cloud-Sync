#include "RCMailProxyLog.h"
#import <Foundation/Foundation.h>

void RCMailProxyLogMessage(const char *message)
{
  if (message == NULL) return;

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSString *text = [[NSString alloc] initWithUTF8String:message];

  NSLog(@"%@", text != nil ? text : @"[Invalid UTF-8 mail proxy log message]");

  [text release];
  [pool release];
}
