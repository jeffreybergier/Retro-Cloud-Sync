#import "RCIOSConfiguration.h"
#import "RCSettingsPresentation.h"
#import "RCAccountTable.h"
#import "RCIOSAccess.h"
#import <Security/Security.h>
#include "RCICloudCredentials.h"
#include "RCIOSCredentialIdentity.h"
@interface RCChoiceTable : UITableViewController {
  NSMutableDictionary *settings_; NSString *key_; NSArray *values_; NSArray *labels_; NSString *help_;
}
- (id)initWithSettings:(NSMutableDictionary *)settings key:(NSString *)key title:(NSString *)title
    values:(NSArray *)values labels:(NSArray *)labels help:(NSString *)help;
@end
@implementation RCChoiceTable
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
  [settings_ setObject:[values_ objectAtIndex:[path row]] forKey:key_]; [table reloadData];
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


@implementation RCAccountTable
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
  [[self navigationItem] setLeftBarButtonItem:[[[UIBarButtonItem alloc] initWithTitle:@"Reset" style:UIBarButtonItemStylePlain target:self action:@selector(resetAccount)] autorelease]];
  [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)] autorelease]];
}
- (void)updateSavedPassword {
  NSString *username=[[username_ text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  char *saved=NULL; RCError error;
  BOOL found=[username length] && RCICloudCredentialsCopyUsername([username UTF8String],&saved,&error);
  free(saved);
  [password_ setPlaceholder:found ? @"Saved in Keychain" : @"Password"];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if(!unreadable_ && ![[username_ text] length]) {
    NSString *account=SingleSavedAccount();
    if(account) [username_ setText:account];
  }
  [self updateSavedPassword];
  [[self tableView] reloadData];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [[self view] endEditing:YES]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; return section==0 || section==2 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { (void)table; return [@[@"iCloud Account",@"Contacts",@"Calendars",@"Interval"] objectAtIndex:section]; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
  (void)table;
  if(section==0) return @"Use an app-specific password; leave blank to keep it. Save applies all Sync settings. Reset disables sync and removes the saved password.";
  if(section==1 || section==2) return @"1-way downloads from iCloud. 2-way also updates iCloud. Disabled leaves Mail unchanged.";
  return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  (void)table; UITableViewCell *cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil] autorelease];
  NSInteger row=[path row],section=[path section];
  if(section==0) { [[cell textLabel] setText:row ? @"Password" : @"Apple ID"]; [cell setAccessoryView:row ? password_ : username_]; [cell setSelectionStyle:UITableViewCellSelectionStyleNone]; }
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
  [table deselectRowAtIndexPath:path animated:YES]; if([path section]==0) return;
  [[self view] endEditing:YES]; NSInteger row=[path row],section=[path section];
  BOOL mode=section==1 || (section==2 && row==0);
  BOOL history=section==2 && row==1;
  NSString *key=section==1 ? @"ContactsSyncMode" : (section==2 ? (row ? @"CalendarHistoryYears" : @"CalendarsSyncMode") : @"SyncIntervalSeconds");
  NSArray *values=mode ? @[@"Disabled",@"OneWay",@"TwoWay"] : (history ? @[@0,@1,@2] : @[@300,@900,@1800,@3600]);
  NSArray *labels=mode ? @[@"Disabled",@"1-way Sync",@"2-way Sync"] : (history ? @[@"All history",@"Last 1 year",@"Last 2 years"] : @[@"5 minutes",@"15 minutes",@"30 minutes",@"1 hour"]);
  if(!mode && !history) {
    NSMutableArray *minutes=[NSMutableArray array], *names=[NSMutableArray array];
    for(NSInteger minute=1;minute<=300;minute++) { [minutes addObject:[NSNumber numberWithInteger:minute*60]]; [names addObject:RCIntervalText(minute)]; }
    values=minutes; labels=names;
  }
  NSString *help=mode ? RCSyncHelp(section==1) : (history ? RCCalendarHistoryHelp() : @"How often to check iCloud for changes.");
  RCChoiceTable *choices=[[RCChoiceTable alloc] initWithSettings:settings_ key:key title:mode ? (section==1 ? @"Contacts Sync" : @"Calendar Sync") : [[[table cellForRowAtIndexPath:path] textLabel] text] values:values labels:labels help:help];
  [[self navigationController] pushViewController:choices animated:YES]; [choices release];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder]; return YES; }
- (void)save {
  [[self view] endEditing:YES];
  if([[NSFileManager defaultManager] fileExistsAtPath:RCIOSConfigPath()]) {
    NSDictionary *latest=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    if(!latest) { RCIOSMessage(@"Cannot save",@"The configuration could not be read."); return; }
    [config_ release]; config_=[latest mutableCopy];
  }
  if(unreadable_ || !config_ || !settings_) { RCIOSMessage(@"Cannot save",@"The existing configuration could not be read. It has been left unchanged."); return; }
  NSString *username=[[username_ text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  BOOL enabled=![[settings_ objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"] || ![[settings_ objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"];
  if((enabled || [[password_ text] length]) && ![username length]) { RCIOSMessage(@"Account required",@"Enter your Apple ID."); return; }
  RCError error;
  if([[password_ text] length]) {
    NSData *secret=[[password_ text] dataUsingEncoding:NSUTF8StringEncoding];
    if(!RCICloudCredentialsSave([username UTF8String],[secret bytes],[secret length],NULL,&error)) { RCIOSMessage(@"Cannot save",@"The password could not be saved in Keychain."); return; }
    [password_ setText:@""];
  }
  if(enabled) { char *saved=NULL; BOOL found=RCICloudCredentialsCopyUsername([username UTF8String],&saved,&error); free(saved);
    if(!found) { RCIOSMessage(@"Password required",@"Enter an app-specific password for this account before enabling sync."); return; } }
  [settings_ setObject:username forKey:@"Username"]; [config_ setObject:settings_ forKey:@"Contacts"];
  [config_ setObject:[NSDate date] forKey:@"SettingsUpdatedAt"];
  if(!RCIOSSaveConfiguration(config_)) { RCIOSMessage(@"Cannot save",@"The configuration could not be saved. Any password already saved remains in Keychain."); return; }
  if(enabled) RCIOSRequestAccess(![[settings_ objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"],
      ![[settings_ objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"]);
  [self updateSavedPassword];
  RCIOSMessage(@"Saved",@"Your settings have been saved.");
  [[self navigationController] popViewControllerAnimated:YES];
}
- (void)resetAccount {
  NSDictionary *latest=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
  if(!latest) { RCIOSMessage(@"Cannot reset",@"Save an account before resetting it."); return; }
  id contacts=[latest objectForKey:@"Contacts"];
  if(![contacts isKindOfClass:[NSDictionary class]]) { RCIOSMessage(@"Cannot reset",@"The configuration could not be read."); return; }
  NSString *account=[contacts objectForKey:@"Username"];
  NSMutableDictionary *updated=[[latest mutableCopy] autorelease];
  NSMutableDictionary *sync=[[contacts mutableCopy] autorelease];
  [sync setObject:@"Disabled" forKey:@"ContactsSyncMode"]; [sync setObject:@"Disabled" forKey:@"CalendarsSyncMode"];
  [updated setObject:sync forKey:@"Contacts"]; [updated setObject:[NSDate date] forKey:@"SettingsUpdatedAt"];
  if(!RCIOSSaveConfiguration(updated)) { RCIOSMessage(@"Cannot reset",@"The configuration could not be saved."); return; }
  RCError error;
  BOOL removed=![account length] || RCICloudCredentialsRemove([account UTF8String],&error);
  if(!removed) RCIOSMessage(@"Password not removed",@"Sync is disabled, but the saved password could not be removed from Keychain. Try Reset again.");
  else {
    [sync setObject:@"" forKey:@"Username"];
    if(!RCIOSSaveConfiguration(updated)) {
      [sync setObject:account ?: @"" forKey:@"Username"];
      RCIOSMessage(@"Cannot save",@"The password was removed and sync disabled, but the account name could not be cleared. Try Reset again.");
    }
  }
  [config_ release]; config_=[updated mutableCopy]; [settings_ release]; settings_=[sync mutableCopy];
  [username_ setText:[sync objectForKey:@"Username"]]; [password_ setText:@""]; [self updateSavedPassword]; [[self tableView] reloadData];
}
- (void)dealloc { [config_ release]; [settings_ release]; [username_ release]; [password_ release]; [super dealloc]; }
@end
