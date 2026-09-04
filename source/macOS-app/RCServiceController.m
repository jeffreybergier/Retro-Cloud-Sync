//
//  RCServiceController.m
//  RetroCloudSync
//

#import "RCServiceController.h"

#import "RCConfiguration.h"

#include <unistd.h>

static NSString * const kRCServiceLabel = @"com.retrocloudsync.daemon";
static NSString * const kRCDaemonName = @"RetroCloudSyncDaemon";
static NSString * const kRCCertificateName = @"cacert.pem";
static NSString * const kRCSyncClientDescriptionName = @"SyncClient.plist";

@interface RCServiceController (Private)
- (NSString *)applicationSupportDirectory;
- (NSString *)launchAgentPath;
- (int)runTaskAtPath:(NSString *)launchPath
           arguments:(NSArray *)arguments
              output:(NSString **)output;
- (int)runLaunchctlWithArguments:(NSArray *)arguments
                          output:(NSString **)output;
- (BOOL)waitForServiceToStopWithTimeout:(NSTimeInterval)timeout;
- (BOOL)ensureDirectoryExists:(NSString *)path error:(NSString **)errorMessage;
- (BOOL)installServiceFilesWithError:(NSString **)errorMessage;
@end

@implementation RCServiceController

- (BOOL)isServiceRunning;
{
  NSString *output = nil;
  NSArray *lines;
  NSEnumerator *lineEnumerator;
  NSString *line;
  NSString *installedDaemonPath = [self installedDaemonPath];

  if ([self runTaskAtPath:@"/bin/ps"
                arguments:[NSArray arrayWithObjects:@"-axww", @"-o",
                                                    @"command", nil]
                   output:&output] != 0) {
    return NO;
  }

  lines = [output componentsSeparatedByString:@"\n"];
  lineEnumerator = [lines objectEnumerator];
  while ((line = [lineEnumerator nextObject]) != nil) {
    NSString *command = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

    if ([command isEqualToString:installedDaemonPath] ||
        [command hasPrefix:[installedDaemonPath stringByAppendingString:@" "]]) {
      return YES;
    }
  }
  return NO;
}

- (BOOL)startServiceWithError:(NSString **)errorMessage;
{
  if ([self isServiceRunning]) {
    return YES;
  }
  if (![self installServiceFilesWithError:errorMessage]) {
    return NO;
  }

  /* Clear any loaded but inactive copy before loading the current plist. */
  [self runLaunchctlWithArguments:
      [NSArray arrayWithObjects:@"unload", [self launchAgentPath], nil]
                           output:nil];
  {
    NSString *output = nil;
    int status = [self runLaunchctlWithArguments:
        [NSArray arrayWithObjects:@"load", [self launchAgentPath], nil]
                              output:&output];
    if (status != 0) {
      if (errorMessage != NULL) {
        *errorMessage = [NSString stringWithFormat:@"Could not start daemon: %@",
            [output length] != 0 ? output : @"launchctl returned an error"];
      }
      return NO;
    }
  }
  return YES;
}

- (BOOL)prepareServiceFilesWithError:(NSString **)errorMessage;
{
  return [self installServiceFilesWithError:errorMessage];
}

- (BOOL)stopServiceWithError:(NSString **)errorMessage;
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *launchAgentPath = [self launchAgentPath];
  NSString *output = nil;
  int status = 0;

  if ([fileManager fileExistsAtPath:launchAgentPath]) {
    status = [self runLaunchctlWithArguments:
        [NSArray arrayWithObjects:@"unload", launchAgentPath, nil]
                              output:&output];
  }
  if (status != 0 && [self isServiceRunning]) {
    if (errorMessage != NULL) {
      *errorMessage = [NSString stringWithFormat:@"Could not stop daemon: %@",
                                                   output];
    }
    return NO;
  }
  if (![self waitForServiceToStopWithTimeout:15.0]) {
    if (errorMessage != NULL) {
      *errorMessage = @"The daemon did not stop within 15 seconds";
    }
    return NO;
  }
  if ([fileManager fileExistsAtPath:launchAgentPath] &&
      ![fileManager removeFileAtPath:launchAgentPath handler:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Daemon stopped, but its LaunchAgent could not be removed";
    }
    return NO;
  }
  return YES;
}

- (NSString *)applicationSupportDirectory;
{
  NSString *libraryDirectory =
      [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
  NSString *supportDirectory =
      [libraryDirectory stringByAppendingPathComponent:@"Application Support"];

  return [supportDirectory stringByAppendingPathComponent:@"RetroCloudSync"];
}

- (NSString *)installedDaemonPath;
{
  return [[self applicationSupportDirectory]
      stringByAppendingPathComponent:kRCDaemonName];
}

- (NSString *)daemonLogPath;
{
  NSString *logsDirectory = [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library"]
      stringByAppendingPathComponent:@"Logs"];

  return [[logsDirectory stringByAppendingPathComponent:@"RetroCloudSync"]
      stringByAppendingPathComponent:@"RetroCloudSyncDaemon.log"];
}

- (NSString *)launchAgentPath;
{
  NSString *libraryDirectory =
      [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
  NSString *launchAgentsDirectory =
      [libraryDirectory stringByAppendingPathComponent:@"LaunchAgents"];

  return [launchAgentsDirectory stringByAppendingPathComponent:
      [kRCServiceLabel stringByAppendingPathExtension:@"plist"]];
}

- (int)runTaskAtPath:(NSString *)launchPath
           arguments:(NSArray *)arguments
              output:(NSString **)output;
{
  NSTask *task = [[[NSTask alloc] init] autorelease];
  NSPipe *pipe = [NSPipe pipe];
  NSData *data;
  NSString *taskOutput;

  [task setLaunchPath:launchPath];
  [task setArguments:arguments];
  [task setStandardOutput:pipe];
  [task setStandardError:pipe];

  @try {
    [task launch];
    [task waitUntilExit];
  }
  @catch (NSException *exception) {
    if (output != NULL) {
      *output = [exception reason];
    }
    return -1;
  }

  data = [[pipe fileHandleForReading] readDataToEndOfFile];
  taskOutput = [[[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding]
      autorelease];
  if (output != NULL) {
    *output = taskOutput;
  }
  return [task terminationStatus];
}

- (int)runLaunchctlWithArguments:(NSArray *)arguments
                          output:(NSString **)output;
{
  NSTask *task = [[[NSTask alloc] init] autorelease];
  NSFileHandle *nullDevice = [NSFileHandle fileHandleWithNullDevice];

  [task setLaunchPath:@"/bin/launchctl"];
  [task setArguments:arguments];
  [task setStandardOutput:nullDevice];
  [task setStandardError:nullDevice];

  @try {
    [task launch];
    [task waitUntilExit];
  }
  @catch (NSException *exception) {
    if (output != NULL) {
      *output = [exception reason];
    }
    return -1;
  }

  if (output != NULL) *output = @"launchctl returned an error";
  return [task terminationStatus];
}

- (BOOL)waitForServiceToStopWithTimeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([self isServiceRunning] && [deadline timeIntervalSinceNow] > 0.0) {
    usleep(100000);
  }
  return ![self isServiceRunning];
}

- (BOOL)ensureDirectoryExists:(NSString *)path
                        error:(NSString **)errorMessage;
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  BOOL isDirectory = NO;
  NSString *parentDirectory;

  if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
    if (isDirectory) {
      return YES;
    }
    if (errorMessage != NULL) {
      *errorMessage = [NSString stringWithFormat:@"Not a directory: %@", path];
    }
    return NO;
  }

  parentDirectory = [path stringByDeletingLastPathComponent];
  if (![parentDirectory isEqualToString:path] &&
      ![self ensureDirectoryExists:parentDirectory error:errorMessage]) {
    return NO;
  }
  if (![fileManager createDirectoryAtPath:path attributes:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = [NSString stringWithFormat:@"Could not create: %@", path];
    }
    return NO;
  }
  return YES;
}

- (BOOL)installServiceFilesWithError:(NSString **)errorMessage;
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *embeddedDaemonPath = [[[NSBundle mainBundle] bundlePath]
      stringByAppendingPathComponent:
          @"Contents/Library/LaunchServices/RetroCloudSyncDaemon"];
  NSString *installedDaemonPath = [self installedDaemonPath];
  NSString *embeddedCertificatePath = [[NSBundle mainBundle]
      pathForResource:@"cacert" ofType:@"pem"];
  NSString *installedCertificatePath = [[self applicationSupportDirectory]
      stringByAppendingPathComponent:kRCCertificateName];
  NSString *embeddedSyncClientPath = [[NSBundle mainBundle]
      pathForResource:@"SyncClient" ofType:@"plist"];
  NSString *installedSyncClientPath = [[self applicationSupportDirectory]
      stringByAppendingPathComponent:kRCSyncClientDescriptionName];
  NSString *launchAgentPath = [self launchAgentPath];
  NSString *launchAgentsDirectory =
      [launchAgentPath stringByDeletingLastPathComponent];
  NSString *logPath = [self daemonLogPath];
  NSString *logDirectory = [logPath stringByDeletingLastPathComponent];
  NSDictionary *launchAgent;

  if (![fileManager fileExistsAtPath:embeddedDaemonPath] ||
      embeddedCertificatePath == nil || embeddedSyncClientPath == nil) {
    if (errorMessage != NULL) {
      *errorMessage = @"The embedded daemon, CA certificates, or Sync Services description is missing";
    }
    return NO;
  }
  if (![self ensureDirectoryExists:[self applicationSupportDirectory]
                             error:errorMessage] ||
      ![self ensureDirectoryExists:logDirectory error:errorMessage] ||
      ![self ensureDirectoryExists:launchAgentsDirectory
                             error:errorMessage]) {
    return NO;
  }
  if (![RCConfiguration ensureConfigurationExistsWithError:errorMessage]) {
    return NO;
  }

  if ([fileManager fileExistsAtPath:installedDaemonPath] &&
      ![fileManager removeFileAtPath:installedDaemonPath handler:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not replace the installed daemon";
    }
    return NO;
  }
  if (![fileManager copyPath:embeddedDaemonPath
                      toPath:installedDaemonPath
                     handler:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not install the embedded daemon";
    }
    return NO;
  }
  if ([fileManager fileExistsAtPath:installedCertificatePath] &&
      ![fileManager removeFileAtPath:installedCertificatePath handler:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not replace the installed CA certificates";
    }
    return NO;
  }
  if (![fileManager copyPath:embeddedCertificatePath
                      toPath:installedCertificatePath
                     handler:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not install the CA certificates";
    }
    return NO;
  }
  if ([fileManager fileExistsAtPath:installedSyncClientPath] &&
      ![fileManager removeFileAtPath:installedSyncClientPath handler:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not replace the Sync Services client description";
    }
    return NO;
  }
  if (![fileManager copyPath:embeddedSyncClientPath
                      toPath:installedSyncClientPath
                     handler:nil]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not install the Sync Services client description";
    }
    return NO;
  }

  launchAgent = [NSDictionary dictionaryWithObjectsAndKeys:
      kRCServiceLabel, @"Label",
      [NSArray arrayWithObjects:installedDaemonPath, @"--config",
                                [RCConfiguration configurationPath], nil],
      @"ProgramArguments",
      [NSNumber numberWithBool:YES], @"RunAtLoad",
      [NSNumber numberWithBool:YES], @"KeepAlive",
      logPath, @"StandardOutPath",
      logPath, @"StandardErrorPath",
      nil];
  if (![launchAgent writeToFile:launchAgentPath atomically:YES]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not write the LaunchAgent property list";
    }
    return NO;
  }
  return YES;
}

@end
