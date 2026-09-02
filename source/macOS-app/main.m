//
//  main.m
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

#import "AppDelegate.h"

int main(int argc, char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSApplication *application = [NSApplication sharedApplication];
  AppDelegate *delegate = [[AppDelegate alloc] init];

  (void)argc;
  (void)argv;

  [application setDelegate:delegate];
  [application run];

  [application setDelegate:nil];
  [delegate release];
  [pool release];
  return 0;
}
