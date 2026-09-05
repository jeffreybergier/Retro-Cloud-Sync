//
//  RCConfiguration.m
//  RetroCloudSync
//

#import "RCConfiguration.h"

#include <sys/stat.h>

static NSString * const kRCConfigurationVersion = @"ConfigurationVersion";
static NSString * const kRCMailProxy = @"MailProxy";
static NSString * const kRCIMAP = @"IMAP";
static NSString * const kRCSMTP = @"SMTP";
static NSString * const kRCLocalPort = @"LocalPort";
static NSString * const kRCRemoteHost = @"RemoteHost";
static NSString * const kRCRemotePort = @"RemotePort";
static NSString * const kRCContacts = @"Contacts";
static NSString * const kRCEnabled = @"Enabled";
static NSString * const kRCCalendarsEnabled = @"CalendarsEnabled";
static NSString * const kRCContactsSyncMode = @"ContactsSyncMode";
static NSString * const kRCCalendarsSyncMode = @"CalendarsSyncMode";
static NSString * const kRCUsername = @"Username";
static NSString * const kRCServiceURL = @"ServiceURL";
static NSString * const kRCSyncIntervalSeconds = @"SyncIntervalSeconds";

@implementation RCConfiguration

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
      mailProxy, kRCMailProxy,
      [NSDictionary dictionaryWithObjectsAndKeys:
          [NSNumber numberWithBool:NO], kRCEnabled,
          [NSNumber numberWithBool:NO], kRCCalendarsEnabled,
          @"Disabled", kRCContactsSyncMode,
          @"Disabled", kRCCalendarsSyncMode,
          @"", kRCUsername,
          @"https://contacts.icloud.com", kRCServiceURL,
          [NSNumber numberWithInt:3600], kRCSyncIntervalSeconds, nil],
      kRCContacts, nil];
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
      *errorMessage = @"The Retro Cloud Sync configuration could not be read";
    }
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
      *errorMessage = @"Could not write the Retro Cloud Sync configuration";
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

+ (NSDictionary *)contactsConfigurationFromConfiguration:
    (NSDictionary *)configuration;
{
  NSDictionary *contacts = [configuration objectForKey:kRCContacts];

  if ([contacts isKindOfClass:[NSDictionary class]]) return contacts;
  return [[self defaultConfiguration] objectForKey:kRCContacts];
}

+ (BOOL)saveMailProxy:(NSDictionary *)mailProxy
                 error:(NSString **)errorMessage;
{
  NSDictionary *loaded = [self loadConfigurationWithError:errorMessage];
  NSMutableDictionary *configuration;

  if (loaded == nil) return NO;
  configuration = [NSMutableDictionary dictionaryWithDictionary:loaded];
  [configuration setObject:mailProxy forKey:kRCMailProxy];
  return [self saveConfiguration:configuration error:errorMessage];
}

+ (BOOL)saveContactsSyncMode:(NSString *)contactsSyncMode
           calendarsSyncMode:(NSString *)calendarsSyncMode
                     username:(NSString *)username
                 syncInterval:(long long)syncInterval
                        error:(NSString **)errorMessage;
{
  NSDictionary *loaded = [self loadConfigurationWithError:errorMessage];
  NSMutableDictionary *configuration;
  NSDictionary *contacts;

  if (loaded == nil) return NO;
  configuration = [NSMutableDictionary dictionaryWithDictionary:loaded];
  contacts = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithBool:
          [contactsSyncMode isEqualToString:@"OneWay"]], kRCEnabled,
      [NSNumber numberWithBool:
          [calendarsSyncMode isEqualToString:@"OneWay"]],
      kRCCalendarsEnabled,
      contactsSyncMode, kRCContactsSyncMode,
      calendarsSyncMode, kRCCalendarsSyncMode,
      username, kRCUsername,
      @"https://contacts.icloud.com", kRCServiceURL,
      [NSNumber numberWithLongLong:syncInterval],
      kRCSyncIntervalSeconds, nil];
  [configuration setObject:contacts forKey:kRCContacts];
  return [self saveConfiguration:configuration error:errorMessage];
}

@end
