//
//  main.m
//  RetroCloudSyncTests
//

#import <Foundation/Foundation.h>

#import "AXTestRunner.h"

static void PrintUsage(const char *programName)
{
  fprintf(stderr,
          "usage: %s --app APP_PATH [--screenshots DIR] [--dump-tree]\n",
          programName);
}

int main(int argc, char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSString *applicationPath = nil;
  NSString *screenshotsDirectory = nil;
  BOOL shouldDumpTree = NO;
  AXTestRunner *runner;
  BOOL succeeded;
  int argumentIndex;

  for (argumentIndex = 1; argumentIndex < argc; argumentIndex++) {
    NSString *argument = [NSString stringWithUTF8String:argv[argumentIndex]];

    if ([argument isEqualToString:@"--app"] && argumentIndex + 1 < argc) {
      argumentIndex++;
      applicationPath =
          [NSString stringWithUTF8String:argv[argumentIndex]];
    } else if ([argument isEqualToString:@"--screenshots"] &&
               argumentIndex + 1 < argc) {
      argumentIndex++;
      screenshotsDirectory =
          [NSString stringWithUTF8String:argv[argumentIndex]];
    } else if ([argument isEqualToString:@"--dump-tree"]) {
      shouldDumpTree = YES;
    } else {
      PrintUsage(argv[0]);
      [pool release];
      return 2;
    }
  }

  if (applicationPath == nil) {
    PrintUsage(argv[0]);
    [pool release];
    return 2;
  }
  if (!AXAPIEnabled()) {
    fprintf(stderr,
            "[SETUP] Accessibility API is disabled; enable access for "
            "assistive devices\n");
    [pool release];
    return 2;
  }

  runner = [[[AXTestRunner alloc]
      initWithApplicationPath:applicationPath
         screenshotsDirectory:screenshotsDirectory] autorelease];
  if (shouldDumpTree) {
    succeeded = [runner dumpAccessibilityTree];
  } else {
    succeeded = [runner runTests];
  }

  [pool release];
  return succeeded ? 0 : 1;
}
