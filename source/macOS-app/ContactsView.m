//
//  ContactsView.m
//  RetroCloudSync
//

#import "ContactsView.h"

#import "RCConfiguration.h"
#import "RCSettingsPresentation.h"
#import "RCServiceController.h"

#include "RCICloudCredentials.h"

#include <string.h>
#include <stdlib.h>

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
- (void)resetAccount:(id)sender;
- (void)updateAccountButton;
- (void)syncSettingsChanged:(id)sender;
- (void)intervalChanged:(id)sender;
- (void)updateIntervalLabel;
- (BOOL)saveSyncSettings;
- (BOOL)saveAccountName:(NSString *)username;
- (BOOL)reloadRunningService;
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
    [calendarsBox setTitle:@"Calendars"];
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
    [[contactsSyncMatrix_ cellAtRow:2 column:0] setEnabled:YES];
    [contactsSyncMatrix_ setToolTip:RCSyncHelp(YES)];
    [contactsSyncMatrix_ setTarget:self];
    [contactsSyncMatrix_ setAction:@selector(syncSettingsChanged:)];
    [self addSubview:contactsSyncMatrix_];

    radioCell = [[[NSButtonCell alloc] init] autorelease];
    [radioCell setButtonType:NSRadioButton];
    calendarsSyncMatrix_ = [[NSMatrix alloc]
        initWithFrame:NSMakeRect(innerLeft,
                                 NSMinY(calendarsBoxFrame) + boxPadding,
                                 innerRight - innerLeft - 160, 68)
                  mode:NSRadioModeMatrix
             prototype:radioCell
          numberOfRows:3
       numberOfColumns:1];
    [calendarsSyncMatrix_ setCellSize:NSMakeSize(innerRight - innerLeft - 160, 20)];
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
    [[calendarsSyncMatrix_ cellAtRow:2 column:0] setEnabled:YES];
    [calendarsSyncMatrix_ setToolTip:RCSyncHelp(NO)];
    [calendarsSyncMatrix_ setTarget:self];
    [calendarsSyncMatrix_ setAction:@selector(syncSettingsChanged:)];
    [self addSubview:calendarsSyncMatrix_];

    {
      NSTextField *historyLabel = [[[NSTextField alloc] initWithFrame:
          NSMakeRect(innerRight - 152, NSMinY(calendarsBoxFrame) + 50, 148, 20)] autorelease];
      [historyLabel setBezeled:NO];
      [historyLabel setDrawsBackground:NO];
      [historyLabel setEditable:NO];
      [historyLabel setSelectable:NO];
      [historyLabel setAlignment:NSRightTextAlignment];
      [historyLabel setStringValue:@"Past events:"];
      [historyLabel setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
      [self addSubview:historyLabel];
    }
    calendarHistoryPopup_ = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(innerRight - 152, NSMinY(calendarsBoxFrame) + 22, 152, 26)
        pullsDown:NO];
    [calendarHistoryPopup_ addItemWithTitle:@"All history"];
    [calendarHistoryPopup_ addItemWithTitle:@"Last 1 year"];
    [calendarHistoryPopup_ addItemWithTitle:@"Last 2 years"];
    [calendarHistoryPopup_ setToolTip:RCCalendarHistoryHelp()];
    [calendarHistoryPopup_ setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [calendarHistoryPopup_ setTarget:self];
    [calendarHistoryPopup_ setAction:@selector(syncSettingsChanged:)];
    [self addSubview:calendarHistoryPopup_];

    [self addLabel:@"Apple ID:"
             frame:NSMakeRect(innerLeft, accountTop - 24, 70, 20)];
    usernameField_ = [[NSTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + 70 + controlSpacing,
                                 accountTop - 22,
                                 innerRight - innerLeft - 70 - controlSpacing,
                                 22)];
    [usernameField_
        setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [usernameField_ setDelegate:(id)self];
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
    [passwordField_ setDelegate:(id)self];
    [self addSubview:passwordField_];

    accountButton_ = [[NSButton alloc]
        initWithFrame:[[accountBox contentView]
            convertRect:NSMakeRect(innerRight - 110, accountTop - 76,
                                   110, actionButtonHeight)
               fromView:self]];
    [accountButton_ setTitle:@"Save Account"];
    [accountButton_ setBezelStyle:NSRoundedBezelStyle];
    [accountButton_ setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [accountButton_ setTarget:self];
    [accountButton_ setAction:@selector(accountButtonClicked:)];
    [[accountBox contentView] addSubview:accountButton_];

    NSButton *reset=[[[NSButton alloc] initWithFrame:[[accountBox contentView]
        convertRect:NSMakeRect(innerRight-258,accountTop-76,140,actionButtonHeight) fromView:self]] autorelease];
    [reset setTitle:@"Remove Password"]; [reset setBezelStyle:NSRoundedBezelStyle];
    [reset setTarget:self]; [reset setAction:@selector(resetAccount:)];
    [reset setToolTip:@"Remove the saved password. Sync preferences are preserved."];
    [reset setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [[accountBox contentView] addSubview:reset];
    [self addLabel:@"Sync options save automatically." frame:NSMakeRect(8, 20, 280, 20)];
    [accountButton_ setToolTip:@"Save the Apple ID and password. Leave the password blank to keep it."];
    [passwordField_ setToolTip:@"Use an app-specific password. Leave blank to keep the saved password."];

    /* Tiger does not reliably infer key order for programmatic views. */
    [contactsSyncMatrix_ setNextKeyView:calendarsSyncMatrix_];
    [usernameField_ setNextKeyView:passwordField_];
    [passwordField_ setNextKeyView:accountButton_];
    [accountButton_ setNextKeyView:contactsSyncMatrix_];
    [calendarsSyncMatrix_ setNextKeyView:calendarHistoryPopup_];
    [calendarHistoryPopup_ setNextKeyView:intervalSlider_];
    [intervalSlider_ setNextKeyView:usernameField_];

    [self reloadSettings];
  }
  return self;
}

- (void)dealloc;
{
  [usernameField_ setDelegate:nil]; [passwordField_ setDelegate:nil];
  [contactsSyncMatrix_ release];
  [calendarsSyncMatrix_ release];
  [calendarHistoryPopup_ release];
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
  if(hasDraft_) return;
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
  {
    id history = [contacts objectForKey:@"CalendarHistoryYears"];
    int years = [history isKindOfClass:[NSNumber class]] ? [history intValue] : 2;
    [calendarHistoryPopup_ selectItemAtIndex:years >= 0 && years <= 2 ? years : 2];
  }
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
  [usernameField_ setStringValue:username ? username : @""];
  syncIntervalSeconds_ =
      [[contacts objectForKey:@"SyncIntervalSeconds"] longLongValue];
  [intervalSlider_ setDoubleValue:syncIntervalSeconds_ / 60.0];
  [self updateIntervalLabel];
  [passwordField_ setStringValue:@""];
  [self updateAccountButton];
}

- (void)setError:(NSString *)message;
{
  NSRunAlertPanel(@"Retro Cloud Sync", @"%@", @"OK", nil, nil,
      message != nil ? message : @"Unknown error");
}

- (void)updateAccountButton;
{
  [accountButton_ setTitle:@"Save Account"];
  [usernameField_ setEnabled:YES];
  [passwordField_ setEnabled:YES];
}

- (void)syncSettingsChanged:(id)sender;
{
  (void)sender;
  [self saveSyncSettings];
}

- (void)controlTextDidChange:(NSNotification *)notification { (void)notification; hasDraft_=YES; }

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

- (BOOL)reloadRunningService;
{
  RCServiceController *service=[[[RCServiceController alloc] init] autorelease];
  NSString *error=nil;
  if([service isServiceRunning] &&
      (![service stopServiceWithError:&error] || ![service startServiceWithError:&error])) {
    [self setError:error]; return NO;
  }
  return YES;
}

- (BOOL)saveAccountName:(NSString *)username;
{
  NSString *error=nil;
  NSDictionary *loaded=[RCConfiguration loadConfigurationWithError:&error];
  if(!loaded) { [self setError:error]; return NO; }
  NSMutableDictionary *configuration=[[loaded mutableCopy] autorelease];
  NSMutableDictionary *contacts=[[[RCConfiguration contactsConfigurationFromConfiguration:loaded] mutableCopy] autorelease];
  [contacts setObject:username forKey:@"Username"];
  [configuration setObject:contacts forKey:@"Contacts"];
  if(![RCConfiguration saveConfiguration:configuration error:&error]) { [self setError:error]; return NO; }
  return [self reloadRunningService];
}

- (BOOL)saveSyncSettings;
{
  NSString *error=nil;
  NSDictionary *configuration=[RCConfiguration loadConfigurationWithError:&error];
  if(!configuration) { [self setError:error]; return NO; }
  NSDictionary *contacts=[RCConfiguration contactsConfigurationFromConfiguration:configuration];
  NSString *contactsMode=[contactsSyncMatrix_ selectedRow]==2 ? @"TwoWay" : [contactsSyncMatrix_ selectedRow]==1 ? @"OneWay" : @"Disabled";
  NSString *calendarsMode=[calendarsSyncMatrix_ selectedRow]==2 ? @"TwoWay" : [calendarsSyncMatrix_ selectedRow]==1 ? @"OneWay" : @"Disabled";
  if(![RCConfiguration saveContactsSyncMode:contactsMode calendarsSyncMode:calendarsMode
      username:[contacts objectForKey:@"Username"] ?: @"" syncInterval:syncIntervalSeconds_
      calendarHistoryYears:(int)[calendarHistoryPopup_ indexOfSelectedItem] error:&error]) {
    [self setError:error];
    /* Restore only options, preserving the account fields being edited. */
    [contactsSyncMatrix_ selectCellAtRow:[[contacts objectForKey:@"ContactsSyncMode"] isEqual:@"TwoWay"] ? 2 : [[contacts objectForKey:@"ContactsSyncMode"] isEqual:@"OneWay"] ? 1 : 0 column:0];
    [calendarsSyncMatrix_ selectCellAtRow:[[contacts objectForKey:@"CalendarsSyncMode"] isEqual:@"TwoWay"] ? 2 : [[contacts objectForKey:@"CalendarsSyncMode"] isEqual:@"OneWay"] ? 1 : 0 column:0];
    [calendarHistoryPopup_ selectItemAtIndex:[[contacts objectForKey:@"CalendarHistoryYears"] intValue]];
    syncIntervalSeconds_=[[contacts objectForKey:@"SyncIntervalSeconds"] longLongValue];
    [intervalSlider_ setDoubleValue:syncIntervalSeconds_/60.0]; [self updateIntervalLabel];
    return NO;
  }
  return [self reloadRunningService];
}

- (void)accountButtonClicked:(id)sender;
{
  (void)sender;
  if(![[self window] makeFirstResponder:nil]) return;
  NSString *username=[[usernameField_ stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *password=[passwordField_ stringValue];
  RCError error;
  if(![username length]) {
    [self setError:@"Enter an Apple ID and an app-specific password."]; return;
  }
  if([password length]) {
    RCServiceController *controller=[[[RCServiceController alloc] init] autorelease];
    NSString *message=nil;
    if(![controller prepareServiceFilesWithError:&message]) { [self setError:message]; return; }
    if(!RCICloudCredentialsSave([username UTF8String],[password UTF8String],strlen([password UTF8String]),
        [[controller installedDaemonPath] fileSystemRepresentation],&error)) {
      [self setError:@"The password could not be saved in Keychain."]; return;
    }
    [passwordField_ setStringValue:@""];
  }
  [usernameField_ setStringValue:username];
  if([self saveAccountName:username]) { hasDraft_=NO; [self updateAccountButton]; }
}

- (void)resetAccount:(id)sender;
{
  (void)sender;
  /* Reset the committed account, never a different account being typed. */
  NSString *message=nil;
  NSDictionary *configuration=[RCConfiguration loadConfigurationWithError:&message];
  if(!configuration) { [self setError:message]; return; }
  NSString *username=[[[configuration objectForKey:@"Contacts"] objectForKey:@"Username"] copy];
  RCError error;
  if([username length] && !RCICloudCredentialsRemove([username UTF8String],&error)) {
    [self setError:@"The saved password could not be removed from Keychain."];
    [username release]; return;
  }
  [username release];
  [passwordField_ setStringValue:@""]; [self updateAccountButton];
  [self reloadRunningService];
}

@end
