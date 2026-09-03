//
//  MailServerView.m
//  RetroCloudSync
//

#import "MailServerView.h"

#import "RCConfiguration.h"

@interface MailServerView (Private)
- (NSTextField *)newEditableFieldWithFrame:(NSRect)frame;
- (void)addLabel:(NSString *)text frame:(NSRect)frame;
- (void)addServiceBox:(NSString *)title
                    y:(float)y
       localPortField:(NSTextField **)localPortField
          serverField:(NSTextField **)serverField
      serverPortField:(NSTextField **)serverPortField;
- (void)saveSettings:(id)sender;
- (void)showError:(NSString *)message;
@end

@implementation MailServerView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    NSButton *saveButton;

    [self addServiceBox:@"Incoming Mail (IMAP)" y:206
         localPortField:&imapLocalPortField_
            serverField:&imapServerField_
        serverPortField:&imapServerPortField_];
    [self addServiceBox:@"Outgoing Mail (SMTP)" y:100
         localPortField:&smtpLocalPortField_
            serverField:&smtpServerField_
        serverPortField:&smtpServerPortField_];
    saveButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(380, 12, 88, 26)] autorelease];
    [saveButton setTitle:@"Save"];
    [saveButton setBezelStyle:NSRoundedBezelStyle];
    [saveButton setTarget:self];
    [saveButton setAction:@selector(saveSettings:)];
    [self addSubview:saveButton];

    [self reloadSettings];
  }
  return self;
}

- (void)dealloc;
{
  [imapLocalPortField_ release];
  [imapServerField_ release];
  [imapServerPortField_ release];
  [smtpLocalPortField_ release];
  [smtpServerField_ release];
  [smtpServerPortField_ release];
  [super dealloc];
}

- (void)reloadSettings;
{
  NSString *errorMessage = nil;
  NSDictionary *configuration =
      [RCConfiguration loadConfigurationWithError:&errorMessage];
  NSDictionary *mailProxy;
  NSDictionary *imap;
  NSDictionary *smtp;

  if (configuration == nil) {
    [self showError:errorMessage];
    return;
  }
  mailProxy = [configuration objectForKey:@"MailProxy"];
  imap = [mailProxy objectForKey:@"IMAP"];
  smtp = [mailProxy objectForKey:@"SMTP"];
  [imapLocalPortField_ setIntValue:[[imap objectForKey:@"LocalPort"] intValue]];
  [imapServerField_ setStringValue:[imap objectForKey:@"RemoteHost"]];
  [imapServerPortField_ setIntValue:[[imap objectForKey:@"RemotePort"] intValue]];
  [smtpLocalPortField_ setIntValue:[[smtp objectForKey:@"LocalPort"] intValue]];
  [smtpServerField_ setStringValue:[smtp objectForKey:@"RemoteHost"]];
  [smtpServerPortField_ setIntValue:[[smtp objectForKey:@"RemotePort"] intValue]];
}

- (void)showError:(NSString *)message;
{
  NSRunAlertPanel(@"Retro Cloud Sync",
      message != nil ? message : @"Unknown error", @"OK", nil, nil);
}

- (NSTextField *)newEditableFieldWithFrame:(NSRect)frame;
{
  NSTextField *field = [[NSTextField alloc] initWithFrame:frame];

  [self addSubview:field];
  return field;
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

- (void)addServiceBox:(NSString *)title
                    y:(float)y
       localPortField:(NSTextField **)localPortField
          serverField:(NSTextField **)serverField
      serverPortField:(NSTextField **)serverPortField;
{
  NSBox *box = [[[NSBox alloc]
      initWithFrame:NSMakeRect(16, y, 448, 98)] autorelease];

  [box setTitle:title];
  [self addSubview:box];

  [self addLabel:@"Local port:" frame:NSMakeRect(30, y + 49, 78, 20)];
  *localPortField = [self newEditableFieldWithFrame:NSMakeRect(116, y + 47, 72, 22)];
  [self addLabel:@"Server:" frame:NSMakeRect(30, y + 20, 78, 20)];
  *serverField = [self newEditableFieldWithFrame:NSMakeRect(116, y + 18, 220, 22)];
  [self addLabel:@"Port:" frame:NSMakeRect(340, y + 20, 44, 20)];
  *serverPortField = [self newEditableFieldWithFrame:NSMakeRect(390, y + 18, 58, 22)];
}

- (void)saveSettings:(id)sender;
{
  NSDictionary *imap;
  NSDictionary *smtp;
  NSDictionary *mailProxy;
  NSString *errorMessage = nil;

  (void)sender;
  imap = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:[imapLocalPortField_ intValue]], @"LocalPort",
      [imapServerField_ stringValue], @"RemoteHost",
      [NSNumber numberWithInt:[imapServerPortField_ intValue]], @"RemotePort",
      nil];
  smtp = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:[smtpLocalPortField_ intValue]], @"LocalPort",
      [smtpServerField_ stringValue], @"RemoteHost",
      [NSNumber numberWithInt:[smtpServerPortField_ intValue]], @"RemotePort",
      nil];
  mailProxy = [NSDictionary dictionaryWithObjectsAndKeys:
      imap, @"IMAP", smtp, @"SMTP", nil];
  if (![RCConfiguration saveMailProxy:mailProxy error:&errorMessage]) {
    [self showError:errorMessage];
    return;
  }
}

@end
