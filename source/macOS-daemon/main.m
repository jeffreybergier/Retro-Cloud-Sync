//
//  main.m
//  RetroCloudSyncDaemon
//

#import <Foundation/Foundation.h>

#include <signal.h>

static volatile sig_atomic_t gShouldKeepRunning = 1;

static void HandleTerminationSignal(int signalNumber)
{
  (void)signalNumber;
  gShouldKeepRunning = 0;
}

int main(int argc, char *argv[])
{
  NSAutoreleasePool *processPool;
  NSPort *keepAlivePort;

  (void)argc;
  (void)argv;

  signal(SIGINT, HandleTerminationSignal);
  signal(SIGTERM, HandleTerminationSignal);

  processPool = [[NSAutoreleasePool alloc] init];
  keepAlivePort = [[NSPort port] retain];
  [[NSRunLoop currentRunLoop] addPort:keepAlivePort
                              forMode:NSDefaultRunLoopMode];
  NSLog(@"Hello from Retro Cloud Sync daemon");

  while (gShouldKeepRunning) {
    NSAutoreleasePool *iterationPool;
    NSDate *wakeDate;

    iterationPool = [[NSAutoreleasePool alloc] init];
    wakeDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
    [[NSRunLoop currentRunLoop] runUntilDate:wakeDate];
    [iterationPool release];
  }

  [[NSRunLoop currentRunLoop] removePort:keepAlivePort
                                 forMode:NSDefaultRunLoopMode];
  [keepAlivePort release];

  NSLog(@"Retro Cloud Sync daemon stopped");
  [processPool release];

  return 0;
}
