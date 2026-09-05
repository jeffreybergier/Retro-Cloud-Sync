//
//  AXTestRunner.m
//  RetroCloudSyncTests
//

#import "AXTestRunner.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString * const kRCTestDaemonName = @"RetroCloudSyncDaemon";

@interface AXTestRunner (Private)
- (BOOL)captureScreenshotNamed:(NSString *)name;
- (void)cleanUp;
- (void)collectElementsWithRole:(CFStringRef)role
                      inElement:(AXUIElementRef)element
                          depth:(unsigned int)depth
                        results:(NSMutableArray *)results;
- (void)dumpElement:(AXUIElementRef)element depth:(unsigned int)depth;
- (AXUIElementRef)findElementNamed:(NSString *)name
                         inElement:(AXUIElementRef)element
                             depth:(unsigned int)depth;
- (AXUIElementRef)findElementWithRole:(CFStringRef)role
                            inElement:(AXUIElementRef)element
                                depth:(unsigned int)depth;
- (BOOL)isDaemonRunning;
- (BOOL)launchApplication;
- (BOOL)pressControlNamed:(NSString *)name segment:(NSInteger)segment;
- (BOOL)runTaskAtPath:(NSString *)path arguments:(NSArray *)arguments;
- (BOOL)replaceTextInField:(AXUIElementRef)field withString:(NSString *)string;
- (BOOL)testMailFieldValidationAtPath:(NSString *)path;
- (BOOL)setMailFieldsWithIMAPLocalPort:(NSString *)imapLocalPort
                            imapServer:(NSString *)imapServer
                        imapServerPort:(NSString *)imapServerPort
                         smtpLocalPort:(NSString *)smtpLocalPort
                            smtpServer:(NSString *)smtpServer
                        smtpServerPort:(NSString *)smtpServerPort;
- (BOOL)waitForConfigurationAtPath:(NSString *)path
                     imapLocalPort:(unsigned short)imapLocalPort
                        imapServer:(NSString *)imapServer
                    imapServerPort:(unsigned short)imapServerPort
                     smtpLocalPort:(unsigned short)smtpLocalPort
                        smtpServer:(NSString *)smtpServer
                    smtpServerPort:(unsigned short)smtpServerPort
                           timeout:(NSTimeInterval)timeout;
- (BOOL)waitForDaemonRunning:(BOOL)shouldRun timeout:(NSTimeInterval)timeout;
- (BOOL)waitForElementNamed:(NSString *)name timeout:(NSTimeInterval)timeout;
- (BOOL)waitForFileAtPath:(NSString *)path timeout:(NSTimeInterval)timeout;
- (BOOL)waitForListenerOnPort:(unsigned short)port
                      timeout:(NSTimeInterval)timeout;
- (BOOL)waitForStatus:(NSString *)status timeout:(NSTimeInterval)timeout;
- (BOOL)waitForWindowWithTimeout:(NSTimeInterval)timeout;
@end

static CFTypeRef CopyAXAttribute(AXUIElementRef element,
                                 CFStringRef attribute)
{
  CFTypeRef value = NULL;

  if (AXUIElementCopyAttributeValue(element, attribute, &value) !=
      kAXErrorSuccess) {
    return NULL;
  }
  return value;
}

static BOOL AXValueMatchesString(CFTypeRef value, NSString *string)
{
  if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
    return NO;
  }
  return [(NSString *)value isEqualToString:string];
}

static void PrintPass(NSString *message)
{
  fprintf(stdout, "[PASS] %s\n", [message UTF8String]);
  fflush(stdout);
}

static void PrintFail(NSString *message)
{
  fprintf(stderr, "[FAIL] %s\n", [message UTF8String]);
  fflush(stderr);
}

static BOOL ConfigurationMatches(NSString *path,
                                 unsigned short imapLocalPort,
                                 NSString *imapServer,
                                 unsigned short imapServerPort,
                                 unsigned short smtpLocalPort,
                                 NSString *smtpServer,
                                 unsigned short smtpServerPort)
{
  NSDictionary *configuration =
      [NSDictionary dictionaryWithContentsOfFile:path];
  NSDictionary *mailProxy = [configuration objectForKey:@"MailProxy"];
  NSDictionary *imap = [mailProxy objectForKey:@"IMAP"];
  NSDictionary *smtp = [mailProxy objectForKey:@"SMTP"];

  return configuration != nil &&
      [[configuration objectForKey:@"ConfigurationVersion"] intValue] == 1 &&
      [[imap objectForKey:@"LocalPort"] intValue] == imapLocalPort &&
      [[imap objectForKey:@"RemoteHost"] isEqualToString:imapServer] &&
      [[imap objectForKey:@"RemotePort"] intValue] == imapServerPort &&
      [[smtp objectForKey:@"LocalPort"] intValue] == smtpLocalPort &&
      [[smtp objectForKey:@"RemoteHost"] isEqualToString:smtpServer] &&
      [[smtp objectForKey:@"RemotePort"] intValue] == smtpServerPort;
}

@implementation AXTestRunner

- (id)initWithApplicationPath:(NSString *)applicationPath
         screenshotsDirectory:(NSString *)screenshotsDirectory;
{
  self = [super init];
  if (self != nil) {
    applicationPath_ = [applicationPath copy];
    screenshotsDirectory_ = [screenshotsDirectory copy];
  }
  return self;
}

- (void)dealloc;
{
  [self cleanUp];
  [applicationPath_ release];
  [screenshotsDirectory_ release];
  [super dealloc];
}

- (BOOL)dumpAccessibilityTree;
{
  BOOL succeeded = NO;

  if (![self launchApplication]) {
    return NO;
  }
  if ([self waitForWindowWithTimeout:10.0]) {
    [self dumpElement:windowElement_ depth:0];
    succeeded = YES;
  }
  [self cleanUp];
  return succeeded;
}

- (BOOL)runTests;
{
  NSString *supportDirectory;
  NSString *daemonPath;
  NSString *certificatePath;
  NSString *syncClientPath;
  NSString *configurationPath;
  NSString *networkTestPath;
  NSString *launchAgentPath;
  NSString *daemonLogPath;
  NSDictionary *configuration;
  NSDictionary *mailProxy;
  NSDictionary *launchAgent;
  unsigned short imapPort;
  unsigned short smtpPort;
  NSFileManager *fileManager = [NSFileManager defaultManager];
  BOOL mailSettingsChanged = NO;
  BOOL succeeded = NO;

  if (![self launchApplication] ||
      ![self waitForWindowWithTimeout:10.0]) {
    [self captureScreenshotNamed:@"window-failure.png"];
    [self cleanUp];
    return NO;
  }
  PrintPass(@"Preferences window appeared");

  supportDirectory = [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support"]
      stringByAppendingPathComponent:@"RetroCloudSync"];
  daemonPath = [supportDirectory stringByAppendingPathComponent:
      kRCTestDaemonName];
  certificatePath = [supportDirectory
      stringByAppendingPathComponent:@"cacert.pem"];
  syncClientPath = [supportDirectory
      stringByAppendingPathComponent:@"SyncClient.plist"];
  configurationPath = [supportDirectory
      stringByAppendingPathComponent:@"Configuration.plist"];
  networkTestPath = [supportDirectory
      stringByAppendingPathComponent:@"RetroCloudSyncNetworkTest.jpg"];
  launchAgentPath = [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/LaunchAgents"]
      stringByAppendingPathComponent:@"com.retrocloudsync.daemon.plist"];
  daemonLogPath = [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Logs/RetroCloudSync"]
      stringByAppendingPathComponent:@"RetroCloudSyncDaemon.log"];

  if (![self waitForStatus:@"Stopped" timeout:1.0] &&
      ![self pressControlNamed:@"Stop" segment:1]) {
    PrintFail(@"Could not press Stop for the running daemon");
    goto cleanup;
  }
  if (![self waitForStatus:@"Stopped" timeout:10.0] ||
      ![self waitForDaemonRunning:NO timeout:10.0]) {
    PrintFail(@"Could not establish a stopped baseline");
    goto cleanup;
  }
  PrintPass(@"Stopped baseline established");
  if ([fileManager fileExistsAtPath:networkTestPath] &&
      ![fileManager removeFileAtPath:networkTestPath handler:nil]) {
    PrintFail(@"Could not remove the previous network test download");
    goto cleanup;
  }

  if (![self pressControlNamed:@"Mail" segment:0] ||
      ![self waitForElementNamed:@"Incoming Mail (IMAP)" timeout:5.0]) {
    PrintFail(@"Could not open the Mail preferences panel");
    goto cleanup;
  }
  PrintPass(@"Mail preferences panel opened");
  mailSettingsChanged = YES;
  if (![self setMailFieldsWithIMAPLocalPort:@"2143"
                                  imapServer:@"imap.example.com"
                              imapServerPort:@"1993"
                               smtpLocalPort:@"2587"
                                  smtpServer:@"smtp.example.com"
                              smtpServerPort:@"2525"]) {
    PrintFail(@"Mail preferences fields could not be found or changed");
    goto cleanup;
  }
  PrintPass(@"All mail preferences fields were found and changed");
  if (![self waitForConfigurationAtPath:configurationPath
                          imapLocalPort:2143
                             imapServer:@"imap.example.com"
                         imapServerPort:1993
                          smtpLocalPort:2587
                             smtpServer:@"smtp.example.com"
                         smtpServerPort:2525
                                timeout:5.0]) {
    PrintFail(@"Changed mail preferences were not saved");
    goto cleanup;
  }
  PrintPass(@"Changed mail preferences were saved before leaving the field");

  if (![self setMailFieldsWithIMAPLocalPort:@"1143"
                                  imapServer:@"imap.mail.me.com"
                              imapServerPort:@"993"
                               smtpLocalPort:@"1587"
                                  smtpServer:@"smtp.mail.me.com"
                              smtpServerPort:@"587"] ||
      ![self waitForConfigurationAtPath:configurationPath
                          imapLocalPort:1143
                             imapServer:@"imap.mail.me.com"
                         imapServerPort:993
                          smtpLocalPort:1587
                             smtpServer:@"smtp.mail.me.com"
                         smtpServerPort:587
                                timeout:5.0]) {
    PrintFail(@"Default mail preferences were not restored");
    goto cleanup;
  }
  PrintPass(@"Default mail preferences were restored and saved");
  if (![self testMailFieldValidationAtPath:configurationPath]) {
    PrintFail(@"Mail field autosave or validation on editing end failed");
    goto cleanup;
  }
  PrintPass(@"Invalid mail values save immediately and alert only on editing end");
  mailSettingsChanged = NO;
  if (![self pressControlNamed:@"Sync" segment:0] ||
      ![self waitForElementNamed:@"iCloud Account" timeout:5.0] ||
      ![self waitForElementNamed:@"Contacts" timeout:5.0] ||
      ![self waitForElementNamed:@"Calendar" timeout:5.0] ||
      ![self waitForElementNamed:@"Interval" timeout:5.0] ||
      ![self waitForElementNamed:@"Apple ID:" timeout:5.0] ||
      ![self waitForElementNamed:@"Password:" timeout:5.0] ||
      ![self waitForElementNamed:@"Disabled" timeout:5.0] ||
      ![self waitForElementNamed:
          @"1-way Sync: iCloud → Address Book" timeout:5.0] ||
      ![self waitForElementNamed:
          @"2-way Sync: iCloud ↔ Address Book"
          timeout:5.0] ||
      ![self waitForElementNamed:@"1-way Sync: iCloud → iCal"
          timeout:5.0] ||
      ![self waitForElementNamed:
          @"2-way Sync: iCloud ↔ iCal" timeout:5.0]) {
    PrintFail(@"Could not open or inspect the Sync preferences panel");
    goto cleanup;
  }
  PrintPass(@"Sync preferences panel opened with account controls");
  {
    AXUIElementRef accountTitle = [self findElementNamed:@"iCloud Account"
        inElement:windowElement_ depth:0];
    AXUIElementRef accountBox = NULL;
    AXUIElementRef accountButton = NULL;

    if (accountTitle != NULL) {
      accountBox = (AXUIElementRef)CopyAXAttribute(accountTitle,
          kAXParentAttribute);
      CFRelease(accountTitle);
    }
    if (accountBox != NULL) {
      accountButton = [self findElementNamed:@"Save"
          inElement:accountBox depth:0];
      if (accountButton == NULL) {
        accountButton = [self findElementNamed:@"Reset"
            inElement:accountBox depth:0];
      }
      CFRelease(accountBox);
    }
    if (accountButton == NULL) {
      PrintFail(@"Save/Reset is missing from the iCloud Account box");
      goto cleanup;
    }
    CFRelease(accountButton);
  }
  PrintPass(@"Credential Save/Reset button is inside the iCloud Account box");
  {
    AXUIElementRef slider = [self findElementWithRole:kAXSliderRole
        inElement:windowElement_ depth:0];
    NSDictionary *original =
        [NSDictionary dictionaryWithContentsOfFile:configurationPath];
    BOOL passed = slider != NULL && original != nil;
    unsigned int index;
    int startingValues[] = {2, 299};
    int expectedMinutes[] = {1, 300};
    CFStringRef actions[] = {kAXDecrementAction, kAXIncrementAction};

    for (index = 0; passed && index < 2; index++) {
      NSDate *deadline;
      BOOL saved = NO;

      if (AXUIElementSetAttributeValue(slider, kAXValueAttribute,
              (CFTypeRef)[NSNumber numberWithInt:startingValues[index]]) !=
              kAXErrorSuccess ||
          AXUIElementPerformAction(slider, actions[index]) != kAXErrorSuccess) {
        passed = NO;
        break;
      }
      deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
      while ([deadline timeIntervalSinceNow] > 0.0) {
        NSDictionary *current = [NSDictionary
            dictionaryWithContentsOfFile:configurationPath];

        if ([[[current objectForKey:@"Contacts"]
                objectForKey:@"SyncIntervalSeconds"] intValue] ==
                expectedMinutes[index] * 60) {
          saved = YES;
          break;
        }
        usleep(100000);
      }
      passed = saved && [self waitForElementNamed:
          index == 0 ? @"1 minute" : @"300 minutes" timeout:5.0];
    }
    if (slider != NULL) CFRelease(slider);
    if (original == nil ||
        ![original writeToFile:configurationPath atomically:YES]) {
      PrintFail(@"Could not restore configuration after the interval slider test");
      goto cleanup;
    }
    if (!passed || ![self pressControlNamed:@"Sync" segment:0]) {
      PrintFail(@"Interval slider endpoints, readout, or autosave failed");
      goto cleanup;
    }
  }
  PrintPass(@"Interval slider saves 1 and 300 minutes with matching readouts");
  [self captureScreenshotNamed:@"sync-panel.png"];
  {
    NSDictionary *original =
        [NSDictionary dictionaryWithContentsOfFile:configurationPath];
    NSDictionary *contacts = [original objectForKey:@"Contacts"];

    if ([[contacts objectForKey:@"Username"] isEqualToString:@""] &&
        [[contacts objectForKey:@"ContactsSyncMode"]
            isEqualToString:@"Disabled"]) {
      BOOL saved = NO;
      BOOL restored = NO;
      NSDate *deadline;

      if ([self pressControlNamed:@"1-way Sync: iCloud → Address Book"
                         segment:0]) {
        deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while ([deadline timeIntervalSinceNow] > 0.0) {
          NSDictionary *current = [NSDictionary
              dictionaryWithContentsOfFile:configurationPath];
          NSDictionary *currentContacts = [current objectForKey:@"Contacts"];

          if ([[currentContacts objectForKey:@"ContactsSyncMode"]
                  isEqualToString:@"OneWay"] &&
              [[currentContacts objectForKey:@"Username"]
                  isEqualToString:@""]) {
            saved = YES;
            break;
          }
          usleep(100000);
        }
      }
      if (saved && [self pressControlNamed:@"Disabled" segment:0]) {
        deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while ([deadline timeIntervalSinceNow] > 0.0) {
          NSDictionary *current = [NSDictionary
              dictionaryWithContentsOfFile:configurationPath];

          if ([current isEqualToDictionary:original]) {
            restored = YES;
            break;
          }
          usleep(100000);
        }
      }
      if (!restored && ![original writeToFile:configurationPath atomically:YES]) {
        PrintFail(@"Could not restore configuration after the sync radio test");
        goto cleanup;
      }
      if (!saved || !restored) {
        PrintFail(@"Sync radio changes were not saved with a blank Apple ID");
        goto cleanup;
      }
      PrintPass(@"Sync radio changes save with a blank Apple ID and restore correctly");
    }
  }
  if (![self pressControlNamed:@"Daemon" segment:0] ||
      ![self waitForStatus:@"Stopped" timeout:5.0]) {
    PrintFail(@"Could not return to the Daemon preferences panel");
    goto cleanup;
  }
  PrintPass(@"Daemon preferences panel reopened");

  if (![self pressControlNamed:@"Start" segment:0]) {
    PrintFail(@"Start control could not be pressed");
    goto cleanup;
  }
  PrintPass(@"Start control pressed");
  /* Tiger's launchctl may defer a newly loaded job while performing its
     internal Bonjour workaround. Allow the blocking Start action to finish. */
  if (![self waitForStatus:@"Running" timeout:90.0] ||
      ![self waitForDaemonRunning:YES timeout:15.0]) {
    PrintFail(@"Daemon did not reach the running state");
    goto cleanup;
  }
  PrintPass(@"Status label reports running");
  PrintPass(@"Daemon process is running");

  if (![fileManager fileExistsAtPath:daemonPath] ||
      ![fileManager fileExistsAtPath:certificatePath] ||
      ![fileManager fileExistsAtPath:syncClientPath] ||
      ![fileManager fileExistsAtPath:configurationPath] ||
      ![fileManager fileExistsAtPath:launchAgentPath]) {
    PrintFail(@"Installed daemon, CA certificates, Sync Services description, configuration, or LaunchAgent are missing");
    goto cleanup;
  }
  PrintPass(@"Daemon, CA certificates, Sync Services description, configuration, and LaunchAgent are installed");
  launchAgent = [NSDictionary dictionaryWithContentsOfFile:launchAgentPath];
  if (![[launchAgent objectForKey:@"StandardOutPath"]
          isEqualToString:daemonLogPath] ||
      ![[launchAgent objectForKey:@"StandardErrorPath"]
          isEqualToString:daemonLogPath] ||
      ![self waitForFileAtPath:daemonLogPath timeout:5.0]) {
    PrintFail(@"LaunchAgent is not writing to the per-user daemon log");
    goto cleanup;
  }
  PrintPass(@"LaunchAgent writes to the per-user daemon log");
  if (![self pressControlNamed:@"Log" segment:0] ||
      ![self waitForElementNamed:@"Reveal" timeout:5.0] ||
      ![self waitForElementNamed:@"Refresh" timeout:5.0]) {
    PrintFail(@"Could not open or inspect the daemon Log preferences panel");
    goto cleanup;
  }
  {
    NSMutableArray *logTextAreas = [NSMutableArray array];

    [self collectElementsWithRole:kAXTextAreaRole inElement:windowElement_
                           depth:0 results:logTextAreas];
    if ([logTextAreas count] != 1) {
      PrintFail(@"The daemon Log preferences panel is missing its log text area");
      goto cleanup;
    }
  }
  PrintPass(@"Daemon Log preferences panel opened");
  if (![self pressControlNamed:@"Daemon" segment:0] ||
      ![self waitForStatus:@"Running" timeout:5.0]) {
    PrintFail(@"Could not return to the running Daemon preferences panel");
    goto cleanup;
  }
  configuration = [NSDictionary dictionaryWithContentsOfFile:configurationPath];
  mailProxy = [configuration objectForKey:@"MailProxy"];
  imapPort = (unsigned short)[[[mailProxy objectForKey:@"IMAP"]
      objectForKey:@"LocalPort"] intValue];
  smtpPort = (unsigned short)[[[mailProxy objectForKey:@"SMTP"]
      objectForKey:@"LocalPort"] intValue];
  if (configuration == nil || imapPort == 0 || smtpPort == 0) {
    PrintFail(@"Mail proxy configuration could not be read");
    goto cleanup;
  }
  if (![self waitForFileAtPath:networkTestPath timeout:120.0]) {
    PrintFail(@"Verified HTTPS image download did not finish");
    goto cleanup;
  }
  PrintPass(@"Verified HTTPS image download finished");
  if (![self waitForListenerOnPort:imapPort timeout:15.0]) {
    PrintFail(@"IMAP listener is not accepting loopback connections");
    goto cleanup;
  }
  PrintPass([NSString stringWithFormat:
      @"IMAP listener accepts connections on 127.0.0.1:%u",
      (unsigned int)imapPort]);
  if (![self waitForListenerOnPort:smtpPort timeout:15.0]) {
    PrintFail(@"SMTP listener is not accepting loopback connections");
    goto cleanup;
  }
  PrintPass([NSString stringWithFormat:
      @"SMTP listener accepts connections on 127.0.0.1:%u",
      (unsigned int)smtpPort]);

  if (![self pressControlNamed:@"Stop" segment:1]) {
    PrintFail(@"Stop control could not be pressed");
    goto cleanup;
  }
  PrintPass(@"Stop control pressed");
  if (![self waitForStatus:@"Stopped" timeout:15.0] ||
      ![self waitForDaemonRunning:NO timeout:15.0]) {
    PrintFail(@"Daemon did not reach the stopped state");
    goto cleanup;
  }
  PrintPass(@"Status label reports stopped");
  PrintPass(@"Daemon process stopped");

  if ([fileManager fileExistsAtPath:launchAgentPath]) {
    PrintFail(@"LaunchAgent plist remains after Stop");
    goto cleanup;
  }
  PrintPass(@"LaunchAgent plist was removed");
  succeeded = YES;

cleanup:
  if (mailSettingsChanged) {
    [self pressControlNamed:@"Mail" segment:0];
    [self setMailFieldsWithIMAPLocalPort:@"1143"
                               imapServer:@"imap.mail.me.com"
                           imapServerPort:@"993"
                            smtpLocalPort:@"1587"
                               smtpServer:@"smtp.mail.me.com"
                           smtpServerPort:@"587"];
  }
  if (!succeeded) {
    [self captureScreenshotNamed:@"failure.png"];
    [self dumpElement:windowElement_ depth:0];
    [self pressControlNamed:@"Daemon" segment:0];
    [self pressControlNamed:@"Stop" segment:1];
  }
  [self cleanUp];
  return succeeded;
}

- (BOOL)captureScreenshotNamed:(NSString *)name;
{
  NSString *path;

  if (screenshotsDirectory_ == nil) {
    return NO;
  }
  path = [screenshotsDirectory_ stringByAppendingPathComponent:name];
  return [self runTaskAtPath:@"/usr/sbin/screencapture"
                   arguments:[NSArray arrayWithObjects:@"-x", path, nil]];
}

- (void)cleanUp;
{
  if (windowElement_ != NULL) {
    CFRelease(windowElement_);
    windowElement_ = NULL;
  }
  if (applicationElement_ != NULL) {
    CFRelease(applicationElement_);
    applicationElement_ = NULL;
  }
  if (applicationTask_ != nil) {
    if ([applicationTask_ isRunning]) {
      [applicationTask_ terminate];
      [applicationTask_ waitUntilExit];
    }
    [applicationTask_ release];
    applicationTask_ = nil;
  }
}

- (void)collectElementsWithRole:(CFStringRef)role
                      inElement:(AXUIElementRef)element
                          depth:(unsigned int)depth
                        results:(NSMutableArray *)results;
{
  CFTypeRef elementRole;
  CFTypeRef children;

  if (depth > 12) {
    return;
  }
  elementRole = CopyAXAttribute(element, kAXRoleAttribute);
  if (elementRole != NULL && CFGetTypeID(elementRole) == CFStringGetTypeID() &&
      CFEqual(elementRole, role)) {
    [results addObject:(id)element];
  }
  if (elementRole != NULL) CFRelease(elementRole);

  children = CopyAXAttribute(element, kAXChildrenAttribute);
  if (children != NULL && CFGetTypeID(children) == CFArrayGetTypeID()) {
    CFIndex childIndex;
    CFIndex childCount = CFArrayGetCount((CFArrayRef)children);

    for (childIndex = 0; childIndex < childCount; childIndex++) {
      [self collectElementsWithRole:role
                          inElement:(AXUIElementRef)CFArrayGetValueAtIndex(
                              (CFArrayRef)children, childIndex)
                              depth:depth + 1
                            results:results];
    }
  }
  if (children != NULL) CFRelease(children);
}

- (void)dumpElement:(AXUIElementRef)element depth:(unsigned int)depth;
{
  CFTypeRef role = CopyAXAttribute(element, kAXRoleAttribute);
  CFTypeRef title = CopyAXAttribute(element, kAXTitleAttribute);
  CFTypeRef value = CopyAXAttribute(element, kAXValueAttribute);
  CFTypeRef description = CopyAXAttribute(element, kAXDescriptionAttribute);
  CFTypeRef children = CopyAXAttribute(element, kAXChildrenAttribute);
  unsigned int index;

  for (index = 0; index < depth; index++) {
    fprintf(stdout, "  ");
  }
  fprintf(stdout, "role=%s title=%s value=%s description=%s\n",
          role != NULL && CFGetTypeID(role) == CFStringGetTypeID()
              ? [(NSString *)role UTF8String] : "-",
          title != NULL && CFGetTypeID(title) == CFStringGetTypeID()
              ? [(NSString *)title UTF8String] : "-",
          value != NULL && CFGetTypeID(value) == CFStringGetTypeID()
              ? [(NSString *)value UTF8String] : "-",
          description != NULL &&
              CFGetTypeID(description) == CFStringGetTypeID()
              ? [(NSString *)description UTF8String] : "-");

  if (children != NULL && CFGetTypeID(children) == CFArrayGetTypeID() &&
      depth < 12) {
    CFIndex childIndex;
    CFIndex childCount = CFArrayGetCount((CFArrayRef)children);

    for (childIndex = 0; childIndex < childCount; childIndex++) {
      [self dumpElement:(AXUIElementRef)CFArrayGetValueAtIndex(
          (CFArrayRef)children, childIndex) depth:depth + 1];
    }
  }

  if (children != NULL) CFRelease(children);
  if (description != NULL) CFRelease(description);
  if (value != NULL) CFRelease(value);
  if (title != NULL) CFRelease(title);
  if (role != NULL) CFRelease(role);
}

- (AXUIElementRef)findElementNamed:(NSString *)name
                         inElement:(AXUIElementRef)element
                             depth:(unsigned int)depth;
{
  CFTypeRef title;
  CFTypeRef value;
  CFTypeRef description;
  CFTypeRef children;
  AXUIElementRef found = NULL;

  if (depth > 12) {
    return NULL;
  }
  title = CopyAXAttribute(element, kAXTitleAttribute);
  value = CopyAXAttribute(element, kAXValueAttribute);
  description = CopyAXAttribute(element, kAXDescriptionAttribute);
  if (AXValueMatchesString(title, name) || AXValueMatchesString(value, name) ||
      AXValueMatchesString(description, name)) {
    found = (AXUIElementRef)CFRetain(element);
  }
  if (description != NULL) CFRelease(description);
  if (value != NULL) CFRelease(value);
  if (title != NULL) CFRelease(title);
  if (found != NULL) {
    return found;
  }

  children = CopyAXAttribute(element, kAXChildrenAttribute);
  if (children != NULL && CFGetTypeID(children) == CFArrayGetTypeID()) {
    CFIndex childIndex;
    CFIndex childCount = CFArrayGetCount((CFArrayRef)children);

    for (childIndex = 0; childIndex < childCount && found == NULL;
         childIndex++) {
      found = [self findElementNamed:name
                           inElement:(AXUIElementRef)CFArrayGetValueAtIndex(
                               (CFArrayRef)children, childIndex)
                               depth:depth + 1];
    }
  }
  if (children != NULL) CFRelease(children);
  return found;
}

- (AXUIElementRef)findElementWithRole:(CFStringRef)role
                            inElement:(AXUIElementRef)element
                                depth:(unsigned int)depth;
{
  CFTypeRef elementRole;
  CFTypeRef children;
  AXUIElementRef found = NULL;

  if (depth > 12) {
    return NULL;
  }
  elementRole = CopyAXAttribute(element, kAXRoleAttribute);
  if (elementRole != NULL && CFGetTypeID(elementRole) == CFStringGetTypeID() &&
      CFEqual(elementRole, role)) {
    found = (AXUIElementRef)CFRetain(element);
  }
  if (elementRole != NULL) CFRelease(elementRole);
  if (found != NULL) {
    return found;
  }

  children = CopyAXAttribute(element, kAXChildrenAttribute);
  if (children != NULL && CFGetTypeID(children) == CFArrayGetTypeID()) {
    CFIndex childIndex;
    CFIndex childCount = CFArrayGetCount((CFArrayRef)children);

    for (childIndex = 0; childIndex < childCount && found == NULL;
         childIndex++) {
      found = [self findElementWithRole:role
                              inElement:(AXUIElementRef)CFArrayGetValueAtIndex(
                                  (CFArrayRef)children, childIndex)
                                  depth:depth + 1];
    }
  }
  if (children != NULL) CFRelease(children);
  return found;
}

- (BOOL)isDaemonRunning;
{
  NSTask *task = [[[NSTask alloc] init] autorelease];
  NSPipe *pipe = [NSPipe pipe];
  NSData *data;
  NSString *output;
  NSString *daemonPath = [[[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support"]
      stringByAppendingPathComponent:@"RetroCloudSync"]
      stringByAppendingPathComponent:kRCTestDaemonName];
  NSArray *lines;
  NSEnumerator *enumerator;
  NSString *line;

  [task setLaunchPath:@"/bin/ps"];
  [task setArguments:
      [NSArray arrayWithObjects:@"-axww", @"-o", @"command", nil]];
  [task setStandardOutput:pipe];
  [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
  [task launch];
  /* Drain ps output before waiting so a full Tiger pipe cannot deadlock the
     harness in the same way as the application's status check. */
  data = [[pipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  output = [[[NSString alloc] initWithData:data
                                  encoding:NSUTF8StringEncoding] autorelease];
  lines = [output componentsSeparatedByString:@"\n"];
  enumerator = [lines objectEnumerator];
  while ((line = [enumerator nextObject]) != nil) {
    NSString *command = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

    if ([command isEqualToString:daemonPath] ||
        [command hasPrefix:[daemonPath stringByAppendingString:@" "]]) {
      return YES;
    }
  }
  return NO;
}

- (BOOL)launchApplication;
{
  NSString *executablePath;
  ProcessSerialNumber processSerialNumber;

  if (!AXAPIEnabled()) {
    PrintFail(@"Accessibility API is disabled; enable access for assistive devices");
    return NO;
  }
  PrintPass(@"Accessibility API is available");

  executablePath = [[applicationPath_
      stringByAppendingPathComponent:@"Contents/MacOS"]
      stringByAppendingPathComponent:@"RetroCloudSync"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:executablePath]) {
    PrintFail(@"Application executable is missing");
    return NO;
  }

  applicationTask_ = [[NSTask alloc] init];
  [applicationTask_ setLaunchPath:executablePath];
  [applicationTask_ setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
  [applicationTask_ setStandardError:[NSFileHandle fileHandleWithNullDevice]];
  [applicationTask_ launch];
  applicationElement_ = AXUIElementCreateApplication(
      [applicationTask_ processIdentifier]);

  if (GetProcessForPID([applicationTask_ processIdentifier],
                       &processSerialNumber) == noErr) {
    SetFrontProcess(&processSerialNumber);
  }
  return YES;
}

- (BOOL)pressControlNamed:(NSString *)name segment:(NSInteger)segment;
{
  AXUIElementRef control = [self findElementNamed:name
                                        inElement:windowElement_
                                            depth:0];
  AXError error;

  if (control != NULL) {
    error = AXUIElementPerformAction(control, kAXPressAction);
    if (error == kAXErrorSuccess) {
      CFRelease(control);
      return YES;
    }
    {
      CFTypeRef positionValue = CopyAXAttribute(control, kAXPositionAttribute);
      CFTypeRef sizeValue = CopyAXAttribute(control, kAXSizeAttribute);
      CGPoint position;
      CGSize size;

      if (positionValue != NULL && sizeValue != NULL &&
          AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType,
                          &position) &&
          AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size)) {
        CGPoint clickPoint = CGPointMake(position.x + size.width / 2.0,
                                         position.y + size.height / 2.0);
        CGPostMouseEvent(clickPoint, true, 1, false);
        usleep(100000);
        CGPostMouseEvent(clickPoint, true, 1, true);
        usleep(100000);
        CGPostMouseEvent(clickPoint, true, 1, false);
        if (sizeValue != NULL) CFRelease(sizeValue);
        if (positionValue != NULL) CFRelease(positionValue);
        CFRelease(control);
        return YES;
      }
      if (sizeValue != NULL) CFRelease(sizeValue);
      if (positionValue != NULL) CFRelease(positionValue);
    }
    CFRelease(control);
  }

  control = [self findElementWithRole:CFSTR("AXRadioGroup")
                            inElement:windowElement_
                                depth:0];
  if (control != NULL) {
    CFTypeRef positionValue = CopyAXAttribute(control, kAXPositionAttribute);
    CFTypeRef sizeValue = CopyAXAttribute(control, kAXSizeAttribute);
    CGPoint position;
    CGSize size;

    if (positionValue != NULL && sizeValue != NULL &&
        AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType,
                        &position) &&
        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size)) {
      CGPoint clickPoint = CGPointMake(
          position.x + size.width * (segment == 0 ? 0.25 : 0.75),
          position.y + size.height / 2.0);
      CGPostMouseEvent(clickPoint, true, 1, false);
      usleep(100000);
      CGPostMouseEvent(clickPoint, true, 1, true);
      usleep(100000);
      CGPostMouseEvent(clickPoint, true, 1, false);
      if (sizeValue != NULL) CFRelease(sizeValue);
      if (positionValue != NULL) CFRelease(positionValue);
      CFRelease(control);
      return YES;
    }
    if (sizeValue != NULL) CFRelease(sizeValue);
    if (positionValue != NULL) CFRelease(positionValue);
    CFRelease(control);
  }
  return NO;
}

- (BOOL)runTaskAtPath:(NSString *)path arguments:(NSArray *)arguments;
{
  NSTask *task = [[[NSTask alloc] init] autorelease];
  NSFileHandle *nullDevice = [NSFileHandle fileHandleWithNullDevice];

  [task setLaunchPath:path];
  [task setArguments:arguments];
  [task setStandardOutput:nullDevice];
  [task setStandardError:nullDevice];
  [task launch];
  [task waitUntilExit];
  return [task terminationStatus] == 0;
}

- (BOOL)replaceTextInField:(AXUIElementRef)field withString:(NSString *)string;
{
  CFTypeRef value;
  CFRange range;
  AXValueRef selection;
  AXError error;
  ProcessSerialNumber process;
  unsigned int index;
  NSDate *deadline;

  if (GetProcessForPID([applicationTask_ processIdentifier], &process) != noErr) {
    return NO;
  }
  SetFrontProcess(&process);
  if (AXUIElementSetAttributeValue(field, kAXFocusedAttribute,
                                  kCFBooleanTrue) != kAXErrorSuccess) return NO;
  value = CopyAXAttribute(field, kAXValueAttribute);
  if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
    if (value != NULL) CFRelease(value);
    return NO;
  }
  range = CFRangeMake(0, CFStringGetLength((CFStringRef)value));
  CFRelease(value);
  selection = AXValueCreate(kAXValueCFRangeType, &range);
  error = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute,
                                      selection);
  CFRelease(selection);
  if (error != kAXErrorSuccess) return NO;
  /* AX value setters bypass NSTextField's user-edit notifications on Tiger. */
  for (index = 0; index < MAX([string length], 1); index++) {
    /* Virtual key codes for the test Mac's US keyboard layout. */
    static const char characters[] = "abcdefghijklmnopqrstuvwxyz0123456789./:";
    static const CGKeyCode keyCodes[] = {
      0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
      45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
      29, 18, 19, 20, 21, 23, 22, 26, 28, 25, 47, 44, 41
    };
    unichar character = [string length] != 0 ? [string characterAtIndex:index] : 0;
    CGKeyCode keyCode = 51;

    if (character != 0) {
      const char *position = character < 128 ? strchr(characters, character) : NULL;
      if (position == NULL) return NO;
      keyCode = keyCodes[position - characters];
    }
    if (character == ':') CGPostKeyboardEvent(0, 56, true);
    CGPostKeyboardEvent(character, keyCode, true);
    CGPostKeyboardEvent(character, keyCode, false);
    if (character == ':') CGPostKeyboardEvent(0, 56, false);
    usleep(50000);
  }
  deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
  while ([deadline timeIntervalSinceNow] > 0.0) {
    BOOL matches;

    value = CopyAXAttribute(field, kAXValueAttribute);
    matches = AXValueMatchesString(value, string);
    if (value != NULL) CFRelease(value);
    if (matches) return YES;
    usleep(100000);
  }
  return NO;
}

- (BOOL)testMailFieldValidationAtPath:(NSString *)path;
{
  NSMutableArray *fields = [NSMutableArray array];
  unsigned int indexes[] = {0, 2, 1};
  NSArray *values = [NSArray arrayWithObjects:@"80", @"65536",
      @"https://imap.example.com", nil];
  NSArray *keys = [NSArray arrayWithObjects:@"LocalPort", @"RemotePort",
      @"RemoteHost", nil];
  NSArray *originals = [NSArray arrayWithObjects:@"1143", @"993",
      @"imap.mail.me.com", nil];
  NSArray *messages = [NSArray arrayWithObjects:
      @"The IMAP local port must be a whole number from 1024 to 65535.",
      @"The IMAP server port must be a whole number from 1 to 65535.",
      @"The IMAP server must be a hostname without whitespace, a scheme, a port, or a path.",
      nil];
  unsigned int index;

  [self collectElementsWithRole:kAXTextFieldRole inElement:windowElement_
                         depth:0 results:fields];
  if ([fields count] != 6) return NO;
  for (index = 0; index < 3; index++) {
    AXUIElementRef field = (AXUIElementRef)[fields objectAtIndex:indexes[index]];
    AXUIElementRef message = NULL;
    AXUIElementRef okay;
    NSDate *deadline;
    BOOL saved = NO;

    if (![self replaceTextInField:field withString:[values objectAtIndex:index]]) {
      return NO;
    }
    deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0.0) {
      NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:path];
      id value = [[[configuration objectForKey:@"MailProxy"] objectForKey:@"IMAP"]
          objectForKey:[keys objectAtIndex:index]];

      if ([[value description] isEqualToString:[values objectAtIndex:index]]) {
        saved = YES;
        break;
      }
      usleep(100000);
    }
    okay = [self findElementNamed:@"OK" inElement:applicationElement_ depth:0];
    if (!saved || okay != NULL) {
      if (okay != NULL) CFRelease(okay);
      return NO;
    }
    /* Tab ends editing and presents the validation sheet. */
    CGPostKeyboardEvent(0, 48, true);
    CGPostKeyboardEvent(0, 48, false);
    deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0.0 && message == NULL) {
      message = [self findElementNamed:[messages objectAtIndex:index]
          inElement:applicationElement_ depth:0];
      if (message == NULL) usleep(100000);
    }
    if (message == NULL) return NO;
    CFRelease(message);
    {
      AXUIElementRef sheet = [self findElementWithRole:kAXSheetRole
          inElement:windowElement_ depth:0];

      if (sheet == NULL) return NO;
      CFRelease(sheet);
    }
    if (index == 0) [self captureScreenshotNamed:@"mail-validation-sheet.png"];
    okay = [self findElementNamed:@"OK" inElement:applicationElement_ depth:0];
    if (okay == NULL) return NO;
    AXUIElementPerformAction(okay, kAXPressAction);
    CFRelease(okay);
    deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0.0) {
      AXUIElementRef sheet = [self findElementWithRole:kAXSheetRole
          inElement:windowElement_ depth:0];

      if (sheet == NULL) break;
      CFRelease(sheet);
      usleep(100000);
    }
    if (![self replaceTextInField:field withString:[originals objectAtIndex:index]]) {
      return NO;
    }
  }
  return [self waitForConfigurationAtPath:path imapLocalPort:1143
      imapServer:@"imap.mail.me.com" imapServerPort:993 smtpLocalPort:1587
      smtpServer:@"smtp.mail.me.com" smtpServerPort:587 timeout:5.0];
}

- (BOOL)setMailFieldsWithIMAPLocalPort:(NSString *)imapLocalPort
                            imapServer:(NSString *)imapServer
                        imapServerPort:(NSString *)imapServerPort
                         smtpLocalPort:(NSString *)smtpLocalPort
                            smtpServer:(NSString *)smtpServer
                        smtpServerPort:(NSString *)smtpServerPort;
{
  NSMutableArray *fields = [NSMutableArray array];
  NSArray *values = [NSArray arrayWithObjects:
      imapLocalPort, imapServer, imapServerPort,
      smtpLocalPort, smtpServer, smtpServerPort, nil];
  unsigned int index;

  [self collectElementsWithRole:kAXTextFieldRole
                      inElement:windowElement_
                          depth:0
                        results:fields];
  if ([fields count] != [values count]) {
    return NO;
  }
  for (index = 0; index < [values count]; index++) {
    if (![self replaceTextInField:(AXUIElementRef)[fields objectAtIndex:index]
                       withString:[values objectAtIndex:index]]) {
      return NO;
    }
  }
  usleep(100000);
  return YES;
}

- (BOOL)waitForConfigurationAtPath:(NSString *)path
                     imapLocalPort:(unsigned short)imapLocalPort
                        imapServer:(NSString *)imapServer
                    imapServerPort:(unsigned short)imapServerPort
                     smtpLocalPort:(unsigned short)smtpLocalPort
                        smtpServer:(NSString *)smtpServer
                    smtpServerPort:(unsigned short)smtpServerPort
                           timeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([deadline timeIntervalSinceNow] > 0.0) {
    if (ConfigurationMatches(path, imapLocalPort, imapServer, imapServerPort,
                             smtpLocalPort, smtpServer, smtpServerPort)) {
      return YES;
    }
    usleep(100000);
  }
  return NO;
}

- (BOOL)waitForDaemonRunning:(BOOL)shouldRun timeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([deadline timeIntervalSinceNow] > 0.0) {
    if ([self isDaemonRunning] == shouldRun) {
      return YES;
    }
    usleep(250000);
  }
  return NO;
}

- (BOOL)waitForElementNamed:(NSString *)name timeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([deadline timeIntervalSinceNow] > 0.0) {
    AXUIElementRef element = [self findElementNamed:name
                                         inElement:windowElement_
                                             depth:0];
    if (element != NULL) {
      CFRelease(element);
      return YES;
    }
    usleep(100000);
  }
  return NO;
}

- (BOOL)waitForFileAtPath:(NSString *)path timeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([deadline timeIntervalSinceNow] > 0.0) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
      return YES;
    }
    usleep(250000);
  }
  return NO;
}

- (BOOL)waitForListenerOnPort:(unsigned short)port
                      timeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([deadline timeIntervalSinceNow] > 0.0) {
    int socketDescriptor = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;

    if (socketDescriptor >= 0) {
      memset(&address, 0, sizeof(address));
      address.sin_family = AF_INET;
      address.sin_port = htons(port);
      address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if (connect(socketDescriptor, (struct sockaddr *)&address,
                  sizeof(address)) == 0) {
        close(socketDescriptor);
        return YES;
      }
      close(socketDescriptor);
    }
    usleep(250000);
  }
  return NO;
}

- (BOOL)waitForStatus:(NSString *)status timeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([deadline timeIntervalSinceNow] > 0.0) {
    AXUIElementRef element = [self findElementNamed:status
                                         inElement:windowElement_
                                             depth:0];
    if (element != NULL) {
      CFRelease(element);
      return YES;
    }
    usleep(250000);
  }
  return NO;
}

- (BOOL)waitForWindowWithTimeout:(NSTimeInterval)timeout;
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

  while ([deadline timeIntervalSinceNow] > 0.0) {
    CFTypeRef windows = CopyAXAttribute(applicationElement_,
                                        kAXWindowsAttribute);
    if (windows != NULL && CFGetTypeID(windows) == CFArrayGetTypeID() &&
        CFArrayGetCount((CFArrayRef)windows) > 0) {
      windowElement_ = (AXUIElementRef)CFRetain(
          CFArrayGetValueAtIndex((CFArrayRef)windows, 0));
      CFRelease(windows);
      return YES;
    }
    if (windows != NULL) CFRelease(windows);
    usleep(250000);
  }
  PrintFail(@"Preferences window did not appear");
  return NO;
}

@end
