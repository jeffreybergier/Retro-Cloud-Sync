#ifndef RC_AUTORELEASE_H
#define RC_AUTORELEASE_H
#import <Foundation/Foundation.h>

/* Tiger's fragile Objective-C runtime does not retain a thrown object while
   unwinding @finally. Move its autorelease to the enclosing pool before
   rethrowing; the normal @finally cleanup then safely releases nil. */
static inline void RCDrainPoolPreservingException(NSAutoreleasePool **pool, id exception)
{
  [exception retain];
  NSAutoreleasePool *inner=*pool;
  *pool=nil;
  [inner release];
  [exception autorelease];
}
#endif
