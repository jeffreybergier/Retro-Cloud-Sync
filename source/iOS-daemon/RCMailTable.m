#import "RCIOSConfiguration.h"
#import "RCSettingsPresentation.h"
#import "RCMailTable.h"

@implementation RCMailTable
- (id)init { return [super initWithStyle:UITableViewStyleGrouped]; }
- (void)viewDidLoad {
  [super viewDidLoad]; [self setTitle:@"Mail"];
  BOOL exists=[[NSFileManager defaultManager] fileExistsAtPath:RCIOSConfigPath()];
  NSDictionary *loaded=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
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
  (void)table; return [@[@"Mail",@"Incoming Mail (IMAP)",@"Outgoing Mail (SMTP)"] objectAtIndex:section];
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
  (void)table;
  if(section==0) return nil;
  if(section==1) return @"Mail: 127.0.0.1, local port, SSL off.";
  return @"Mail: 127.0.0.1, local port, SSL off, Password authentication.";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
  (void)table;
  UITableViewCell *cell=[[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil] autorelease];
  [[cell textLabel] setText:[path section] ? [@[@"Local port",@"Server",@"Server port"] objectAtIndex:[path row]] : @"Enable Mail proxy"];
  [cell setAccessoryView:[path section] ? [fields_ objectAtIndex:([path section]-1)*3+[path row]] : enabled_];
  [cell setSelectionStyle:UITableViewCellSelectionStyleNone]; return cell;
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder]; return YES; }
- (void)save {
  [[self view] endEditing:YES];
  if([[NSFileManager defaultManager] fileExistsAtPath:RCIOSConfigPath()]) {
    NSDictionary *latest=[NSDictionary dictionaryWithContentsOfFile:RCIOSConfigPath()];
    if(!latest) { RCIOSMessage(@"Cannot save",@"The configuration could not be read."); return; }
    [config_ release]; config_=[latest mutableCopy];
  }
  if(unreadable_ || !config_) { RCIOSMessage(@"Cannot save",@"The existing configuration could not be read. It has been left unchanged."); return; }
  NSMutableDictionary *mail=[NSMutableDictionary dictionary];
  [mail setObject:[NSNumber numberWithBool:[enabled_ isOn]] forKey:@"Enabled"];
  NSInteger firstPort=0;
  for(NSUInteger service=0;service<2;service++) {
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for(NSUInteger row=0;row<3;row++) {
      NSString *value=[[[fields_ objectAtIndex:service*3+row] text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSString *key=[@[@"LocalPort",@"RemoteHost",@"RemotePort"] objectAtIndex:row];
      NSString *error=RCMailFieldError(value,row==1,row==0);
      if(error) { RCIOSMessage(@"Invalid Mail settings",error); return; }
      if(row==1) [values setObject:value forKey:key];
      else {
        NSInteger port=[value integerValue];
        if(row==0) {
          if(service==0) firstPort=port;
          else if(firstPort==port) { RCIOSMessage(@"Invalid ports",@"IMAP and SMTP need different local ports."); return; }
        }
        [values setObject:[NSNumber numberWithInteger:port] forKey:key];
      }
    }
    [mail setObject:values forKey:service ? @"SMTP" : @"IMAP"];
  }
  [config_ setObject:mail forKey:@"MailProxy"];
  [config_ setObject:[NSDate date] forKey:@"SettingsUpdatedAt"];
  if(!RCIOSSaveConfiguration(config_)) { RCIOSMessage(@"Cannot save",@"The configuration could not be saved."); return; }
  RCIOSMessage(@"Saved",@"Mail proxy settings have been saved.");
  [[self navigationController] popViewControllerAnimated:YES];
}
- (void)dealloc { [enabled_ release]; [fields_ release]; [config_ release]; [super dealloc]; }
@end
