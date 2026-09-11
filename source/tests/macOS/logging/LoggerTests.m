#import "RCLogger.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int RCMailLoggingTests(void);
int RCStatusTests(void);

static void *Worker(void *argument)
{
  const char *service = argument;
  unsigned int i;
  /* Deliberately no caller-owned autorelease pool. */
  RCLoggerSetContext(service, !strcmp(service, "Contacts") ? 41 : 42);
  for (i = 0; i < 10; i++) {
    errno = EBUSY;
    RCLoggerC(RCLogInfo, NULL, "Test", "worker=%s item=%u", service, i);
    if (errno != EBUSY) return (void *)1;
  }
  return NULL;
}

int main(void)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  pthread_t contacts, calendars;
  void *first, *second;
  char longMessage[10000];
  if (!RCStatusTests()) return 5;
  if (!RCMailLoggingTests()) return 1;
  errno = EDOM;
  RCLoggerSetContext("Daemon", 0);
  RCLogger(RCLogInfo, NULL, "Test", @"percent=100%% Unicode=caf\u00e9\nnew-line\tend");
  if (errno != EDOM) return 2;
  RCLoggerC(RCLogWarning, "Mail", "Test", "%s", "invalid=\xff");
  memset(longMessage, 'x', sizeof(longMessage) - 1);
  longMessage[sizeof(longMessage) - 1] = 0;
  RCLoggerC(RCLogInfo, NULL, "Test", "%s", longMessage);
  RCLoggerC(RCLogDebug, NULL, "Test", "debug-marker");
  RCLoggerSetConnection("Mail/IMAP", 7);
  RCLoggerC(RCLogWarning, NULL, "TLS", "connection-marker");
  RCLoggerSetContext("Daemon", 0);
  if (pthread_create(&contacts, NULL, Worker, "Contacts") ||
      pthread_create(&calendars, NULL, Worker, "Calendars")) return 3;
  pthread_join(contacts, &first); pthread_join(calendars, &second);
  if (first || second) return 4;
  RCLogger(RCLogInfo, NULL, "Test", @"main-context-marker");
  [pool release];
  puts("Logger tests passed");
  return 0;
}
