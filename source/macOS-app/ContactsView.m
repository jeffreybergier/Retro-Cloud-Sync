//
//  ContactsView.m
//  RetroCloudSync
//

#import "ContactsView.h"

#import "RCConfiguration.h"
#import "RCServiceController.h"

#include "RCICloudCredentials.h"

#include <string.h>

/* Continuous actions update the readout; commit once dragging has finished. */
@interface RCIntervalSlider : NSSlider {
  BOOL trackingInterval_;
}
- (BOOL)isTrackingInterval;
@end

@implementation RCIntervalSlider
- (BOOL)isTrackingInterval;
{
  return trackingInterval_;
}

- (void)mouseDown:(NSEvent *)event;
{
  trackingInterval_ = YES;
  [super mouseDown:event];
  trackingInterval_ = NO;
  [self sendAction:[self action] to:[self target]];
}
@end

@interface ContactsView (Private)
- (void)addLabel:(NSString *)text frame:(NSRect)frame;
- (void)accountButtonClicked:(id)sender;
- (void)updateAccountButton;
- (void)syncSettingsChanged:(id)sender;
- (void)intervalChanged:(id)sender;
- (void)updateIntervalLabel;
- (BOOL)saveSyncSettings;
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
    NSBox *intervalBox;
    NSButtonCell *radioCell;
    NSRect accountBoxFrame;
    NSRect contactsBoxFrame;
    NSRect calendarsBoxFrame;
    NSRect intervalBoxFrame;
    float innerLeft;
    float innerRight;
    float accountTop;
    const float edgePadding = 8;
    const float boxPadding = 8;
    const float controlSpacing = 4;
    const float boxTitleHeight = 14;
    const float accountBoxHeight = 104;
    const float syncBoxHeight = 98;
    const float intervalBoxHeight = 70;
    const float actionButtonHeight = 26;

    accountBoxFrame = NSMakeRect(
        edgePadding, NSHeight(frame) - edgePadding - accountBoxHeight,
        NSWidth(frame) - (edgePadding * 2), accountBoxHeight);
    contactsBoxFrame = NSMakeRect(
        edgePadding, NSMinY(accountBoxFrame) - edgePadding - syncBoxHeight,
        NSWidth(frame) - (edgePadding * 2), syncBoxHeight);
    calendarsBoxFrame = NSMakeRect(
        edgePadding, NSMinY(contactsBoxFrame) - edgePadding - syncBoxHeight,
        NSWidth(frame) - (edgePadding * 2), syncBoxHeight);
    intervalBoxFrame = NSMakeRect(
        edgePadding, NSMinY(calendarsBoxFrame) - edgePadding - intervalBoxHeight,
        NSWidth(frame) - (edgePadding * 2), intervalBoxHeight);
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
    [contactsBox setTitle:@"Contacts"];
    [contactsBox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:contactsBox];

    calendarsBox = [[[NSBox alloc]
        initWithFrame:calendarsBoxFrame] autorelease];
    [calendarsBox setTitle:@"Calendar"];
    [calendarsBox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:calendarsBox];

    intervalBox = [[[NSBox alloc]
        initWithFrame:intervalBoxFrame] autorelease];
    [intervalBox setTitle:@"Interval"];
    [intervalBox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:intervalBox];

    intervalLabel_ = [[NSTextField alloc]
        initWithFrame:[[intervalBox contentView]
            convertRect:NSMakeRect(innerRight - 120,
                NSMaxY(intervalBoxFrame) - boxTitleHeight - boxPadding - 20,
                120, 20) fromView:self]];
    [intervalLabel_ setBezeled:NO];
    [intervalLabel_ setDrawsBackground:NO];
    [intervalLabel_ setEditable:NO];
    [intervalLabel_ setSelectable:NO];
    [intervalLabel_ setAlignment:NSRightTextAlignment];
    [intervalLabel_ setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [[intervalBox contentView] addSubview:intervalLabel_];

    intervalSlider_ = [[RCIntervalSlider alloc]
        initWithFrame:[[intervalBox contentView]
            convertRect:NSMakeRect(innerLeft,
                NSMinY(intervalBoxFrame) + boxPadding,
                innerRight - innerLeft, 20) fromView:self]];
    [intervalSlider_ setMinValue:1];
    [intervalSlider_ setMaxValue:300];
    [intervalSlider_ setAltIncrementValue:1];
    [intervalSlider_ setContinuous:YES];
    [intervalSlider_ setTarget:self];
    [intervalSlider_ setAction:@selector(intervalChanged:)];
    [intervalSlider_ setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [[intervalBox contentView] addSubview:intervalSlider_];

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
    [contactsSyncMatrix_ setTarget:self];
    [contactsSyncMatrix_ setAction:@selector(syncSettingsChanged:)];
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
    [calendarsSyncMatrix_ setTarget:self];
    [calendarsSyncMatrix_ setAction:@selector(syncSettingsChanged:)];
    [self addSubview:calendarsSyncMatrix_];

    [self addLabel:@"Apple ID:"
             frame:NSMakeRect(innerLeft, accountTop - 24, 70, 20)];
    usernameField_ = [[NSTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + 70 + controlSpacing,
                                 accountTop - 22,
                                 innerRight - innerLeft - 70 - controlSpacing,
                                 22)];
    [usernameField_
        setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [usernameField_ setDelegate:self];
    [self addSubview:usernameField_];

    [self addLabel:@"Password:"
             frame:NSMakeRect(innerLeft, accountTop - 50, 70, 20)];
    passwordField_ = [[NSSecureTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + 70 + controlSpacing,
                                 accountTop - 48,
                                 innerRight - innerLeft - 70 - controlSpacing,
                                 22)];
    [passwordField_
        setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:passwordField_];

    accountButton_ = [[NSButton alloc]
        initWithFrame:[[accountBox contentView]
            convertRect:NSMakeRect(innerRight - 80, accountTop - 76,
                                   80, actionButtonHeight)
               fromView:self]];
    [accountButton_ setTitle:@"Save"];
    [accountButton_ setBezelStyle:NSRoundedBezelStyle];
    [accountButton_ setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [accountButton_ setTarget:self];
    [accountButton_ setAction:@selector(accountButtonClicked:)];
    [[accountBox contentView] addSubview:accountButton_];

    /* Tiger does not reliably infer key order for programmatic views. */
    [contactsSyncMatrix_ setNextKeyView:calendarsSyncMatrix_];
    [usernameField_ setNextKeyView:passwordField_];
    [passwordField_ setNextKeyView:accountButton_];
    [accountButton_ setNextKeyView:contactsSyncMatrix_];
    [calendarsSyncMatrix_ setNextKeyView:intervalSlider_];
    [intervalSlider_ setNextKeyView:usernameField_];

    [self reloadSettings];
  }
  return self;
}

- (void)dealloc;
{
  [usernameField_ setDelegate:nil];
  [contactsSyncMatrix_ release];
  [calendarsSyncMatrix_ release];
  [usernameField_ release];
  [passwordField_ release];
  [intervalSlider_ release];
  [intervalLabel_ release];
  [accountButton_ release];
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
  syncIntervalSeconds_ =
      [[contacts objectForKey:@"SyncIntervalSeconds"] longLongValue];
  [intervalSlider_ setDoubleValue:syncIntervalSeconds_ / 60.0];
  [self updateIntervalLabel];
  [passwordField_ setStringValue:@""];
  [self updateAccountButton];
}

- (void)setError:(NSString *)message;
{
  NSRunAlertPanel(@"Retro Cloud Sync",
      message != nil ? message : @"Unknown error", @"OK", nil, nil);
}

- (void)updateAccountButton;
{
  NSString *username = [[usernameField_ stringValue]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];

  hasCredentials_ = RCICloudCredentialsExist([username UTF8String]);
  [accountButton_ setTitle:hasCredentials_ ? @"Reset" : @"Save"];
  [passwordField_ setEnabled:!hasCredentials_];
  if (hasCredentials_) [passwordField_ setStringValue:@""];
}

- (void)controlTextDidChange:(NSNotification *)notification;
{
  if ([notification object] == usernameField_) {
    [self updateAccountButton];
  }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification;
{
  if ([notification object] == usernameField_) {
    [self syncSettingsChanged:[notification object]];
  }
}

- (void)syncSettingsChanged:(id)sender;
{
  (void)sender;
  if (![self saveSyncSettings]) [self reloadSettings];
}

- (void)updateIntervalLabel;
{
  long long minutes = syncIntervalSeconds_ / 60;

  [intervalLabel_ setStringValue:[NSString stringWithFormat:
      minutes == 1 ? @"%lld minute" : @"%lld minutes", minutes]];
}

- (void)intervalChanged:(id)sender;
{
  int minutes = (int)([intervalSlider_ doubleValue] + 0.5);

  (void)sender;
  [intervalSlider_ setIntValue:minutes];
  syncIntervalSeconds_ = (long long)minutes * 60;
  [self updateIntervalLabel];
  if (![intervalSlider_ isTrackingInterval]) [self syncSettingsChanged:sender];
}

- (BOOL)saveSyncSettings;
{
  NSString *errorMessage = nil;
  NSDictionary *configuration;
  NSDictionary *oldContacts;
  NSString *username = [[usernameField_ stringValue]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *contactsSyncMode = [contactsSyncMatrix_ selectedRow] == 2 ?
      @"TwoWay" : ([contactsSyncMatrix_ selectedRow] == 1 ?
          @"OneWay" : @"Disabled");
  NSString *calendarsSyncMode = [calendarsSyncMatrix_ selectedRow] == 2 ?
      @"TwoWay" : ([calendarsSyncMatrix_ selectedRow] == 1 ?
          @"OneWay" : @"Disabled");
  RCServiceController *serviceController =
      [[[RCServiceController alloc] init] autorelease];
  BOOL serviceWasRunning = [serviceController isServiceRunning];

  configuration = [RCConfiguration
      loadConfigurationWithError:&errorMessage];
  if (configuration == nil) {
    [self setError:errorMessage];
    return NO;
  }
  oldContacts = [RCConfiguration
      contactsConfigurationFromConfiguration:configuration];
  if ([[oldContacts objectForKey:@"Username"] isEqualToString:username] &&
      [[oldContacts objectForKey:@"ContactsSyncMode"]
          isEqualToString:contactsSyncMode] &&
      [[oldContacts objectForKey:@"CalendarsSyncMode"]
          isEqualToString:calendarsSyncMode] &&
      [[oldContacts objectForKey:@"SyncIntervalSeconds"] longLongValue] ==
          syncIntervalSeconds_) {
    return YES;
  }
  if (![RCConfiguration saveContactsSyncMode:contactsSyncMode
      calendarsSyncMode:calendarsSyncMode username:username
      syncInterval:syncIntervalSeconds_ error:&errorMessage]) {
    [self setError:errorMessage];
    return NO;
  }
  if (serviceWasRunning &&
      (![serviceController stopServiceWithError:&errorMessage] ||
       ![serviceController startServiceWithError:&errorMessage])) {
    [self setError:errorMessage];
    return NO;
  }
  return YES;
}

- (void)accountButtonClicked:(id)sender;
{
  NSString *username = [[usernameField_ stringValue]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *password = [passwordField_ stringValue];
  NSString *errorMessage = nil;
  RCError credentialError;
  RCServiceController *serviceController =
      [[[RCServiceController alloc] init] autorelease];

  (void)sender;
  /* Refresh a stale button without turning a Save click into a deletion. */
  if (hasCredentials_ != RCICloudCredentialsExist([username UTF8String])) {
    [self updateAccountButton];
    return;
  }
  RCErrorClear(&credentialError);
  if (hasCredentials_) {
    if (!RCICloudCredentialsRemove([username UTF8String], &credentialError)) {
      [self setError:[NSString stringWithUTF8String:credentialError.message]];
      return;
    }
  } else {
    if ([username length] == 0 || [username UTF8String] == NULL ||
        [password length] == 0 || [password UTF8String] == NULL) {
      [self setError:@"Enter an Apple ID and an app-specific password."];
      return;
    }
    if (![serviceController prepareServiceFilesWithError:&errorMessage]) {
      [self setError:errorMessage];
      return;
    }
    if (!RCICloudCredentialsSave([username UTF8String], [password UTF8String],
        strlen([password UTF8String]),
        [[serviceController installedDaemonPath] fileSystemRepresentation],
        &credentialError)) {
      [self setError:[NSString stringWithUTF8String:credentialError.message]];
      return;
    }
  }
  [passwordField_ setStringValue:@""];
  [self updateAccountButton];
}

@end
