#import "RCIOSConfiguration.h"
#import "RCSettingsPresentation.h"
#import "RCIOSSettings.h"
#import "RCIOSAccess.h"
#import "RCAccountTable.h"
#import "RCMailTable.h"
#import "RCLogViewController.h"
#import <AltivecCocoa/AIFontAwesome.h>
static NSString *StatusDate(id value, NSString *fallback) {
  if(![value isKindOfClass:[NSDate class]]) return fallback;
  NSDateFormatter *formatter=[[[NSDateFormatter alloc] init] autorelease];
  [formatter setDateStyle:NSDateFormatterShortStyle];
  [formatter setTimeStyle:NSDateFormatterShortStyle];
  return [formatter stringFromDate:value];
}

@implementation RCIOSSettings
- (NSArray *)collectionIdentifiersForSection:(NSInteger)section;
{ return [self collectionFixedIdentifiersForSection:section]; }
- (id)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad {
  [super viewDidLoad]; [self setTitle:@"Status"];
  [[self navigationItem] setRightBarButtonItem:[[[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)] autorelease]];
  [self refresh];
}
- (void)refresh {
  NSDictionary *latest=[NSDictionary dictionaryWithContentsOfFile:[RCIOSSettingsDirectory stringByAppendingPathComponent:@"Status.plist"]];
  [status_ release]; status_=[latest retain];
  [self refreshCollection];
}
- (void)serviceChanged:(UISwitch *)control {
  NSMutableDictionary *configuration=[NSMutableDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
  if(!configuration) { RCIOSMessage(@"Cannot update service",@"Save your account or Mail settings first."); [self refresh]; return; }
  if([control tag]==1) {
    NSMutableDictionary *mail=[[[configuration objectForKey:@"MailProxy"] mutableCopy] autorelease];
    if(![mail isKindOfClass:[NSMutableDictionary class]]) { RCIOSMessage(@"Cannot update service",@"Mail settings could not be read."); [self refresh]; return; }
    [mail setObject:[NSNumber numberWithBool:[control isOn]] forKey:@"Enabled"];
    [configuration setObject:mail forKey:@"MailProxy"];
  } else {
    [configuration setObject:[NSNumber numberWithBool:![control isOn]] forKey:[control tag]==0 ? @"ServicePaused" : @"SyncPaused"];
  }
  [configuration setObject:[NSDate date] forKey:@"SettingsUpdatedAt"];
  if(!RCIOSSaveConfiguration(configuration)) RCIOSMessage(@"Cannot update service",@"The configuration could not be saved.");
  else if([control tag]!=1 && [control isOn] && ![[configuration objectForKey:@"SyncPaused"] boolValue]) {
    NSDictionary *sync=[configuration objectForKey:@"Contacts"];
    RCIOSRequestAccess(![[sync objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"],
        ![[sync objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"]);
  }
  [self refresh];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [refreshTimer_ invalidate]; [refreshTimer_ release];
  refreshTimer_=[[NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES] retain];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [refreshTimer_ invalidate]; [refreshTimer_ release]; refreshTimer_=nil;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
  (void)table; return section==0 ? 3 : section==1 ? 2 : 6;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
  (void)table; return [@[@"Services",@"Daemon",@"Contacts",@"Calendars"] objectAtIndex:section];
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
  (void)table; return section==0 ? @"Disabling the daemon stops Mail and sync after saving active work. Mail and Sync keep their individual settings." : nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  (void)table;
  UITableViewCell *cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil] autorelease];
  if([path section]==0) {
    NSInteger kind=[path row];
    NSDictionary *configuration=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    BOOL daemonEnabled=configuration && ![[configuration objectForKey:@"ServicePaused"] boolValue];
    UISwitch *control=[[[UISwitch alloc] init] autorelease];
    [control setTag:kind];
    [control setOn:kind==0 ? daemonEnabled : kind==1 ? [[[configuration objectForKey:@"MailProxy"] objectForKey:@"Enabled"] boolValue] : configuration && ![[configuration objectForKey:@"SyncPaused"] boolValue]];
    [control setEnabled:configuration && (kind==0 || daemonEnabled)];
    [control addTarget:self action:@selector(serviceChanged:) forControlEvents:UIControlEventValueChanged];
    NSString *title=[@[@"Enable daemon",@"Enable Mail proxy",@"Enable Sync"] objectAtIndex:kind];
    [[cell textLabel] setText:title]; [control setAccessibilityLabel:title];
    [cell setAccessoryView:control]; [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
    return cell;
  }
  NSString *label, *value;
  if([path section]==1) {
    if([path row]==0) {
      label=@"Status";
      NSDictionary *configuration=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
      BOOL paused=[[configuration objectForKey:@"ServicePaused"] boolValue];
      value=RCStatusIsLive(status_) ? (paused ? @"Stopping — saving progress…" : @"Running") : @"Stopped";
    } else { label=@"Last report"; value=StatusDate([status_ objectForKey:@"UpdatedAt"],@"None"); }
  } else {
    id service=[status_ objectForKey:[path section]==2 ? @"Contacts" : @"Calendars"];
    if(![service isKindOfClass:[NSDictionary class]]) service=nil;
    BOOL live=RCStatusIsLive(status_);
    label=[@[@"Status",@"Progress",@"Last successful sync",@"Pending items",[service objectForKey:@"ErrorCode"] ? @"Next retry" : @"Next sync",@"Error"] objectAtIndex:[path row]];
    switch([path row]) {
      case 0: value=RCStatusText(service,live); break;
      case 1: value=live ? ([service objectForKey:@"Progress"] ?: @"—") : @"—"; break;
      case 2: value=StatusDate([service objectForKey:@"LastSuccess"],@"Not yet synced"); break;
      case 3: value=[[service objectForKey:@"PendingCount"] description] ?: @"Unknown"; break;
      case 4: value=live ? StatusDate([service objectForKey:@"NextAttempt"],@"Not scheduled") : @"Not scheduled"; break;
      default: value=RCStatusErrorText([service objectForKey:@"ErrorCode"]) ?: @"None"; break;
    }
  }
  [[cell textLabel] setText:label];
  [[cell detailTextLabel] setText:value];
  [[cell detailTextLabel] setNumberOfLines:3];
  [[cell detailTextLabel] setFont:[UIFont systemFontOfSize:12]];
  [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
  return cell;
}
- (void)dealloc { [refreshTimer_ invalidate]; [refreshTimer_ release]; [status_ release]; [super dealloc]; }
@end

UIViewController *RCIOSRootController(void) {
  [AIFontAwesome registerBundledFonts];
  NSArray *screens=@[[[[RCIOSSettings alloc] init] autorelease],
      [[[RCMailTable alloc] init] autorelease],
      [[[RCAccountTable alloc] init] autorelease],
      [[[RCLogViewController alloc] init] autorelease]];
  NSArray *titles=@[@"Status",@"Mail",@"Sync",@"Log"];
  AIFontAwesomeIcon icons[]={AIFAGauge,AIFAEnvelope,AIFAAddressBook,AIFAFileLines};
  CGFloat scale=[[UIScreen mainScreen] scale];
  NSMutableArray *panes=[NSMutableArray array];
  for(NSUInteger index=0;index<[screens count];index++) {
    UITableViewController *screen=[screens objectAtIndex:index];
    [screen setTitle:[titles objectAtIndex:index]];
    UINavigationController *navigation=[[[UINavigationController alloc] initWithRootViewController:screen] autorelease];
    UIImage *icon=[AIFontAwesome imageForIcon:icons[index] style:AIFontAwesomeStyleSolid
        iconSize:24.0 canvasSize:32.0 scale:scale];
    [navigation setTabBarItem:[[[UITabBarItem alloc] initWithTitle:[titles objectAtIndex:index] image:icon tag:index] autorelease]];
    [panes addObject:navigation];
  }
  UITabBarController *tabs=[[[UITabBarController alloc] init] autorelease];
  [tabs setViewControllers:panes];
  return tabs;
}
