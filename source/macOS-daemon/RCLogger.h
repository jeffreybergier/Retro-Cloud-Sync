#ifndef RC_LOGGER_H
#define RC_LOGGER_H
#include "RCLogLevel.h"

/* Synchronous, thread-safe NSLog sink. NULL service inherits this thread's
   context. No Foundation objects or autorelease pool are needed by C callers.
   DEBUG is enabled by RETROCLOUDSYNC_LOG_LEVEL=DEBUG at process startup. */
void RCLoggerSetContext(const char *service, unsigned long poll);
void RCLoggerSetConnection(const char *service, unsigned long connection);
void RCLoggerC(RCLogLevel level, const char *service, const char *phase,
               const char *format, ...) __attribute__((format(printf, 4, 5)));
#ifdef __OBJC__
#import <Foundation/Foundation.h>
void RCLogger(RCLogLevel level, const char *service, const char *phase,
              NSString *format, ...) __attribute__((format(__NSString__, 4, 5)));
#endif
#endif
