//
//  MailServerView.m
//  RetroCloudSync
//

#import "MailServerView.h"

#import "RCConfiguration.h"

@interface MailServerView (Private)
- (NSTextField *)newEditableFieldWithFrame:(NSRect)frame
                          autoresizingMask:(unsigned int)mask;
- (void)addLabel:(NSString *)text
           frame:(NSRect)frame
autoresizingMask:(unsigned int)mask;
- (void)addServiceBox:(NSString *)title
                 frame:(NSRect)boxFrame
       localPortField:(NSTextField **)localPortField
          serverField:(NSTextField **)serverField
      serverPortField:(NSTextField **)serverPortField;
- (void)saveSettings:(id)sender;
- (NSString *)validationErrorForField:(NSTextField *)field;
- (void)showError:(NSString *)message;
- (void)alertDidEnd:(NSAlert *)alert
        returnCode:(NSInteger)returnCode
       contextInfo:(void *)contextInfo;
@end

@implementation MailServerView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    NSRect incomingBoxFrame;
    NSRect outgoingBoxFrame;
    const float edgePadding = 8;
    const float boxSpacing = 8;
    const float boxHeight = 78;

    incomingBoxFrame = NSMakeRect(
        edgePadding, NSHeight(frame) - edgePadding - boxHeight,
        NSWidth(frame) - (edgePadding * 2), boxHeight);
    outgoingBoxFrame = NSMakeRect(
        edgePadding, NSMinY(incomingBoxFrame) - boxSpacing - boxHeight,
        NSWidth(frame) - (edgePadding * 2), boxHeight);

    [self addServiceBox:@"Incoming Mail (IMAP)" frame:incomingBoxFrame
         localPortField:&imapLocalPortField_
            serverField:&imapServerField_
        serverPortField:&imapServerPortField_];
    [self addServiceBox:@"Outgoing Mail (SMTP)" frame:outgoingBoxFrame
         localPortField:&smtpLocalPortField_
            serverField:&smtpServerField_
        serverPortField:&smtpServerPortField_];
    [imapLocalPortField_ setNextKeyView:imapServerField_];
    [imapServerField_ setNextKeyView:imapServerPortField_];
    [imapServerPortField_ setNextKeyView:smtpLocalPortField_];
    [smtpLocalPortField_ setNextKeyView:smtpServerField_];
    [smtpServerField_ setNextKeyView:smtpServerPortField_];
    [smtpServerPortField_ setNextKeyView:imapLocalPortField_];

    [self reloadSettings];
  }
  return self;
}

- (void)dealloc;
{
  [imapLocalPortField_ setDelegate:nil];
  [imapServerField_ setDelegate:nil];
  [imapServerPortField_ setDelegate:nil];
  [smtpLocalPortField_ setDelegate:nil];
  [smtpServerField_ setDelegate:nil];
  [smtpServerPortField_ setDelegate:nil];
  [imapLocalPortField_ release];
  [imapServerField_ release];
  [imapServerPortField_ release];
  [smtpLocalPortField_ release];
  [smtpServerField_ release];
  [smtpServerPortField_ release];
  [pendingErrorMessage_ release];
  [super dealloc];
}

- (void)viewDidMoveToWindow;
{
  [super viewDidMoveToWindow];
  if ([self window] != nil && pendingErrorMessage_ != nil) {
    NSString *message = [pendingErrorMessage_ autorelease];

    pendingErrorMessage_ = nil;
    [self showError:message];
  }
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
  NSAlert *alert;

  if (showingError_) return;
  if ([self window] == nil) {
    [pendingErrorMessage_ release];
    pendingErrorMessage_ = [(message != nil ? message : @"Unknown error") copy];
    return;
  }
  showingError_ = YES;
  alert = [[[NSAlert alloc] init] autorelease];
  [alert setMessageText:@"Retro Cloud Sync"];
  [alert setInformativeText:message != nil ? message : @"Unknown error"];
  [alert addButtonWithTitle:@"OK"];
  [alert beginSheetModalForWindow:[self window]
                   modalDelegate:self
                  didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                     contextInfo:NULL];
}

- (void)alertDidEnd:(NSAlert *)alert
        returnCode:(NSInteger)returnCode
       contextInfo:(void *)contextInfo;
{
  (void)alert;
  (void)returnCode;
  (void)contextInfo;
  showingError_ = NO;
}

- (NSTextField *)newEditableFieldWithFrame:(NSRect)frame
                          autoresizingMask:(unsigned int)mask;
{
  NSTextField *field = [[NSTextField alloc] initWithFrame:frame];

  [field setAutoresizingMask:mask];
  [field setDelegate:self];
  [self addSubview:field];
  return field;
}

- (void)addLabel:(NSString *)text
           frame:(NSRect)frame
autoresizingMask:(unsigned int)mask;
{
  NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];

  [label setBezeled:NO];
  [label setDrawsBackground:NO];
  [label setEditable:NO];
  [label setSelectable:NO];
  [label setAlignment:NSRightTextAlignment];
  [label setStringValue:text];
  [label setAutoresizingMask:mask];
  [self addSubview:label];
}

- (void)addServiceBox:(NSString *)title
                 frame:(NSRect)boxFrame
       localPortField:(NSTextField **)localPortField
          serverField:(NSTextField **)serverField
      serverPortField:(NSTextField **)serverPortField;
{
  float innerLeft;
  float innerRight;
  float firstFieldY;
  float secondFieldY;
  float fieldX;
  float portFieldX;
  float portLabelX;
  const float boxPadding = 8;
  const float controlSpacing = 4;
  const float boxTitleHeight = 14;
  const float labelWidth = 70;
  const float localPortWidth = 72;
  const float portLabelWidth = 44;
  const float serverPortWidth = 58;
  const float fieldHeight = 22;
  const float labelHeight = 20;
  NSBox *box = [[[NSBox alloc]
      initWithFrame:boxFrame] autorelease];

  innerLeft = NSMinX(boxFrame) + boxPadding;
  innerRight = NSMaxX(boxFrame) - boxPadding;
  firstFieldY = NSMaxY(boxFrame) - boxTitleHeight - boxPadding - fieldHeight;
  secondFieldY = firstFieldY - controlSpacing - fieldHeight;
  fieldX = innerLeft + labelWidth + controlSpacing;
  portFieldX = innerRight - serverPortWidth;
  portLabelX = portFieldX - controlSpacing - portLabelWidth;

  [box setTitle:title];
  [box setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
  [self addSubview:box];

  [self addLabel:@"Local port:"
           frame:NSMakeRect(innerLeft, firstFieldY - 3,
                            labelWidth, labelHeight)
autoresizingMask:NSViewMinYMargin];
  *localPortField = [self newEditableFieldWithFrame:
      NSMakeRect(fieldX, firstFieldY, localPortWidth, fieldHeight)
      autoresizingMask:NSViewMinYMargin];
  [self addLabel:@"Server:"
           frame:NSMakeRect(innerLeft, secondFieldY - 3,
                            labelWidth, labelHeight)
autoresizingMask:NSViewMinYMargin];
  *serverField = [self newEditableFieldWithFrame:
      NSMakeRect(fieldX, secondFieldY,
                 portLabelX - controlSpacing - fieldX, fieldHeight)
      autoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
  [self addLabel:@"Port:"
           frame:NSMakeRect(portLabelX, secondFieldY - 3,
                            portLabelWidth, labelHeight)
autoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
  *serverPortField = [self newEditableFieldWithFrame:
      NSMakeRect(portFieldX, secondFieldY, serverPortWidth, fieldHeight)
      autoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
}

- (void)controlTextDidChange:(NSNotification *)notification;
{
  [self saveSettings:[notification object]];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification;
{
  NSString *errorMessage = [self validationErrorForField:[notification object]];

  if (errorMessage != nil) [self showError:errorMessage];
}

- (NSString *)validationErrorForField:(NSTextField *)field;
{
  NSString *service = (field == imapLocalPortField_ ||
      field == imapServerField_ || field == imapServerPortField_) ?
      @"IMAP" : @"SMTP";
  NSString *value = [field stringValue];

  if (field == imapServerField_ || field == smtpServerField_) {
    NSMutableCharacterSet *invalidCharacters =
        [[[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy]
            autorelease];

    [invalidCharacters addCharactersInString:@"/:\\"];
    if ([value length] == 0 || [value UTF8String] == NULL ||
        [value rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound) {
      return [NSString stringWithFormat:
          @"The %@ server must be a hostname without whitespace, a scheme, "
           "a port, or a path.", service];
    }
  } else {
    BOOL local = field == imapLocalPortField_ || field == smtpLocalPortField_;
    int minimum = local ? 1024 : 1;
    int port;
    NSScanner *scanner = [NSScanner scannerWithString:
        [value stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]]];

    [scanner setCharactersToBeSkipped:nil];
    if (![scanner scanInt:&port] || ![scanner isAtEnd] ||
        port < minimum || port > 65535) {
      return [NSString stringWithFormat:
          @"The %@ %@ port must be a whole number from %d to 65535.",
          service, local ? @"local" : @"server", minimum];
    }
  }
  return nil;
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
