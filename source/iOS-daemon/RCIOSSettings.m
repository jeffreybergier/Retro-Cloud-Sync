#import "RCIOSSettings.h"
#import "RCIOSAccess.h"
#include "RCICloudCredentials.h"
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#ifdef RCIOS_UI_TESTS
#import <QuartzCore/QuartzCore.h>
#endif

#ifdef RCIOS_UI_TESTS
static NSString *const Directory=@"/var/mobile/Library/Caches/RetroCloudUITests";
#else
static NSString *const Directory=@"/var/mobile/Library/Application Support/rCloud";
#endif
static NSString *ConfigPath(void) { return [Directory stringByAppendingPathComponent:@"Config.plist"]; }
static void Message(NSString *title,NSString *message) {
  UIAlertView *alert=[[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
  [alert show]; [alert release];
}
/* The temporary file is private before writing, including on first setup. */
static BOOL Save(NSDictionary *config) {
  if(![[NSFileManager defaultManager] createDirectoryAtPath:Directory withIntermediateDirectories:YES
      attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions] error:NULL]) return NO;
  NSData *data=[NSPropertyListSerialization dataFromPropertyList:config format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];
  if(!data) return NO;
  char *name=strdup([[ConfigPath() stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
  if(!name) return NO;
  int fd=mkstemp(name); BOOL ok=fd>=0; NSUInteger left=[data length]; const char *bytes=[data bytes];
  while(ok && left) { ssize_t n=write(fd,bytes,left); if(n<0 && errno==EINTR) continue;
    if(n<=0) { ok=NO; break; } bytes+=n; left-=n; }
  if(fd>=0) { if(fsync(fd)) ok=NO; if(close(fd)) ok=NO; }
  if(ok) ok=rename(name,[ConfigPath() fileSystemRepresentation])==0;
  if(!ok) unlink(name); free(name); return ok;
}

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

@interface RCAccountTable : UITableViewController <UITextFieldDelegate> {
  NSMutableDictionary *config_; NSMutableDictionary *settings_; UITextField *username_; UITextField *password_; BOOL unreadable_;
}
@end
@implementation RCAccountTable
- (id)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad {
  [super viewDidLoad]; [self setTitle:@"Account & Sync"];
  NSDictionary *loaded=[NSDictionary dictionaryWithContentsOfFile:ConfigPath()];
  unreadable_=!loaded && [[NSFileManager defaultManager] fileExistsAtPath:ConfigPath()];
  if(!loaded) loaded=[NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Config.example" ofType:@"plist"]];
  if(![[loaded objectForKey:@"Contacts"] isKindOfClass:[NSDictionary class]]) { unreadable_=YES; loaded=nil; }
  config_=[loaded mutableCopy]; settings_=[[config_ objectForKey:@"Contacts"] mutableCopy];
  for(NSString *key in @[@"Username",@"ContactsSyncMode",@"CalendarsSyncMode"])
    if(![[settings_ objectForKey:key] isKindOfClass:[NSString class]]) unreadable_=YES;
  if(unreadable_) { [settings_ release]; settings_=[[NSMutableDictionary alloc] init]; }

  if(![[NSFileManager defaultManager] fileExistsAtPath:ConfigPath()]) {
    [settings_ setObject:@"" forKey:@"Username"];
    [settings_ setObject:@"Disabled" forKey:@"ContactsSyncMode"]; [settings_ setObject:@"Disabled" forKey:@"CalendarsSyncMode"];
  }
  username_=[[UITextField alloc] initWithFrame:CGRectMake(0,0,200,32)];
  password_=[[UITextField alloc] initWithFrame:CGRectMake(0,0,200,32)];
  for(UITextField *field in [NSArray arrayWithObjects:username_,password_,nil]) {
    [field setAutocapitalizationType:UITextAutocapitalizationTypeNone]; [field setAutocorrectionType:UITextAutocorrectionTypeNo];
    [field setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter]; [field setDelegate:self]; [field setReturnKeyType:UIReturnKeyDone];
  }
  [username_ setKeyboardType:UIKeyboardTypeEmailAddress]; [username_ setPlaceholder:@"Apple Account"]; [username_ setText:[settings_ objectForKey:@"Username"]];
  [password_ setSecureTextEntry:YES]; [password_ setPlaceholder:@"App-specific password"];
  [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)] autorelease]];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [[self tableView] reloadData]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [[self view] endEditing:YES]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; (void)section; return 2; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { (void)table; return [@[@"iCloud",@"Sync",@"Schedule"] objectAtIndex:section]; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
  (void)table;
  if(section==0) return @"Use an app-specific password. Leave the password blank to keep the saved password for this account. Passwords are stored in Keychain.";
  if(section==1) return @"Download only copies iCloud data to this device. Two-way also uploads supported local changes. Choose Disabled for both services to stop syncing. Save to apply your changes.";
  return @"All future events are included. Save to apply your changes. Sync continues when this app is closed.";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  (void)table; UITableViewCell *cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil] autorelease];
  NSInteger row=[path row],section=[path section];
  if(section==0) { [[cell textLabel] setText:row ? @"Password" : @"Account"]; [cell setAccessoryView:row ? password_ : username_]; [cell setSelectionStyle:UITableViewCellSelectionStyleNone]; }
  else {
    NSString *key=section==1 ? (row ? @"CalendarsSyncMode" : @"ContactsSyncMode") : (row ? @"CalendarHistoryYears" : @"SyncIntervalSeconds");
    [[cell textLabel] setText:section==1 ? (row ? @"Calendars" : @"Contacts") : (row ? @"Calendar history" : @"Interval")];
    id value=[settings_ objectForKey:key]; NSString *label;
    if(section==1) label=[value isEqual:@"TwoWay"] ? @"Two-way" : ([value isEqual:@"OneWay"] ? @"Download only" : @"Disabled");
    else if(row) label=[value intValue] ? [NSString stringWithFormat:@"Last %@ year(s)",value] : @"All history";
    else label=[NSString stringWithFormat:@"%ld minutes",(long)[value integerValue]/60];
    [[cell detailTextLabel] setText:label]; [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
  } return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
  [table deselectRowAtIndexPath:path animated:YES]; if([path section]==0) return;
  [[self view] endEditing:YES]; NSInteger row=[path row],section=[path section];
  NSString *key=section==1 ? (row ? @"CalendarsSyncMode" : @"ContactsSyncMode") : (row ? @"CalendarHistoryYears" : @"SyncIntervalSeconds");
  NSArray *values=section==1 ? @[@"Disabled",@"OneWay",@"TwoWay"] : (row ? @[@0,@1,@2] : @[@300,@900,@1800,@3600]);
  NSArray *labels=section==1 ? @[@"Disabled",@"Download only",@"Two-way"] : (row ? @[@"All history",@"Last 1 year",@"Last 2 years"] : @[@"5 minutes",@"15 minutes",@"30 minutes",@"1 hour"]);
  NSString *help=section==1 ? @"Two-way sync can change iCloud data. Unsupported changes remain pending for review." : (row ? @"Older imported events may leave the device. They remain in iCloud. Ongoing recurring series are kept." : @"How often to check iCloud for changes.");
  RCChoiceTable *choices=[[RCChoiceTable alloc] initWithSettings:settings_ key:key title:[[[table cellForRowAtIndexPath:path] textLabel] text] values:values labels:labels help:help];
  [[self navigationController] pushViewController:choices animated:YES]; [choices release];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder]; return YES; }
- (void)save {
  [[self view] endEditing:YES];
  if(unreadable_ || !config_ || !settings_) { Message(@"Cannot save",@"The existing configuration could not be read. It has been left unchanged."); return; }
  NSString *username=[[username_ text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  BOOL enabled=![[settings_ objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"] || ![[settings_ objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"];
  if((enabled || [[password_ text] length]) && ![username length]) { Message(@"Account required",@"Enter your Apple Account email address."); return; }
  RCError error;
  if([[password_ text] length]) {
    NSData *secret=[[password_ text] dataUsingEncoding:NSUTF8StringEncoding];
    if(!RCICloudCredentialsSave([username UTF8String],[secret bytes],[secret length],NULL,&error)) { Message(@"Cannot save",@"The password could not be saved in Keychain."); return; }
    [password_ setText:@""];
  }
  if(enabled) { char *saved=NULL; BOOL found=RCICloudCredentialsCopyUsername([username UTF8String],&saved,&error); free(saved);
    if(!found) { Message(@"Password required",@"Enter an app-specific password for this account before enabling sync."); return; } }
  [settings_ setObject:username forKey:@"Username"]; [config_ setObject:settings_ forKey:@"Contacts"];
  [config_ setObject:[NSDate date] forKey:@"SettingsUpdatedAt"];
  if(!Save(config_)) { Message(@"Cannot save",@"The configuration could not be saved. Any password already saved remains in Keychain."); return; }
  if(enabled) RCIOSRequestAccess(![[settings_ objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"],
      ![[settings_ objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"]);
  Message(@"Saved",@"Your settings have been saved.");
  [[self navigationController] popViewControllerAnimated:YES];
}
- (void)dealloc { [config_ release]; [settings_ release]; [username_ release]; [password_ release]; [super dealloc]; }
@end

@interface RCMailTable : UITableViewController <UITextFieldDelegate> {
  UISwitch *enabled_; NSArray *fields_; NSMutableDictionary *config_; BOOL unreadable_;
}
@end
@implementation RCMailTable
- (id)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad {
  [super viewDidLoad]; [self setTitle:@"Mail Proxy"];
  BOOL exists=[[NSFileManager defaultManager] fileExistsAtPath:ConfigPath()];
  NSDictionary *loaded=[NSDictionary dictionaryWithContentsOfFile:ConfigPath()];
  unreadable_=exists && !loaded;
  if(!exists) {
    loaded=[NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Config.example" ofType:@"plist"]];
  }
  config_=[loaded mutableCopy];
  if(!exists) {
    NSMutableDictionary *contacts=[[[config_ objectForKey:@"Contacts"] mutableCopy] autorelease];
    [contacts setObject:@"" forKey:@"Username"];
    [contacts setObject:@"Disabled" forKey:@"ContactsSyncMode"];
    [contacts setObject:@"Disabled" forKey:@"CalendarsSyncMode"];
    if(contacts) [config_ setObject:contacts forKey:@"Contacts"];
  }
  id mail=[config_ objectForKey:@"MailProxy"];
  if(![mail isKindOfClass:[NSDictionary class]]) { unreadable_=YES; mail=nil; }
  enabled_=[[UISwitch alloc] init]; [enabled_ setOn:[[mail objectForKey:@"Enabled"] boolValue]];
  NSMutableArray *fields=[NSMutableArray array];
  for(NSString *service in @[@"IMAP",@"SMTP"]) {
    id values=[mail objectForKey:service];
    if(![values isKindOfClass:[NSDictionary class]]) { unreadable_=YES; values=nil; }
    for(NSString *key in @[@"LocalPort",@"RemoteHost",@"RemotePort"]) {
      UITextField *field=[[[UITextField alloc] initWithFrame:CGRectMake(0,0,180,32)] autorelease];
      [field setText:[[values objectForKey:key] description]];
      [field setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter];
      [field setAutocorrectionType:UITextAutocorrectionTypeNo];
      [field setAutocapitalizationType:UITextAutocapitalizationTypeNone];
      [field setKeyboardType:[key isEqual:@"RemoteHost"] ? UIKeyboardTypeURL : UIKeyboardTypeNumberPad];
      [field setReturnKeyType:UIReturnKeyDone]; [field setDelegate:self];
      [fields addObject:field];
    }
  }
  fields_=[fields copy];
  [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)] autorelease]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; return section ? 3 : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
  (void)table; return [@[@"Proxy",@"Incoming (IMAP)",@"Outgoing (SMTP)"] objectAtIndex:section];
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
  (void)table;
  if(section==0) return @"Mail works independently of Contacts and Calendars. Save to apply changes.";
  if(section==1) return @"In Mail account settings, use 127.0.0.1 and the local IMAP port (1143 by default), with SSL off. Enter your iCloud mail username and app-specific password in Mail.";
  return @"For outgoing mail, use 127.0.0.1 and the local SMTP port (1587 by default), SSL off, and Password authentication. The proxy verifies TLS to the upstream servers. Use IMAP TLS port 993 and SMTP STARTTLS port 587 upstream. Local ports must be different and between 1024 and 65535.";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  (void)table;
  UITableViewCell *cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil] autorelease];
  [[cell textLabel] setText:[path section] ? [@[@"Local port",@"Server",@"Server port"] objectAtIndex:[path row]] : @"Enabled"];
  [cell setAccessoryView:[path section] ? [fields_ objectAtIndex:([path section]-1)*3+[path row]] : enabled_];
  [cell setSelectionStyle:UITableViewCellSelectionStyleNone]; return cell;
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder]; return YES; }
- (void)save {
  [[self view] endEditing:YES];
  if(unreadable_ || !config_) { Message(@"Cannot save",@"The existing configuration could not be read. It has been left unchanged."); return; }
  NSMutableDictionary *mail=[NSMutableDictionary dictionary];
  [mail setObject:[NSNumber numberWithBool:[enabled_ isOn]] forKey:@"Enabled"];
  NSInteger firstPort=0;
  for(NSUInteger service=0;service<2;service++) {
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for(NSUInteger row=0;row<3;row++) {
      NSString *value=[[[fields_ objectAtIndex:service*3+row] text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSString *key=[@[@"LocalPort",@"RemoteHost",@"RemotePort"] objectAtIndex:row];
      if(row==1) {
        NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
        if(![value length] || [value rangeOfCharacterFromSet:[allowed invertedSet]].location!=NSNotFound) {
          Message(@"Invalid server",@"Enter a server hostname without a scheme, port, or path."); return;
        }
        [values setObject:value forKey:key];
      } else {
        NSInteger port=[value integerValue];
        if(![value length] || [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound || port<(row==0 ? 1024 : 1) || port>65535) {
          Message(@"Invalid port",@"Local ports must be 1024–65535. Server ports must be 1–65535."); return;
        }
        if(row==0) {
          if(service==0) firstPort=port;
          else if(firstPort==port) { Message(@"Invalid ports",@"IMAP and SMTP need different local ports."); return; }
        }
        [values setObject:[NSNumber numberWithInteger:port] forKey:key];
      }
    }
    [mail setObject:values forKey:service ? @"SMTP" : @"IMAP"];
  }
  [config_ setObject:mail forKey:@"MailProxy"];
  [config_ setObject:[NSDate date] forKey:@"SettingsUpdatedAt"];
  if(!Save(config_)) { Message(@"Cannot save",@"The configuration could not be saved."); return; }
  Message(@"Saved",@"Mail proxy settings have been saved.");
  [[self navigationController] popViewControllerAnimated:YES];
}
- (void)dealloc { [enabled_ release]; [fields_ release]; [config_ release]; [super dealloc]; }
@end

@interface RCLogTable : UITableViewController { NSArray *lines_; }
@end
@implementation RCLogTable
- (void)viewDidLoad { [super viewDidLoad]; [self setTitle:@"Log"]; [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)] autorelease]]; [self refresh]; }
- (void)refresh {
  NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:@"/var/mobile/Library/Logs/RetroCloudSync/RetroCloudSyncDaemon.log"];
  NSString *tail=nil;
  @try { unsigned long long size=[file seekToEndOfFile]; [file seekToFileOffset:size>65536 ? size-65536 : 0];
    NSData *data=[file readDataOfLength:65536]; tail=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if(!tail && data) tail=[[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    if(size>65536) { NSRange newline=[tail rangeOfString:@"\n"]; if(newline.location!=NSNotFound) tail=[tail substringFromIndex:newline.location+1]; }
  } @catch(NSException *exception) { (void)exception; tail=@"Log unavailable."; } @finally { [file closeFile]; }
  [lines_ release]; lines_=[[(tail ? tail : @"No log yet.") componentsSeparatedByString:@"\n"] copy]; [[self tableView] reloadData];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; (void)section; return [lines_ count]; }
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
  /* Measure with UIKit's default label font, also available on iOS 5. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CGSize size=[[lines_ objectAtIndex:[path row]] sizeWithFont:[UIFont systemFontOfSize:[UIFont labelFontSize]]
      constrainedToSize:CGSizeMake(MAX(1,CGRectGetWidth([table bounds])-30),CGFLOAT_MAX) lineBreakMode:NSLineBreakByWordWrapping];
#pragma clang diagnostic pop
  return MAX(44,size.height+24);
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"log"];
  if(!cell) cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"log"] autorelease];
  [[cell textLabel] setNumberOfLines:0]; [[cell textLabel] setText:[lines_ objectAtIndex:[path row]]]; [cell setSelectionStyle:UITableViewCellSelectionStyleNone]; return cell;
}
- (void)dealloc { [lines_ release]; [super dealloc]; }
@end

static NSString *StatusDate(id value, NSString *fallback) {
  if(![value isKindOfClass:[NSDate class]]) return fallback;
  NSDateFormatter *formatter=[[[NSDateFormatter alloc] init] autorelease];
  [formatter setDateStyle:NSDateFormatterShortStyle];
  [formatter setTimeStyle:NSDateFormatterShortStyle];
  return [formatter stringFromDate:value];
}

@implementation RCIOSSettings
- (id)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; [self setTitle:@"rCloud"]; [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)] autorelease]]; }
- (void)refresh {
  [status_ release];
  status_=[[NSDictionary dictionaryWithContentsOfFile:[Directory stringByAppendingPathComponent:@"Status.plist"]] retain];
  [[self tableView] reloadData];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
  (void)table; return section==0 ? 3 : (section==3 ? 1 : 5);
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
  (void)table; return [@[@"Settings",@"Contacts",@"Calendars",@"Daemon"] objectAtIndex:section];
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
  (void)table; return section==3 ? @"Status shows the daemon’s last saved report. Tap Refresh to update. Sync runs in the background." : nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  (void)table;
  UITableViewCell *cell=[[[UITableViewCell alloc] initWithStyle:[path section] ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault reuseIdentifier:nil] autorelease];
  if(![path section]) {
    [[cell textLabel] setText:[@[@"Account & Sync",@"Mail Proxy",@"Log"] objectAtIndex:[path row]]];
    [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
  } else {
    NSString *label, *value;
    if([path section]==3) {
      label=@"Last report";
      value=StatusDate([status_ objectForKey:@"UpdatedAt"],@"None");
    } else {
      id service=[status_ objectForKey:[path section]==1 ? @"Contacts" : @"Calendars"];
      if(![service isKindOfClass:[NSDictionary class]]) service=nil;
      label=[@[@"Status",@"Last success",@"Pending changes",@"Next attempt",@"Error"] objectAtIndex:[path row]];
      switch([path row]) {
        case 0: value=[service objectForKey:@"Phase"] ?: @"Not started"; break;
        case 1: value=StatusDate([service objectForKey:@"LastSuccess"],@"Never"); break;
        case 2: value=[[service objectForKey:@"PendingCount"] description] ?: @"Unknown"; break;
        case 3: value=StatusDate([service objectForKey:@"NextAttempt"],@"Not scheduled"); break;
        default: value=[[service objectForKey:@"ErrorCode"] description] ?: @"None"; break;
      }
    }
    [[cell textLabel] setText:label];
    [[cell detailTextLabel] setText:value];
    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
  }
  return cell;
}
- (void)dealloc { [status_ release]; [super dealloc]; }
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
  [table deselectRowAtIndexPath:path animated:YES]; if([path section]) return;
  UITableViewController *screen=[path row]==0 ? [[RCAccountTable alloc] init] : ([path row]==1 ? [[RCMailTable alloc] init] : [[RCLogTable alloc] initWithStyle:UITableViewStylePlain]);
  [[self navigationController] pushViewController:screen animated:YES]; [screen release];
}
@end

#ifdef RCIOS_UI_TESTS
/* Device smoke test: a separate build uses only a private cache configuration. */
void RCIOSRunUITests(UIWindow *window) {
  NSMutableArray *checks=[NSMutableArray array];
  NSString *failure=nil;
  NSString *account=@"retrocloud-ui-test.invalid";
  RCError error;
  @try {
    NSCAssert(CGRectGetHeight([window bounds])==568, @"iPhone 5 must have a full 568-point window");
    [checks addObject:@"iPhone 5 full-height window"];
    UINavigationController *navigation=(UINavigationController *)[window rootViewController];
    RCIOSSettings *root=(RCIOSSettings *)[navigation topViewController];
    NSCAssert([root isKindOfClass:[UITableViewController class]], @"Root table");
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(CGRectGetWidth([window bounds]),CGRectGetHeight([window bounds])),YES,0);
    [[window layer] renderInContext:UIGraphicsGetCurrentContext()];
    NSData *png=UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()); UIGraphicsEndImageContext();
    [[NSFileManager defaultManager] createDirectoryAtPath:Directory withIntermediateDirectories:YES attributes:nil error:NULL];
    [png writeToFile:[Directory stringByAppendingPathComponent:@"status.png"] atomically:YES];
    RCAccountTable *form=[[RCAccountTable alloc] init]; [navigation pushViewController:form animated:NO]; [form view];
    NSMutableDictionary *settings=[form valueForKey:@"settings_"];
    NSCAssert([[settings objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"] && [[settings objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"], @"Fresh setup must not enable syncing");
    [checks addObject:@"Fresh configuration defaults to disabled"];
    for(NSInteger section=1;section<=2;section++) for(NSInteger row=0;row<2;row++) {
      NSIndexPath *path=[NSIndexPath indexPathForRow:row inSection:section];
      [form tableView:[form tableView] didSelectRowAtIndexPath:path];
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
      RCChoiceTable *choice=(RCChoiceTable *)[navigation topViewController];
      NSCAssert([choice isKindOfClass:[RCChoiceTable class]], @"Every options screen is a table");
      [choice tableView:[choice tableView] didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
    [checks addObject:@"Contacts, Calendars, interval and history choices"];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(CGRectGetWidth([window bounds]),CGRectGetHeight([window bounds])),YES,0);
    [[window layer] renderInContext:UIGraphicsGetCurrentContext()];
    NSData *formPNG=UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()); UIGraphicsEndImageContext();
    [formPNG writeToFile:[Directory stringByAppendingPathComponent:@"account.png"] atomically:YES];
    [settings setObject:@"Disabled" forKey:@"ContactsSyncMode"]; [settings setObject:@"Disabled" forKey:@"CalendarsSyncMode"];
    UITextField *username=[form valueForKey:@"username_"]; UITextField *password=[form valueForKey:@"password_"];
    NSCAssert([password isSecureTextEntry], @"Password must be secure");
    [username setText:account]; [password setText:@"synthetic-ui-password"];
    [form save];
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:ConfigPath()];
    NSCAssert([[[saved objectForKey:@"Contacts"] objectForKey:@"Username"] isEqual:account], @"Account persisted");
    NSCAssert([[saved description] rangeOfString:@"synthetic-ui-password"].location==NSNotFound, @"No password in configuration");
    struct stat info; NSCAssert(stat([ConfigPath() fileSystemRepresentation],&info)==0 && (info.st_mode&0777)==0600, @"Private configuration");
    char *secret=NULL; size_t length=0;
    NSCAssert(RCICloudCredentialsCopyPassword([account UTF8String],&secret,&length,&error), @"UI Keychain save");
    BOOL matches=length==strlen("synthetic-ui-password") && !memcmp(secret,"synthetic-ui-password",length);
    RCICloudCredentialsClearPassword(secret,length); NSCAssert(matches, @"Saved secret");
    NSCAssert(![[password text] length], @"Password field cleared");
    [checks addObject:@"Save action: private config, Keychain password, secure field cleared"];
    [form release];
    RCMailTable *mail=[[RCMailTable alloc] init]; [mail view];
    [(UISwitch *)[mail valueForKey:@"enabled_"] setOn:YES];
    [mail save];
    NSDictionary *mailConfig=[NSDictionary dictionaryWithContentsOfFile:ConfigPath()];
    NSCAssert([[[mailConfig objectForKey:@"MailProxy"] objectForKey:@"Enabled"] boolValue], @"Mail enabled setting saved");
    NSCAssert([[mailConfig objectForKey:@"Contacts"] isEqual:[saved objectForKey:@"Contacts"]], @"Mail settings preserve sync account");
    [checks addObject:@"Mail settings save independently and preserve sync configuration"];
    [mail release];
    RCLogTable *logs=[[RCLogTable alloc] initWithStyle:UITableViewStylePlain]; [logs view]; [logs refresh];
    NSCAssert([logs tableView:[logs tableView] numberOfRowsInSection:0]>0,@"Log loaded"); [logs release];
    [checks addObject:@"Bounded log screen"];
  } @catch(NSException *exception) { failure=[exception reason]; }
  RCICloudCredentialsRemove([account UTF8String],&error);
  [[NSFileManager defaultManager] removeItemAtPath:ConfigPath() error:NULL];
  [@{@"Checks":checks,@"Result":failure ?: @"PASS"} writeToFile:[Directory stringByAppendingPathComponent:@"result.plist"] atomically:YES];
}
#endif
