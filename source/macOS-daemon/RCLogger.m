#import "RCLogger.h"
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char service[32]; unsigned long poll; unsigned long connection; } RCLogContext;
static pthread_key_t contextKey;
static pthread_once_t loggerOnce = PTHREAD_ONCE_INIT;
static int contextKeyReady;
static int debugEnabled;

static void RCLoggerInitialize(void)
{
  const char *level = getenv("RETROCLOUDSYNC_LOG_LEVEL");
  debugEnabled = level != NULL && strcmp(level, "DEBUG") == 0;
  contextKeyReady = pthread_key_create(&contextKey, free) == 0;
}

void RCLoggerSetContext(const char *service, unsigned long poll)
{
  int savedError = errno;
  RCLogContext *context;
  pthread_once(&loggerOnce, RCLoggerInitialize);
  if (contextKeyReady) {
    context = pthread_getspecific(contextKey);
    if (context == NULL) {
      context = calloc(1, sizeof(*context));
      if (context && pthread_setspecific(contextKey, context) != 0) {
        free(context); context = NULL;
      }
    }
    if (context) {
      snprintf(context->service, sizeof(context->service), "%s", service ?: "Daemon");
      context->poll = poll;
      context->connection = 0;
    }
  }
  errno = savedError;
}

void RCLoggerSetConnection(const char *service, unsigned long connection)
{
  int savedError = errno;
  RCLoggerSetContext(service, 0);
  RCLogContext *context = contextKeyReady ? pthread_getspecific(contextKey) : NULL;
  if (context) context->connection = connection;
  errno = savedError;
}

/* External details cannot insert extra log lines; cap output without splitting
   UTF-16 surrogate pairs. Never use a message as an NSLog format string. */
static NSString *RCLogClean(NSString *text)
{
  NSMutableString *clean = [NSMutableString string];
  NSUInteger i, length = [text length], limit = MIN(length, (NSUInteger)2048);
  if (limit < length && limit > 0) {
    unichar last = [text characterAtIndex:limit - 1];
    if (last >= 0xD800 && last <= 0xDBFF) limit--;
  }
  for (i = 0; i < limit; i++) {
    unichar ch = [text characterAtIndex:i];
    if (ch < 0x20 || (ch >= 0x7F && ch <= 0x9F) || ch == 0x2028 || ch == 0x2029)
      [clean appendString:@" "];
    else [clean appendString:[NSString stringWithCharacters:&ch length:1]];
  }
  if (limit < length) [clean appendString:@" [truncated]"];
  return clean;
}

static void RCLogEmit(RCLogLevel level, const char *service, const char *phase,
                      NSString *message)
{
  static const char *names[] = { "DEBUG", "INFO", "WARN", "ERROR" };
  RCLogContext *context = contextKeyReady ? pthread_getspecific(contextKey) : NULL;
  if (service == NULL) service = context ? context->service : "Sync";
  NSString *scope = [NSString stringWithUTF8String:service];
  NSString *stage = phase ? [NSString stringWithUTF8String:phase] : nil;
  NSMutableString *prefix = [NSMutableString stringWithFormat:@"%s [%@]",
      names[(unsigned int)level <= RCLogError ? level : RCLogError],
      RCLogClean(scope ?: @"Unknown")];
  if (stage) [prefix appendFormat:@"[%@]", RCLogClean(stage)];
  if (context && context->poll) [prefix appendFormat:@"[poll=%lu]", context->poll];
  if (context && context->connection) [prefix appendFormat:@"[connection=%lu]", context->connection];
  NSLog(@"%@ %@", prefix, RCLogClean(message ?: @"Invalid UTF-8 log message"));
}

void RCLogger(RCLogLevel level, const char *service, const char *phase,
              NSString *format, ...)
{
  int savedError = errno;
  pthread_once(&loggerOnce, RCLoggerInitialize);
  if (level != RCLogDebug || debugEnabled) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RCLogEmit(level, service, phase, message);
    [message release];
    [pool release];
  }
  errno = savedError;
}

void RCLoggerC(RCLogLevel level, const char *service, const char *phase,
               const char *format, ...)
{
  int savedError = errno;
  pthread_once(&loggerOnce, RCLoggerInitialize);
  if (level != RCLogDebug || debugEnabled) {
    char message[8192];
    int length;
    va_list args;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    va_start(args, format);
    length = vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    NSString *text = nil;
    if (length >= 0) {
      size_t used = strlen(message);
      /* A bounded C format may cut a UTF-8 sequence. Trim only that suffix. */
      text = [[[NSString alloc] initWithBytes:message length:used
          encoding:NSUTF8StringEncoding] autorelease];
      if (length >= (int)sizeof(message)) {
        unsigned int trim;
        for (trim = 1; text == nil && trim <= 3 && used >= trim; trim++)
          text = [[[NSString alloc] initWithBytes:message length:used - trim
              encoding:NSUTF8StringEncoding] autorelease];
        if (text) text = [text stringByAppendingString:@" [truncated]"];
      }
    }
    RCLogEmit(level, service, phase, text);
    [pool release];
  }
  errno = savedError;
}
