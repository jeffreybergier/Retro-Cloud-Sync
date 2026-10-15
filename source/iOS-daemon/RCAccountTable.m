#import "RCIOSConfiguration.h"
#import "RCSettingsPresentation.h"
#import "RCAccountTable.h"
#import "RCIOSAccess.h"
#import <Security/Security.h>
#include "RCICloudCredentials.h"
#include "RCIOSCredentialIdentity.h"
static NSString *const RCAccountChoiceChanged = @"RCAccountChoiceChanged";
@interface RCChoiceTable : AICollectionTableViewController {
  NSMutableDictionary *settings_; NSString *key_; NSArray *values_; NSArray *labels_; NSString *help_;
}
- (id)initWithSettings:(NSMutableDictionary *)settings key:(NSString *)key title:(NSString *)title
    values:(NSArray *)values labels:(NSArray *)labels help:(NSString *)help;
@end
@implementation RCChoiceTable
- (NSArray *)collectionIdentifiersForSection:(NSInteger)section;
{ return [self collectionFixedIdentifiersForSection:section]; }
- (id)initWithSettings:(NSMutableDictionary *)settings key:(NSString *)key title:(NSString *)title values:(NSArray *)values labels:(NSArray *)labels help:(NSString *)help {
  if((self=[super initWithStyle:UITableViewStyleGrouped])) { settings_=[settings retain]; key_=[key copy]; values_=[values copy]; labels_=[labels copy]; help_=[help copy]; [self setTitle:title]; } return self;
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; (void)section; return [values_ count]; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section { (void)table; (void)section; return help_; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"choice"];
  if(!cell) cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"choice"] autorelease];
  [[cell textLabel] setText:[labels_ objectAtIndex:[path row]]];
  [cell setAccessoryType:[[settings_ objectForKey:key_] isEqual:[values_ objectAtIndex:[path row]]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone]; return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
  [[NSNotificationCenter defaultCenter] postNotificationName:RCAccountChoiceChanged object:settings_
      userInfo:@{@"key":key_, @"value":[values_ objectAtIndex:[path row]]}];
  [self refreshCollection];
  [[self navigationController] popViewControllerAnimated:YES];
}
- (void)dealloc { [settings_ release]; [key_ release]; [values_ release]; [labels_ release]; [help_ release]; [super dealloc]; }
@end

/* Account discovery reads attributes only, never the saved password. Do not
   guess which account to use if several credentials have been retained. */
static NSString *SingleSavedAccount(void) {
  NSDictionary *query=@{(id)kSecClass:(id)kSecClassGenericPassword,
      (id)kSecAttrService:@RCIOS_KEYCHAIN_SERVICE,
      (id)kSecAttrAccessGroup:@RCIOS_KEYCHAIN_GROUP,
      (id)kSecReturnAttributes:@YES, (id)kSecMatchLimit:(id)kSecMatchLimitAll};
  CFTypeRef result=NULL;
  OSStatus status=SecItemCopyMatching((CFDictionaryRef)query,&result);
  NSString *account=nil;
  if(status==errSecSuccess && result && CFGetTypeID(result)==CFArrayGetTypeID() && [(NSArray *)result count]==1) {
    id attributes=[(NSArray *)result objectAtIndex:0];
    id name=[attributes isKindOfClass:[NSDictionary class]] ? [attributes objectForKey:(id)kSecAttrAccount] : nil;
    if([name isKindOfClass:[NSString class]] && [name length]) account=[[name copy] autorelease];
  }
  if(result) CFRelease(result);
  return account;
}


@interface RCAccountTable ()
- (BOOL)saveSetting:(NSString *)key value:(id)value;
- (void)intervalChanged:(UISlider *)slider;
- (void)saveInterval:(UISlider *)slider;
@end

@implementation RCAccountTable
/* Replacement cells must transfer ownership of retained editor controls. */
- (void)bindAccessory:(UIView *)control toCell:(UITableViewCell *)cell {
  if(!accessoryCells_) accessoryCells_=[[NSMutableDictionary alloc] init];
  NSValue *key=[NSValue valueWithNonretainedObject:control];
  UITableViewCell *old=[accessoryCells_ objectForKey:key];
  if(old!=cell) [old setAccessoryView:nil];
  [cell setAccessoryView:control]; [accessoryCells_ setObject:cell forKey:key];
}
- (NSArray *)collectionIdentifiersForSection:(NSInteger)section;
{ return [self collectionFixedIdentifiersForSection:section]; }
- (id)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad {
  [super viewDidLoad]; [self setTitle:@"Sync"];
  NSDictionary *loaded=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
  unreadable_=!loaded && [[NSFileManager defaultManager] fileExistsAtPath:RCIOSConfigPath()];
  if(!loaded) loaded=[NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Config.example" ofType:@"plist"]];
  if(![[loaded objectForKey:@"Contacts"] isKindOfClass:[NSDictionary class]]) { unreadable_=YES; loaded=nil; }
  config_=[loaded mutableCopy]; settings_=[[config_ objectForKey:@"Contacts"] mutableCopy];
  for(NSString *key in @[@"Username",@"ContactsSyncMode",@"CalendarsSyncMode"])
    if(![[settings_ objectForKey:key] isKindOfClass:[NSString class]]) unreadable_=YES;
  if(unreadable_) { [settings_ release]; settings_=[[NSMutableDictionary alloc] init]; }

  if(![[NSFileManager defaultManager] fileExistsAtPath:RCIOSConfigPath()]) {
    [settings_ setObject:@"" forKey:@"Username"];
    [settings_ setObject:@"Disabled" forKey:@"ContactsSyncMode"]; [settings_ setObject:@"Disabled" forKey:@"CalendarsSyncMode"];
  }
  if(!unreadable_) [config_ setObject:settings_ forKey:@"Contacts"];
  username_=[[UITextField alloc] initWithFrame:CGRectMake(0,0,200,32)];
  password_=[[UITextField alloc] initWithFrame:CGRectMake(0,0,200,32)];
  for(UITextField *field in [NSArray arrayWithObjects:username_,password_,nil]) {
    [field setAutocapitalizationType:UITextAutocapitalizationTypeNone]; [field setAutocorrectionType:UITextAutocorrectionTypeNo];
    [field setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter]; [field setDelegate:self]; [field setReturnKeyType:UIReturnKeyDone];
  }
  [username_ setKeyboardType:UIKeyboardTypeEmailAddress]; [username_ setPlaceholder:@"Apple ID"]; [username_ setText:[settings_ objectForKey:@"Username"]];
  [password_ setSecureTextEntry:YES];
  [username_ addTarget:self action:@selector(updateSavedPassword) forControlEvents:UIControlEventEditingChanged];
  if(!unreadable_ && ![[username_ text] length]) {
    NSString *account=SingleSavedAccount();
    if(account) [username_ setText:account];
  }
  [self updateSavedPassword];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(accountChoiceChanged:) name:RCAccountChoiceChanged object:settings_];
  intervalSlider_=[[UISlider alloc] initWithFrame:CGRectMake(0,0,240,32)];
  [intervalSlider_ setMinimumValue:1]; [intervalSlider_ setMaximumValue:300];
  [intervalSlider_ setValue:[[settings_ objectForKey:@"SyncIntervalSeconds"] integerValue]/60.0];
  [intervalSlider_ setAccessibilityLabel:@"Sync interval"];
  [intervalSlider_ addTarget:self action:@selector(intervalChanged:) forControlEvents:UIControlEventValueChanged];
  [intervalSlider_ addTarget:self action:@selector(saveInterval:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
  intervalLabel_=[[UILabel alloc] initWithFrame:CGRectMake(0,0,180,32)];
  [intervalLabel_ setTextAlignment:(NSTextAlignment)UITextAlignmentRight];
  [intervalLabel_ setBackgroundColor:[UIColor clearColor]];
  [intervalLabel_ setText:RCIntervalText([[settings_ objectForKey:@"SyncIntervalSeconds"] integerValue]/60)];
  [self refreshCollection];
}
- (BOOL)saveSetting:(NSString *)key value:(id)value {
  NSDictionary *latest=[[NSFileManager defaultManager] fileExistsAtPath:RCIOSConfigPath()] ?
      [NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()] : config_;
  if(unreadable_ || ![[latest objectForKey:@"Contacts"] isKindOfClass:[NSDictionary class]]) {
    RCIOSMessage(@"Cannot save",@"The configuration could not be read."); return NO;
  }
  NSMutableDictionary *updated=[[latest mutableCopy] autorelease];
  NSMutableDictionary *sync=[[[latest objectForKey:@"Contacts"] mutableCopy] autorelease];
  [sync setObject:value forKey:key]; [updated setObject:sync forKey:@"Contacts"];
  [updated setObject:[NSDate date] forKey:@"SettingsUpdatedAt"];
  if(!RCIOSSaveConfiguration(updated)) { RCIOSMessage(@"Cannot save",@"The configuration could not be saved."); return NO; }
  [settings_ setDictionary:sync];
  [config_ release]; config_=[updated mutableCopy];
  if(([key isEqual:@"ContactsSyncMode"] || [key isEqual:@"CalendarsSyncMode"] || [key isEqual:@"Username"]) &&
      ![[updated objectForKey:@"SyncPaused"] boolValue] && ![[updated objectForKey:@"ServicePaused"] boolValue])
    RCIOSRequestAccess(![[sync objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"],
        ![[sync objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"]);
  return YES;
}
- (void)accountChoiceChanged:(NSNotification *)note {
  [self saveSetting:[[note userInfo] objectForKey:@"key"] value:[[note userInfo] objectForKey:@"value"]];
  [self refreshCollection];
}
- (void)intervalChanged:(UISlider *)slider {
  NSInteger minutes=MAX(1,MIN(300,(NSInteger)([slider value]+0.5f)));
  [slider setValue:minutes];
  [intervalLabel_ setText:RCIntervalText(minutes)];
  [slider setAccessibilityValue:RCIntervalText(minutes)];
  if(![slider isTracking]) [self saveInterval:slider];
}
- (void)saveInterval:(UISlider *)slider {
  NSInteger seconds=(NSInteger)([slider value]+0.5f)*60;
  if(seconds==[[settings_ objectForKey:@"SyncIntervalSeconds"] integerValue]) return;
  if(![self saveSetting:@"SyncIntervalSeconds" value:[NSNumber numberWithInteger:seconds]]) {
    [slider setValue:[[settings_ objectForKey:@"SyncIntervalSeconds"] integerValue]/60.0];
    [intervalLabel_ setText:RCIntervalText([[settings_ objectForKey:@"SyncIntervalSeconds"] integerValue]/60)];
  }
}
- (void)updateSavedPassword {
  NSString *username=[[username_ text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  char *saved=NULL; RCError error;
  BOOL found=[username length] && RCICloudCredentialsCopyUsername([username UTF8String],&saved,&error);
  free(saved);
  [password_ setPlaceholder:found ? @"Saved in Keychain" : @"Password"];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [[self view] endEditing:YES]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; return section==0 ? 4 : (section==1 ? 1 : 2); }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { (void)table; return [@[@"iCloud Account",@"Contacts",@"Calendars",@"Interval"] objectAtIndex:section]; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
  (void)table;
  if(section==0) return @"Save Account stores your Apple ID and app-specific password. Remove Password deletes only the saved password. Sync options save automatically.";
  if(section==1 || section==2) return @"1-way downloads from iCloud. 2-way also updates iCloud. Disabled leaves Mail unchanged.";
  return @"Changes save automatically. The interval steps by one minute.";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  (void)table; UITableViewCell *cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil] autorelease];
  NSInteger row=[path row],section=[path section];
  if(section==0 && row<2) { [[cell textLabel] setText:row ? @"Password" : @"Apple ID"]; [self bindAccessory:row ? password_ : username_ toCell:cell]; [cell setSelectionStyle:UITableViewCellSelectionStyleNone]; }
  else if(section==0) {
    [[cell textLabel] setText:row==2 ? @"Save Account" : @"Remove Password"];
    [[cell textLabel] setTextColor:row==2 ? [UIColor blueColor] : [UIColor redColor]];
    [cell setAccessibilityTraits:UIAccessibilityTraitButton];
  } else if(section==3) {
    [[cell textLabel] setText:row==0 ? @"Interval" : @""];
    [self bindAccessory:row==0 ? (UIView *)intervalLabel_ : (UIView *)intervalSlider_ toCell:cell];
    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
  }
  else {
    BOOL mode=section==1 || (section==2 && row==0);
    BOOL history=section==2 && row==1;
    NSString *key=section==1 ? @"ContactsSyncMode" : (section==2 ? (row ? @"CalendarHistoryYears" : @"CalendarsSyncMode") : @"SyncIntervalSeconds");
    [[cell textLabel] setText:mode ? @"Sync" : (history ? @"Past events" : @"Interval")];
    id value=[settings_ objectForKey:key]; NSString *label;
    if(mode) label=[value isEqual:@"TwoWay"] ? @"2-way Sync" : ([value isEqual:@"OneWay"] ? @"1-way Sync" : @"Disabled");
    else if(history) label=[value intValue]==1 ? @"Last 1 year" : ([value intValue]==2 ? @"Last 2 years" : @"All history");
    else label=RCIntervalText([value integerValue]/60);
    [[cell detailTextLabel] setText:label]; [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
  } return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
  [table deselectRowAtIndexPath:path animated:YES];
  if([path section]==0) { if([path row]==2) [self save]; else if([path row]==3) [self resetAccount]; return; }
  if([path section]==3) return;
  [[self view] endEditing:YES]; NSInteger row=[path row],section=[path section];
  BOOL mode=section==1 || (section==2 && row==0);
  BOOL history=section==2 && row==1;
  NSString *key=section==1 ? @"ContactsSyncMode" : (section==2 ? (row ? @"CalendarHistoryYears" : @"CalendarsSyncMode") : @"SyncIntervalSeconds");
  NSArray *values=mode ? @[@"Disabled",@"OneWay",@"TwoWay"] : (history ? @[@0,@1,@2] : @[@300,@900,@1800,@3600]);
  NSArray *labels=mode ? @[@"Disabled",@"1-way Sync",@"2-way Sync"] : (history ? @[@"All history",@"Last 1 year",@"Last 2 years"] : @[@"5 minutes",@"15 minutes",@"30 minutes",@"1 hour"]);
  NSString *help=mode ? RCSyncHelp(section==1) : (history ? RCCalendarHistoryHelp() : @"How often to check iCloud for changes.");
  RCChoiceTable *choices=[[RCChoiceTable alloc] initWithSettings:settings_ key:key title:mode ? (section==1 ? @"Contacts Sync" : @"Calendar Sync") : [[[table cellForRowAtIndexPath:path] textLabel] text] values:values labels:labels help:help];
  [[self navigationController] pushViewController:choices animated:YES]; [choices release];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder]; return YES; }
- (void)save {
  [[self view] endEditing:YES];
  if(unreadable_) { RCIOSMessage(@"Cannot save",@"The configuration could not be read."); return; }
  NSString *username=[[username_ text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if(![username length]) { RCIOSMessage(@"Account required",@"Enter your Apple ID."); return; }
  RCError error;
  if([[password_ text] length]) {
    NSData *secret=[[password_ text] dataUsingEncoding:NSUTF8StringEncoding];
    if(!RCICloudCredentialsSave([username UTF8String],[secret bytes],[secret length],NULL,&error)) {
      RCIOSMessage(@"Cannot save",@"The password could not be saved in Keychain."); return;
    }
    [password_ setText:@""];
  }
  if(![self saveSetting:@"Username" value:username]) return;
  [username_ setText:username]; [self updateSavedPassword];
  RCIOSMessage(@"Saved",@"Your account has been saved.");
}
- (void)resetAccount {
  NSDictionary *latest=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
  NSString *account=[[latest objectForKey:@"Contacts"] objectForKey:@"Username"];
  if(![account length]) { RCIOSMessage(@"Cannot remove password",@"Save an account first."); return; }
  RCError error;
  if(!RCICloudCredentialsRemove([account UTF8String],&error)) {
    RCIOSMessage(@"Password not removed",@"The saved password could not be removed from Keychain."); return;
  }
  [password_ setText:@""]; [self updateSavedPassword];
  [self saveSetting:@"Username" value:account];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [accessoryCells_ release]; [intervalSlider_ release]; [intervalLabel_ release]; [config_ release]; [settings_ release]; [username_ release]; [password_ release]; [super dealloc]; }
@end
