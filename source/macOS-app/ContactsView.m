//
//  ContactsView.m
//  RetroCloudSync
//

#import "ContactsView.h"

#import "RCConfiguration.h"
#import "RCServiceController.h"

#include "RCICloudCredentials.h"

#include <string.h>

@interface ContactsView (Private)
- (void)addLabel:(NSString *)text frame:(NSRect)frame;
- (void)saveSettings:(id)sender;
- (void)removeAccount:(id)sender;
- (void)setError:(NSString *)message;
@end

@implementation ContactsView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    NSBox *box;
    NSButton *saveButton;
    NSButton *removeButton;
    NSTextField *helpLabel;

    box = [[[NSBox alloc] initWithFrame:NSMakeRect(16, 64, 448, 240)]
        autorelease];
    [box setTitle:@"Contacts & Calendars"];
    [self addSubview:box];

    enabledButton_ = [[NSButton alloc] initWithFrame:NSMakeRect(116, 260, 310, 20)];
    [enabledButton_ setButtonType:NSSwitchButton];
    [enabledButton_ setTitle:@"Sync Contacts"];
    [self addSubview:enabledButton_];

    calendarsEnabledButton_ = [[NSButton alloc]
        initWithFrame:NSMakeRect(116, 236, 310, 20)];
    [calendarsEnabledButton_ setButtonType:NSSwitchButton];
    [calendarsEnabledButton_ setTitle:@"Sync Calendars"];
    [self addSubview:calendarsEnabledButton_];

    [self addLabel:@"Apple ID:" frame:NSMakeRect(30, 202, 78, 20)];
    usernameField_ = [[NSTextField alloc] initWithFrame:NSMakeRect(116, 200, 320, 22)];
    [self addSubview:usernameField_];

    [self addLabel:@"Password:" frame:NSMakeRect(30, 168, 78, 20)];
    passwordField_ = [[NSSecureTextField alloc]
        initWithFrame:NSMakeRect(116, 166, 320, 22)];
    [self addSubview:passwordField_];

    [self addLabel:@"Sync every:" frame:NSMakeRect(30, 136, 78, 20)];
    intervalField_ = [[NSTextField alloc]
        initWithFrame:NSMakeRect(116, 134, 64, 22)];
    [self addSubview:intervalField_];
    helpLabel = [[[NSTextField alloc]
        initWithFrame:NSMakeRect(186, 136, 250, 20)] autorelease];
    [helpLabel setBezeled:NO];
    [helpLabel setDrawsBackground:NO];
    [helpLabel setEditable:NO];
    [helpLabel setSelectable:NO];
    [helpLabel setStringValue:@"minutes"];
    [self addSubview:helpLabel];

    removeButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(276, 12, 104, 26)] autorelease];
    [removeButton setTitle:@"Remove Account"];
    [removeButton setBezelStyle:NSRoundedBezelStyle];
    [removeButton setTarget:self];
    [removeButton setAction:@selector(removeAccount:)];
    [self addSubview:removeButton];

    saveButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(388, 12, 80, 26)] autorelease];
    [saveButton setTitle:@"Save"];
    [saveButton setBezelStyle:NSRoundedBezelStyle];
    [saveButton setTarget:self];
    [saveButton setAction:@selector(saveSettings:)];
    [self addSubview:saveButton];

    /* Tiger does not reliably infer key order for programmatic views. */
    [enabledButton_ setNextKeyView:calendarsEnabledButton_];
    [calendarsEnabledButton_ setNextKeyView:usernameField_];
    [usernameField_ setNextKeyView:passwordField_];
    [passwordField_ setNextKeyView:intervalField_];
    [intervalField_ setNextKeyView:removeButton];
    [removeButton setNextKeyView:saveButton];
    [saveButton setNextKeyView:enabledButton_];

    [self reloadSettings];
  }
  return self;
}

- (void)dealloc;
{
  [enabledButton_ release];
  [calendarsEnabledButton_ release];
  [usernameField_ release];
  [passwordField_ release];
  [intervalField_ release];
  [super dealloc];
}

- (void)addLabel:(NSString *)text frame:(NSRect)frame;
{
  NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
  [label setBezeled:NO];
  [label setDrawsBackground:NO];
  [label setEditable:NO];
  [label setSelectable:NO];
  [label setAlignment:NSRightTextAlignment];
  [label setStringValue:text];
  [self addSubview:label];
}

- (void)reloadSettings;
{
  NSString *errorMessage = nil;
  NSDictionary *configuration =
      [RCConfiguration loadConfigurationWithError:&errorMessage];
  NSDictionary *contacts;
  NSString *username;
  char *password = NULL;
  size_t passwordLength = 0;
  RCError credentialError;

  if (configuration == nil) {
    [self setError:errorMessage];
    return;
  }
  contacts = [RCConfiguration
      contactsConfigurationFromConfiguration:configuration];
  username = [contacts objectForKey:@"Username"];
  [enabledButton_ setState:[[contacts objectForKey:@"Enabled"] boolValue] ?
                                NSOnState : NSOffState];
  [calendarsEnabledButton_ setState:
      [[contacts objectForKey:@"CalendarsEnabled"] boolValue] ?
          NSOnState : NSOffState];
  [usernameField_ setStringValue:username];
  [intervalField_ setIntValue:
      [[contacts objectForKey:@"SyncIntervalSeconds"] intValue] / 60];
  RCErrorClear(&credentialError);
  if ([username length] != 0 && [username UTF8String] != NULL &&
      RCICloudCredentialsCopyPassword([username UTF8String], &password,
                                      &passwordLength, &credentialError)) {
    NSString *passwordString = [[[NSString alloc]
        initWithBytes:password
               length:passwordLength
             encoding:NSUTF8StringEncoding] autorelease];

    [passwordField_ setStringValue:
        passwordString != nil ? passwordString : @""];
  } else {
    [passwordField_ setStringValue:@""];
  }
  RCICloudCredentialsClearPassword(password, passwordLength);
}

- (void)setError:(NSString *)message;
{
  NSRunAlertPanel(@"Retro Cloud Sync",
      message != nil ? message : @"Unknown error", @"OK", nil, nil);
}

- (void)saveSettings:(id)sender;
{
  NSString *errorMessage = nil;
  NSDictionary *configuration;
  NSDictionary *oldContacts;
  NSString *oldUsername;
  NSString *username = [[usernameField_ stringValue]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *password = [passwordField_ stringValue];
  unsigned int minutes = (unsigned int)[intervalField_ intValue];
  BOOL enabled = [enabledButton_ state] == NSOnState;
  BOOL calendarsEnabled = [calendarsEnabledButton_ state] == NSOnState;
  BOOL passwordAlreadyExists = NO;
  NSString *credentialWarning = nil;
  RCError credentialError;
  RCServiceController *serviceController =
      [[[RCServiceController alloc] init] autorelease];
  BOOL serviceWasRunning = [serviceController isServiceRunning];

  (void)sender;
  if ([username length] == 0 || minutes == 0 || minutes > 10080) {
    [self setError:@"Enter an Apple ID and a sync interval from 1 to 10080 minutes."];
    return;
  }
  configuration = [RCConfiguration
      loadConfigurationWithError:&errorMessage];
  if (configuration == nil) {
    [self setError:errorMessage];
    return;
  }
  oldContacts = [RCConfiguration
      contactsConfigurationFromConfiguration:configuration];
  oldUsername = [oldContacts objectForKey:@"Username"];
  RCErrorClear(&credentialError);
  if ([username UTF8String] != NULL) {
    passwordAlreadyExists = RCICloudCredentialsExist([username UTF8String]);
  }
  if ([password length] == 0 && !passwordAlreadyExists) {
    [self setError:@"Enter an app-specific password for this Apple ID."];
    return;
  }
  if ([password length] != 0) {
    if (![serviceController prepareServiceFilesWithError:&errorMessage]) {
      [self setError:errorMessage];
      return;
    }
    RCErrorClear(&credentialError);
    if ([username UTF8String] == NULL || [password UTF8String] == NULL ||
        !RCICloudCredentialsSave([username UTF8String], [password UTF8String],
            strlen([password UTF8String]),
            [[serviceController installedDaemonPath] fileSystemRepresentation],
            &credentialError)) {
      [self setError:[NSString stringWithUTF8String:credentialError.message]];
      return;
    }
  }
  if (![RCConfiguration saveContactsEnabled:enabled
      calendarsEnabled:calendarsEnabled username:username
      syncInterval:minutes * 60 error:&errorMessage]) {
    [self setError:errorMessage];
    return;
  }
  if (![oldUsername isEqualToString:username] && [oldUsername length] != 0) {
    RCErrorClear(&credentialError);
    if (!RCICloudCredentialsRemove([oldUsername UTF8String],
                                   &credentialError)) {
      credentialWarning = [NSString stringWithUTF8String:
          credentialError.message];
    }
  }
  if (serviceWasRunning &&
      (![serviceController stopServiceWithError:&errorMessage] ||
       ![serviceController startServiceWithError:&errorMessage])) {
    [self setError:errorMessage];
    return;
  }
  if (credentialWarning != nil) [self setError:credentialWarning];
}

- (void)removeAccount:(id)sender;
{
  NSString *username = [usernameField_ stringValue];
  NSString *errorMessage = nil;
  RCError credentialError;
  NSString *credentialWarning = nil;
  RCServiceController *serviceController =
      [[[RCServiceController alloc] init] autorelease];
  BOOL serviceWasRunning = [serviceController isServiceRunning];

  (void)sender;
  if (![RCConfiguration saveContactsEnabled:NO calendarsEnabled:NO
      username:@"" syncInterval:3600 error:&errorMessage]) {
    [self setError:errorMessage];
    return;
  }
  RCErrorClear(&credentialError);
  if ([username UTF8String] != NULL &&
      !RCICloudCredentialsRemove([username UTF8String], &credentialError)) {
    credentialWarning = [NSString stringWithUTF8String:
        credentialError.message];
  }
  [enabledButton_ setState:NSOffState];
  [calendarsEnabledButton_ setState:NSOffState];
  [usernameField_ setStringValue:@""];
  [passwordField_ setStringValue:@""];
  [intervalField_ setIntValue:60];
  if (serviceWasRunning &&
      (![serviceController stopServiceWithError:&errorMessage] ||
       ![serviceController startServiceWithError:&errorMessage])) {
    [self setError:errorMessage];
    return;
  }
  if (credentialWarning != nil) [self setError:credentialWarning];
}

@end
