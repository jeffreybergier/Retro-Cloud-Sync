//
//  RCMailServerSettings.m
//  RetroCloudSync
//

#import "RCMailServerSettings.h"

#include <sys/stat.h>

static NSString * const kRCConfigurationVersion = @"ConfigurationVersion";
static NSString * const kRCMailProxy = @"MailProxy";
static NSString * const kRCIMAP = @"IMAP";
static NSString * const kRCSMTP = @"SMTP";
static NSString * const kRCLocalPort = @"LocalPort";
static NSString * const kRCRemoteHost = @"RemoteHost";
static NSString * const kRCRemotePort = @"RemotePort";

@interface RCMailServerSettings (Private)
+ (BOOL)validateService:(NSDictionary *)service
                   name:(NSString *)name
                  error:(NSString **)errorMessage;
@end

@implementation RCMailServerSettings

+ (NSString *)configurationPath;
{
  NSString *supportDirectory = [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support"]
      stringByAppendingPathComponent:@"RetroCloudSync"];

  return [supportDirectory stringByAppendingPathComponent:@"Configuration.plist"];
}

+ (NSDictionary *)defaultConfiguration;
{
  NSDictionary *imap = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:1143], kRCLocalPort,
      @"imap.mail.me.com", kRCRemoteHost,
      [NSNumber numberWithInt:993], kRCRemotePort,
      nil];
  NSDictionary *smtp = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:1587], kRCLocalPort,
      @"smtp.mail.me.com", kRCRemoteHost,
      [NSNumber numberWithInt:587], kRCRemotePort,
      nil];
  NSDictionary *mailProxy = [NSDictionary dictionaryWithObjectsAndKeys:
      imap, kRCIMAP, smtp, kRCSMTP, nil];

  return [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:1], kRCConfigurationVersion,
      mailProxy, kRCMailProxy, nil];
}

+ (NSDictionary *)loadConfigurationWithError:(NSString **)errorMessage;
{
  NSString *path = [self configurationPath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSDictionary *configuration;

  if (![fileManager fileExistsAtPath:path]) {
    return [self defaultConfiguration];
  }
  configuration = [NSDictionary dictionaryWithContentsOfFile:path];
  if (configuration == nil) {
    if (errorMessage != NULL) {
      *errorMessage = @"The mail server configuration could not be read";
    }
    return nil;
  }
  if (![self validateConfiguration:configuration error:errorMessage]) {
    return nil;
  }
  return configuration;
}

+ (BOOL)saveConfiguration:(NSDictionary *)configuration
                     error:(NSString **)errorMessage;
{
  NSString *path = [self configurationPath];
  NSString *directory = [path stringByDeletingLastPathComponent];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  BOOL isDirectory = NO;

  if (![self validateConfiguration:configuration error:errorMessage]) {
    return NO;
  }
  if (![fileManager fileExistsAtPath:directory isDirectory:&isDirectory]) {
    NSString *applicationSupport = [directory stringByDeletingLastPathComponent];

    if (![fileManager fileExistsAtPath:applicationSupport isDirectory:&isDirectory] ||
        !isDirectory ||
        ![fileManager createDirectoryAtPath:directory attributes:nil]) {
      if (errorMessage != NULL) {
        *errorMessage = @"Could not create the RetroCloudSync support directory";
      }
      return NO;
    }
  } else if (!isDirectory) {
    if (errorMessage != NULL) {
      *errorMessage = @"The RetroCloudSync support path is not a directory";
    }
    return NO;
  }
  if (![configuration writeToFile:path atomically:YES]) {
    if (errorMessage != NULL) {
      *errorMessage = @"Could not write the mail server configuration";
    }
    return NO;
  }
  chmod([path fileSystemRepresentation], S_IRUSR | S_IWUSR);
  return YES;
}

+ (BOOL)ensureConfigurationExistsWithError:(NSString **)errorMessage;
{
  NSString *path = [self configurationPath];
  NSDictionary *configuration = [self loadConfigurationWithError:errorMessage];

  if (configuration == nil) {
    return NO;
  }
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return YES;
  }
  return [self saveConfiguration:configuration error:errorMessage];
}

+ (BOOL)validateConfiguration:(NSDictionary *)configuration
                         error:(NSString **)errorMessage;
{
  NSNumber *version;
  NSDictionary *mailProxy;
  NSDictionary *imap;
  NSDictionary *smtp;

  if (![configuration isKindOfClass:[NSDictionary class]]) {
    if (errorMessage != NULL) {
      *errorMessage = @"The configuration is not a property-list dictionary";
    }
    return NO;
  }
  version = [configuration objectForKey:kRCConfigurationVersion];
  mailProxy = [configuration objectForKey:kRCMailProxy];
  if (![version isKindOfClass:[NSNumber class]] || [version intValue] != 1 ||
      ![mailProxy isKindOfClass:[NSDictionary class]]) {
    if (errorMessage != NULL) {
      *errorMessage = @"The mail server configuration version is unsupported";
    }
    return NO;
  }
  imap = [mailProxy objectForKey:kRCIMAP];
  smtp = [mailProxy objectForKey:kRCSMTP];
  if (![self validateService:imap name:@"IMAP" error:errorMessage] ||
      ![self validateService:smtp name:@"SMTP" error:errorMessage]) {
    return NO;
  }
  if ([[imap objectForKey:kRCLocalPort] intValue] ==
      [[smtp objectForKey:kRCLocalPort] intValue]) {
    if (errorMessage != NULL) {
      *errorMessage = @"IMAP and SMTP must use different local ports";
    }
    return NO;
  }
  return YES;
}

+ (BOOL)validateService:(NSDictionary *)service
                   name:(NSString *)name
                  error:(NSString **)errorMessage;
{
  NSNumber *localPort;
  NSNumber *remotePort;
  NSString *remoteHost;
  NSCharacterSet *invalidHostCharacters =
      [NSCharacterSet characterSetWithCharactersInString:@" /:\\"];

  if (![service isKindOfClass:[NSDictionary class]]) {
    if (errorMessage != NULL) {
      *errorMessage = [NSString stringWithFormat:@"The %@ settings are missing", name];
    }
    return NO;
  }
  localPort = [service objectForKey:kRCLocalPort];
  remotePort = [service objectForKey:kRCRemotePort];
  remoteHost = [service objectForKey:kRCRemoteHost];
  if (![localPort isKindOfClass:[NSNumber class]] ||
      [localPort intValue] < 1024 || [localPort intValue] > 65535) {
    if (errorMessage != NULL) {
      *errorMessage = [NSString stringWithFormat:
          @"The %@ local port must be between 1024 and 65535", name];
    }
    return NO;
  }
  if (![remotePort isKindOfClass:[NSNumber class]] ||
      [remotePort intValue] < 1 || [remotePort intValue] > 65535) {
    if (errorMessage != NULL) {
      *errorMessage = [NSString stringWithFormat:
          @"The %@ server port must be between 1 and 65535", name];
    }
    return NO;
  }
  if (![remoteHost isKindOfClass:[NSString class]] ||
      [remoteHost length] == 0 ||
      [remoteHost rangeOfCharacterFromSet:invalidHostCharacters].location !=
          NSNotFound ||
      [remoteHost rangeOfCharacterFromSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]].location !=
          NSNotFound) {
    if (errorMessage != NULL) {
      *errorMessage = [NSString stringWithFormat:
          @"The %@ server must be a hostname without a scheme or path", name];
    }
    return NO;
  }
  return YES;
}

@end
