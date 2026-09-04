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
    NSBox *accountBox;
    NSBox *contactsBox;
    NSBox *calendarsBox;
    NSButtonCell *radioCell;
    NSButton *saveButton;
    NSButton *removeButton;
    NSTextField *helpLabel;
    NSRect accountBoxFrame;
    NSRect contactsBoxFrame;
    NSRect calendarsBoxFrame;
    float innerLeft;
    float innerRight;
    float accountTop;
    const float edgePadding = 8;
    const float boxPadding = 8;
    const float controlSpacing = 4;
    const float boxTitleHeight = 14;
    const float accountBoxHeight = 104;
    const float syncBoxHeight = 98;
    const float actionButtonHeight = 26;

    accountBoxFrame = NSMakeRect(
        edgePadding, NSHeight(frame) - edgePadding - accountBoxHeight,
        NSWidth(frame) - (edgePadding * 2), accountBoxHeight);
    calendarsBoxFrame = NSMakeRect(
        edgePadding,
        edgePadding + actionButtonHeight + edgePadding,
        NSWidth(frame) - (edgePadding * 2), syncBoxHeight);
    contactsBoxFrame = NSMakeRect(
        edgePadding, NSMaxY(calendarsBoxFrame) + edgePadding,
        NSWidth(frame) - (edgePadding * 2), syncBoxHeight);
    innerLeft = NSMinX(accountBoxFrame) + boxPadding;
    innerRight = NSMaxX(accountBoxFrame) - boxPadding;
    accountTop = NSMaxY(accountBoxFrame) - boxTitleHeight - boxPadding;

    accountBox = [[[NSBox alloc]
        initWithFrame:accountBoxFrame] autorelease];
    [accountBox setTitle:@"iCloud Account"];
    [accountBox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:accountBox];

    contactsBox = [[[NSBox alloc]
        initWithFrame:contactsBoxFrame] autorelease];
    [contactsBox setTitle:@"Contacts Sync"];
    [contactsBox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:contactsBox];

    calendarsBox = [[[NSBox alloc]
        initWithFrame:calendarsBoxFrame] autorelease];
    [calendarsBox setTitle:@"Calendar Sync"];
    [calendarsBox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:calendarsBox];

    radioCell = [[[NSButtonCell alloc] init] autorelease];
    [radioCell setButtonType:NSRadioButton];
    contactsSyncMatrix_ = [[NSMatrix alloc]
        initWithFrame:NSMakeRect(innerLeft,
                                 NSMinY(contactsBoxFrame) + boxPadding,
                                 innerRight - innerLeft, 68)
                  mode:NSRadioModeMatrix
             prototype:radioCell
          numberOfRows:3
       numberOfColumns:1];
    [contactsSyncMatrix_ setCellSize:NSMakeSize(innerRight - innerLeft, 20)];
    [contactsSyncMatrix_ setIntercellSpacing:
        NSMakeSize(0, controlSpacing)];
    [contactsSyncMatrix_ setAutosizesCells:YES];
    [contactsSyncMatrix_
        setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [[contactsSyncMatrix_ cellAtRow:0 column:0]
        setTitle:@"Disabled"];
    [[contactsSyncMatrix_ cellAtRow:1 column:0]
        setTitle:@"1-way Sync: iCloud → Address Book"];
    [[contactsSyncMatrix_ cellAtRow:2 column:0]
        setTitle:@"2-way Sync: iCloud ↔ Address Book"];
    [[contactsSyncMatrix_ cellAtRow:2 column:0] setEnabled:NO];
    [self addSubview:contactsSyncMatrix_];

    radioCell = [[[NSButtonCell alloc] init] autorelease];
    [radioCell setButtonType:NSRadioButton];
    calendarsSyncMatrix_ = [[NSMatrix alloc]
        initWithFrame:NSMakeRect(innerLeft,
                                 NSMinY(calendarsBoxFrame) + boxPadding,
                                 innerRight - innerLeft, 68)
                  mode:NSRadioModeMatrix
             prototype:radioCell
          numberOfRows:3
       numberOfColumns:1];
    [calendarsSyncMatrix_ setCellSize:NSMakeSize(innerRight - innerLeft, 20)];
    [calendarsSyncMatrix_ setIntercellSpacing:
        NSMakeSize(0, controlSpacing)];
    [calendarsSyncMatrix_ setAutosizesCells:YES];
    [calendarsSyncMatrix_
        setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [[calendarsSyncMatrix_ cellAtRow:0 column:0]
        setTitle:@"Disabled"];
    [[calendarsSyncMatrix_ cellAtRow:1 column:0]
        setTitle:@"1-way Sync: iCloud → iCal"];
    [[calendarsSyncMatrix_ cellAtRow:2 column:0]
        setTitle:@"2-way Sync: iCloud ↔ iCal"];
    [[calendarsSyncMatrix_ cellAtRow:2 column:0] setEnabled:NO];
    [self addSubview:calendarsSyncMatrix_];

    [self addLabel:@"Apple ID:"
             frame:NSMakeRect(innerLeft, accountTop - 20, 70, 20)];
    usernameField_ = [[NSTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + 70 + controlSpacing,
                                 accountTop - 22,
                                 innerRight - innerLeft - 70 - controlSpacing,
                                 22)];
    [usernameField_
        setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:usernameField_];

    [self addLabel:@"Password:"
             frame:NSMakeRect(innerLeft, accountTop - 46, 70, 20)];
    passwordField_ = [[NSSecureTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + 70 + controlSpacing,
                                 accountTop - 48,
                                 innerRight - innerLeft - 70 - controlSpacing,
                                 22)];
    [passwordField_
        setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:passwordField_];

    [self addLabel:@"Sync every:"
             frame:NSMakeRect(innerLeft, accountTop - 72, 70, 20)];
    intervalField_ = [[NSTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + 70 + controlSpacing,
                                 accountTop - 74, 64, 22)];
    [intervalField_ setAutoresizingMask:NSViewMinYMargin];
    [self addSubview:intervalField_];
    helpLabel = [[[NSTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + 70 + controlSpacing + 64 +
                                     controlSpacing,
                                 accountTop - 72,
                                 innerRight - innerLeft - 70 -
                                     (controlSpacing * 2) - 64,
                                 20)] autorelease];
    [helpLabel setBezeled:NO];
    [helpLabel setDrawsBackground:NO];
    [helpLabel setEditable:NO];
    [helpLabel setSelectable:NO];
    [helpLabel setStringValue:@"minutes"];
    [helpLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:helpLabel];

    removeButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(NSWidth(frame) - edgePadding - 80 -
                                     controlSpacing - 104,
                                 edgePadding, 104, 26)] autorelease];
    [removeButton setTitle:@"Remove Account"];
    [removeButton setBezelStyle:NSRoundedBezelStyle];
    [removeButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [removeButton setTarget:self];
    [removeButton setAction:@selector(removeAccount:)];
    [self addSubview:removeButton];

    saveButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(NSWidth(frame) - edgePadding - 80,
                                 edgePadding, 80, 26)] autorelease];
    [saveButton setTitle:@"Save"];
    [saveButton setBezelStyle:NSRoundedBezelStyle];
    [saveButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [saveButton setTarget:self];
    [saveButton setAction:@selector(saveSettings:)];
    [self addSubview:saveButton];

    /* Tiger does not reliably infer key order for programmatic views. */
    [contactsSyncMatrix_ setNextKeyView:calendarsSyncMatrix_];
    [calendarsSyncMatrix_ setNextKeyView:usernameField_];
    [usernameField_ setNextKeyView:passwordField_];
    [passwordField_ setNextKeyView:intervalField_];
    [intervalField_ setNextKeyView:removeButton];
    [removeButton setNextKeyView:saveButton];
    [saveButton setNextKeyView:contactsSyncMatrix_];

    [self reloadSettings];
  }
  return self;
}

- (void)dealloc;
{
  [contactsSyncMatrix_ release];
  [calendarsSyncMatrix_ release];
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
  [label setAutoresizingMask:NSViewMinYMargin];
  [self addSubview:label];
}

- (void)reloadSettings;
{
  NSString *errorMessage = nil;
  NSDictionary *configuration =
      [RCConfiguration loadConfigurationWithError:&errorMessage];
  NSDictionary *contacts;
  NSString *username;
  NSString *contactsSyncMode;
  NSString *calendarsSyncMode;
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
  contactsSyncMode = [contacts objectForKey:@"ContactsSyncMode"];
  calendarsSyncMode = [contacts objectForKey:@"CalendarsSyncMode"];
  [contactsSyncMatrix_ selectCellAtRow:
      [contactsSyncMode isEqualToString:@"TwoWay"] ? 2 :
      ([contactsSyncMode isEqualToString:@"OneWay"] ||
       (contactsSyncMode == nil &&
        [[contacts objectForKey:@"Enabled"] boolValue])) ? 1 : 0
                                  column:0];
  [calendarsSyncMatrix_ selectCellAtRow:
      [calendarsSyncMode isEqualToString:@"TwoWay"] ? 2 :
      ([calendarsSyncMode isEqualToString:@"OneWay"] ||
       (calendarsSyncMode == nil &&
        [[contacts objectForKey:@"CalendarsEnabled"] boolValue])) ? 1 : 0
                                   column:0];
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
  NSString *contactsSyncMode = [contactsSyncMatrix_ selectedRow] == 2 ?
      @"TwoWay" : ([contactsSyncMatrix_ selectedRow] == 1 ?
          @"OneWay" : @"Disabled");
  NSString *calendarsSyncMode = [calendarsSyncMatrix_ selectedRow] == 2 ?
      @"TwoWay" : ([calendarsSyncMatrix_ selectedRow] == 1 ?
          @"OneWay" : @"Disabled");
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
  if (![RCConfiguration saveContactsSyncMode:contactsSyncMode
      calendarsSyncMode:calendarsSyncMode username:username
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
  if (![RCConfiguration saveContactsSyncMode:@"Disabled"
      calendarsSyncMode:@"Disabled" username:@"" syncInterval:3600
      error:&errorMessage]) {
    [self setError:errorMessage];
    return;
  }
  RCErrorClear(&credentialError);
  if ([username UTF8String] != NULL &&
      !RCICloudCredentialsRemove([username UTF8String], &credentialError)) {
    credentialWarning = [NSString stringWithUTF8String:
        credentialError.message];
  }
  [contactsSyncMatrix_ selectCellAtRow:0 column:0];
  [calendarsSyncMatrix_ selectCellAtRow:0 column:0];
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
