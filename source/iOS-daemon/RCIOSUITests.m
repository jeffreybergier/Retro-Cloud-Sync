#import "RCIOSConfiguration.h"
#import "RCSettingsPresentation.h"
#import "RCIOSSettings.h"
#import "RCAccountTable.h"
#import "RCMailTable.h"
#import "RCLogViewController.h"
#import <AltivecCocoa/AIFontAwesome.h>
#import <QuartzCore/QuartzCore.h>
#include "RCICloudCredentials.h"
#include <sys/stat.h>
#include <unistd.h>
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
    UITabBarController *tabs=(UITabBarController *)[window rootViewController];
    NSCAssert([tabs isKindOfClass:[UITabBarController class]], @"Standard tab navigation");
    NSCAssert([[[tabs tabBar] items] count]==4, @"Four panes");
    NSArray *titles=@[@"Status",@"Mail",@"Sync",@"Log"];
    for(NSUInteger n=0;n<4;n++) NSCAssert([[[[[tabs tabBar] items] objectAtIndex:n] title] isEqual:[titles objectAtIndex:n]], @"Mac pane order and labels");
    [checks addObject:@"Mac pane order: Status, Mail, Sync, Log"];
    UINavigationController *navigation=(UINavigationController *)[tabs selectedViewController];
    RCIOSSettings *root=(RCIOSSettings *)[navigation topViewController];
    NSCAssert([root isKindOfClass:[UITableViewController class]], @"Root table");
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(CGRectGetWidth([window bounds]),CGRectGetHeight([window bounds])),YES,0);
    [[window layer] renderInContext:UIGraphicsGetCurrentContext()];
    NSData *png=UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()); UIGraphicsEndImageContext();
    [[NSFileManager defaultManager] createDirectoryAtPath:RCIOSSettingsDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    [png writeToFile:[RCIOSSettingsDirectory stringByAppendingPathComponent:@"status.png"] atomically:YES];
    NSString *statusPath=[RCIOSSettingsDirectory stringByAppendingPathComponent:@"Status.plist"];
    NSDictionary *photoStatus=@{@"Running":@YES,@"PID":@(getpid()),@"Contacts":@{@"Phase":@"Photos",@"Progress":@"1 / 2 contacts"}};
    [photoStatus writeToFile:statusPath atomically:YES];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
    NSIndexPath *progressPath=[NSIndexPath indexPathForRow:1 inSection:2];
    UITableViewCell *progressCell=[root tableView:[root tableView] cellForRowAtIndexPath:progressPath];
    NSCAssert([[[progressCell detailTextLabel] text] isEqual:@"1 / 2 contacts"], @"Visible status refreshes automatically");
    [@{@"Running":@YES,@"PID":@(getpid()),@"Contacts":@{@"Phase":@"Photos",@"Progress":@"2 / 2 contacts"}} writeToFile:statusPath atomically:YES];
    [root refresh];
    progressCell=[root tableView:[root tableView] cellForRowAtIndexPath:progressPath];
    NSCAssert([[[progressCell detailTextLabel] text] isEqual:@"2 / 2 contacts"], @"Manual status refresh");
    UITableViewCell *phaseCell=[root tableView:[root tableView] cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
    NSCAssert([[[phaseCell detailTextLabel] text] isEqual:@"Checking contact photos…"], @"Shared readable phase");
    [@{@"Running":@NO,@"Contacts":@{@"Phase":@"Photos",@"Progress":@"2 / 2 contacts"}} writeToFile:statusPath atomically:YES];
    [root refresh];
    phaseCell=[root tableView:[root tableView] cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
    NSCAssert([[[phaseCell detailTextLabel] text] isEqual:@"Paused — background service stopped"], @"Stopped daemon must not display stale activity");
    [[NSFileManager defaultManager] removeItemAtPath:statusPath error:NULL];
    [checks addObject:@"Automatic and manual status refresh show current photo progress"];
    RCAccountTable *form=[[RCAccountTable alloc] init]; [navigation pushViewController:form animated:NO]; [form view];
    NSMutableDictionary *settings=[form valueForKey:@"settings_"];
    NSCAssert([[settings objectForKey:@"ContactsSyncMode"] isEqual:@"Disabled"] && [[settings objectForKey:@"CalendarsSyncMode"] isEqual:@"Disabled"], @"Fresh setup must not enable syncing");
    [checks addObject:@"Fresh configuration defaults to disabled"];
    for(NSArray *position in @[@[@1,@0],@[@2,@0],@[@2,@1]]) {
      NSIndexPath *path=[NSIndexPath indexPathForRow:[[position objectAtIndex:1] integerValue] inSection:[[position objectAtIndex:0] integerValue]];
      [form tableView:[form tableView] didSelectRowAtIndexPath:path];
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
      UITableViewController *choice=(UITableViewController *)[navigation topViewController];
      NSCAssert([choice isKindOfClass:[UITableViewController class]], @"Every options screen is a table");
      [choice tableView:[choice tableView] didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
    NSCAssert(![[form navigationItem] rightBarButtonItem] && ![[form navigationItem] leftBarButtonItem], @"Account actions belong inside the form");
    NSDictionary *automatic=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    NSCAssert([[[automatic objectForKey:@"Contacts"] objectForKey:@"ContactsSyncMode"] isEqual:@"OneWay"], @"Mode saved without Save Account");
    NSCAssert([[[automatic objectForKey:@"Contacts"] objectForKey:@"Username"] isEqual:@""], @"Options must not save an account draft");
    UISlider *interval=[form valueForKey:@"intervalSlider_"];
    [interval setValue:17.6]; [interval sendActionsForControlEvents:UIControlEventValueChanged];
    NSCAssert([interval value]==18, @"Interval snaps to whole minutes");
    NSCAssert([[[[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()] objectForKey:@"Contacts"] objectForKey:@"SyncIntervalSeconds"] intValue]==1080, @"Interval saves automatically");
    [checks addObject:@"Sync choices save immediately and interval snaps to minutes"];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(CGRectGetWidth([window bounds]),CGRectGetHeight([window bounds])),YES,0);
    [[window layer] renderInContext:UIGraphicsGetCurrentContext()];
    NSData *formPNG=UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()); UIGraphicsEndImageContext();
    [formPNG writeToFile:[RCIOSSettingsDirectory stringByAppendingPathComponent:@"account.png"] atomically:YES];
    UITextField *username=[form valueForKey:@"username_"]; UITextField *password=[form valueForKey:@"password_"];
    NSCAssert([password isSecureTextEntry], @"Password must be secure");
    [username setText:account]; [password setText:@"synthetic-ui-password"];
    [form save];
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    NSCAssert([[[saved objectForKey:@"Contacts"] objectForKey:@"Username"] isEqual:account], @"Account persisted");
    NSCAssert([[saved description] rangeOfString:@"synthetic-ui-password"].location==NSNotFound, @"No password in configuration");
    struct stat info; NSCAssert(stat([RCIOSConfigPath() fileSystemRepresentation],&info)==0 && (info.st_mode&0777)==0600, @"Private configuration");
    char *secret=NULL; size_t length=0;
    NSCAssert(RCICloudCredentialsCopyPassword([account UTF8String],&secret,&length,&error), @"UI Keychain save");
    BOOL matches=length==strlen("synthetic-ui-password") && !memcmp(secret,"synthetic-ui-password",length);
    RCICloudCredentialsClearPassword(secret,length); NSCAssert(matches, @"Saved secret");
    NSCAssert(![[password text] length], @"Password field cleared");
    NSCAssert([[password placeholder] isEqual:@"Saved in Keychain"], @"Saved password status is visible without reading it");
    RCAccountTable *reopened=[[RCAccountTable alloc] init]; [reopened view];
    NSCAssert([[(UITextField *)[reopened valueForKey:@"username_"] text] isEqual:account], @"Reopened saved account");
    NSCAssert([[(UITextField *)[reopened valueForKey:@"password_"] placeholder] isEqual:@"Saved in Keychain"], @"Reopened saved password status");
    [reopened release];
    [checks addObject:@"Save action: private config, Keychain password, secure field cleared"];
    [form release];
    RCMailTable *mail=[[RCMailTable alloc] init]; [mail view];
    UITableViewCell *mailControl=[root tableView:[root tableView] cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
    UISwitch *mailSwitch=(UISwitch *)[mailControl accessoryView];
    [mailSwitch setOn:YES]; [mailSwitch sendActionsForControlEvents:UIControlEventValueChanged];
    [mail save];
    NSDictionary *mailConfig=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    NSCAssert([[[mailConfig objectForKey:@"MailProxy"] objectForKey:@"Enabled"] boolValue], @"Mail enabled setting saved");
    NSCAssert([[mailConfig objectForKey:@"Contacts"] isEqual:[saved objectForKey:@"Contacts"]], @"Mail settings preserve sync account");
    [checks addObject:@"Mail settings save independently and preserve sync configuration"];
    UITableViewCell *syncControl=[root tableView:[root tableView] cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
    UISwitch *syncSwitch=(UISwitch *)[syncControl accessoryView];
    [syncSwitch setOn:NO]; [syncSwitch sendActionsForControlEvents:UIControlEventValueChanged];
    NSDictionary *paused=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    NSCAssert([[paused objectForKey:@"SyncPaused"] boolValue], @"Sync master switch persists");
    NSCAssert([[paused objectForKey:@"Contacts"] isEqual:[mailConfig objectForKey:@"Contacts"]], @"Sync master preserves individual modes");
    NSCAssert([[paused objectForKey:@"MailProxy"] isEqual:[mailConfig objectForKey:@"MailProxy"]], @"Sync master preserves Mail");
    [syncSwitch setOn:YES]; [syncSwitch sendActionsForControlEvents:UIControlEventValueChanged];
    mailConfig=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    UITextField *port=[[mail valueForKey:@"fields_"] objectAtIndex:0];
    [port setText:@"0"]; [mail save];
    NSCAssert([[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()] isEqual:mailConfig], @"Invalid Mail draft must not be written");
    [mail release];
    RCAccountTable *reset=[[RCAccountTable alloc] init]; [reset view]; [reset resetAccount];
    NSDictionary *resetConfig=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    NSCAssert([[resetConfig objectForKey:@"Contacts"] isEqual:[mailConfig objectForKey:@"Contacts"]], @"Removing a password preserves the account and sync options");
    NSCAssert([[resetConfig objectForKey:@"MailProxy"] isEqual:[mailConfig objectForKey:@"MailProxy"]], @"Reset preserves Mail");
    char *removed=NULL;
    NSCAssert(!RCICloudCredentialsCopyUsername([account UTF8String],&removed,&error), @"Reset removes the credential"); free(removed); [reset release];
    RCLogViewController *logs=(RCLogViewController *)[[(UINavigationController *)[[tabs viewControllers] objectAtIndex:3] topViewController] retain];
    UITextView *logText=(UITextView *)[logs view];
    NSCAssert([logText isKindOfClass:[UITextView class]] && ![logText isEditable],@"Log is one read-only scrolling text view");
    NSCAssert([[logText text] length]>0 && ![[logs valueForKey:@"loader_"] isLoading],@"Initial log text is ready before appearance");
    NSString *initial=[[logText text] copy];
    [logs viewWillAppear:NO];
    NSCAssert(![[logs valueForKey:@"loader_"] isLoading] && [[logText text] isEqual:initial],@"Appearance does not reload log text");
    [logs viewWillDisappear:NO]; [initial release];
    [tabs setSelectedIndex:3];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    NSMutableString *sample=[NSMutableString string];
    for(NSUInteger line=0;line<100;++line) [sample appendFormat:@"[%lu] Sync complete — saved local changes.\n",(unsigned long)line];
    [logs performSelector:@selector(logLoaded:) withObject:@{@"text":sample}];
    [logText layoutIfNeeded];
    [logText setContentOffset:CGPointMake(0,120) animated:NO];
    [sample appendString:@"[100] Waiting for next update.\n"];
    [logs performSelector:@selector(logLoaded:) withObject:@{@"text":sample}];
    NSCAssert(fabs([logText contentOffset].y-120)<2,@"Live log updates preserve a reader's scroll position");
    UIGraphicsBeginImageContextWithOptions([window bounds].size,YES,0);
    [[window layer] renderInContext:UIGraphicsGetCurrentContext()];
    NSData *logPNG=UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()); UIGraphicsEndImageContext();
    [logPNG writeToFile:[RCIOSSettingsDirectory stringByAppendingPathComponent:@"log.png"] atomically:YES];
    [tabs setSelectedIndex:0];

    [logs release];
    RCLogViewController *discarded=[[RCLogViewController alloc] init];
    [discarded view]; [discarded refresh]; [discarded release]; /* Cancel pending delivery. */
    [checks addObject:@"Bounded scrolling log text, synchronous initial content and explicit refresh"];

  } @catch(NSException *exception) { failure=[exception reason]; }
  RCICloudCredentialsRemove([account UTF8String],&error);
  [[NSFileManager defaultManager] removeItemAtPath:RCIOSConfigPath() error:NULL];
  [@{@"Checks":checks,@"Result":failure ?: @"PASS",@"RunID":[[NSBundle mainBundle] objectForInfoDictionaryKey:@"RCTestRunID"] ?: @""} writeToFile:[RCIOSSettingsDirectory stringByAppendingPathComponent:@"result.plist"] atomically:YES];
}
#endif
