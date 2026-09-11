//
//  DaemonStatusView.m
//  RetroCloudSync
//

#import "DaemonStatusView.h"

#import "RCServiceController.h"
#import "RCConfiguration.h"
#import <AltivecCocoa/AIFontAwesome.h>
#include <signal.h>
#include <errno.h>

@interface DaemonStatusView (Private)
- (void)serviceButtonClicked:(id)sender;
- (void)updateServiceStatus:(NSTimer *)timer;
- (void)updateSyncStatus;
- (void)stopServiceInBackground:(id)unused;
- (void)stopServiceFinished:(NSString *)errorMessage;
@end

static NSTextField *RCStatusLabel(NSView *view, NSRect frame)
{
  NSTextField *label=[[[NSTextField alloc] initWithFrame:frame] autorelease];
  [label setBezeled:NO]; [label setDrawsBackground:NO]; [label setEditable:NO];
  [label setSelectable:YES];
  [[label cell] setWraps:YES];
  [[label cell] setScrollable:NO];
  [label setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
  [view addSubview:label]; return label;
}
/* Six paragraphs in one field: a muted heading followed by its value.
   Fixed line heights keep both service sections aligned, including empty states. */
static NSAttributedString *RCStatusDetails(NSString *message, NSString *last,
                                          NSString *heading, NSString *detail)
{
  NSArray *rows=[NSArray arrayWithObjects:@"Status",message,
      @"Last successful sync",last,heading,detail,nil];
  NSMutableAttributedString *text=[[[NSMutableAttributedString alloc] init] autorelease];
  unsigned int i;
  for(i=0;i<6;i++) {
    BOOL isHeading=(i%2)==0;
    NSMutableParagraphStyle *paragraph=[[[NSMutableParagraphStyle alloc] init] autorelease];
    [paragraph setMinimumLineHeight:16];
    [paragraph setMaximumLineHeight:16];
    [paragraph setParagraphSpacing:!isHeading && i<5 ? 6 : 0];
    [paragraph setLineBreakMode:NSLineBreakByTruncatingTail];
    NSDictionary *attributes=[NSDictionary dictionaryWithObjectsAndKeys:
        isHeading ? [NSFont boldSystemFontOfSize:11] : [NSFont systemFontOfSize:12],NSFontAttributeName,
        isHeading ? [NSColor darkGrayColor] : [NSColor controlTextColor],NSForegroundColorAttributeName,
        paragraph,NSParagraphStyleAttributeName,nil];
    NSString *row=[rows objectAtIndex:i];
    if(i<5) row=[row stringByAppendingString:@"\n"];
    [text appendAttributedString:[[[NSAttributedString alloc] initWithString:row
        attributes:attributes] autorelease]];
  }
  return text;
}
static NSImage *RCStatusIcon(NSString *severity, BOOL paused)
{
  BOOL red=[severity isEqual:@"red"], green=[severity isEqual:@"green"];
  AIFontAwesomeIcon glyph=paused ? AIFAPause : red ? AIFACircleXmark : green ? AIFACircleCheck : AIFATriangleExclamation;
  NSImage *source=[AIFontAwesome imageForIcon:glyph style:AIFontAwesomeStyleSolid
      iconSize:18 canvasSize:24 scale:1];
  NSImage *image=[[[NSImage alloc] initWithSize:NSMakeSize(24,24)] autorelease];
  [image lockFocus];
  [source drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
  NSColor *color=red ? [NSColor colorWithCalibratedRed:0.78 green:0.12 blue:0.12 alpha:1] :
      green ? [NSColor colorWithCalibratedRed:0.12 green:0.55 blue:0.22 alpha:1] :
      [NSColor colorWithCalibratedRed:0.78 green:0.57 blue:0.03 alpha:1];
  [color set]; NSRectFillUsingOperation(NSMakeRect(0,0,24,24),NSCompositeSourceIn);
  [image unlockFocus]; return image;
}
static NSString *RCStatusDate(id value)
{
  if(![value isKindOfClass:[NSDate class]]) return @"Not yet synced";
  NSDateFormatter *formatter=[[[NSDateFormatter alloc] init] autorelease];
  [formatter setFormatterBehavior:NSDateFormatterBehavior10_4];
  [formatter setDateStyle:NSDateFormatterShortStyle]; [formatter setTimeStyle:NSDateFormatterShortStyle];
  return [formatter stringFromDate:value];
}

@implementation DaemonStatusView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    NSBox *serviceBox;
    NSButton *serviceButton;
    NSTextField *statusTitle;
    NSTextField *statusLabel;
    NSRect boxFrame;
    float innerLeft;
    float innerRight;
    float buttonX;
    float buttonY;
    float textY;
    const float edgePadding = 8;
    const float boxPadding = 8;
    const float controlSpacing = 4;
    const float boxTitleHeight = 14;
    const float labelWidth = 70;
    const float buttonWidth = 88;
    const float buttonHeight = 26;
    const float textHeight = 20;
    float boxHeight;

    serviceController_ = [[RCServiceController alloc] init];
    boxHeight = boxTitleHeight + boxPadding + buttonHeight + boxPadding;
    boxFrame = NSMakeRect(edgePadding,
        NSHeight(frame) - edgePadding - boxHeight,
        NSWidth(frame) - (edgePadding * 2), boxHeight);
    innerLeft = NSMinX(boxFrame) + boxPadding;
    innerRight = NSMaxX(boxFrame) - boxPadding;
    buttonX = innerRight - buttonWidth;
    buttonY = NSMinY(boxFrame) + boxPadding;
    textY = buttonY + ((buttonHeight - textHeight) / 2);

    serviceBox = [[[NSBox alloc]
        initWithFrame:boxFrame] autorelease];
    [serviceBox setTitle:@"Daemon"];
    [serviceBox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:serviceBox];

    statusTitle = [[[NSTextField alloc]
        initWithFrame:NSMakeRect(innerLeft, textY,
                                 labelWidth, textHeight)] autorelease];
    [statusTitle setBezeled:NO];
    [statusTitle setDrawsBackground:NO];
    [statusTitle setEditable:NO];
    [statusTitle setSelectable:NO];
    [statusTitle setAlignment:NSRightTextAlignment];
    [statusTitle setStringValue:@"Status:"];
    [statusTitle setAutoresizingMask:NSViewMinYMargin];
    [self addSubview:statusTitle];

    statusLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(innerLeft + labelWidth + controlSpacing,
            textY,
            buttonX - controlSpacing -
                (innerLeft + labelWidth + controlSpacing),
            textHeight)];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setStringValue:@"Stopped"];
    [statusLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [self addSubview:statusLabel];
    statusLabel_ = statusLabel;

    serviceButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(buttonX, buttonY,
                                 buttonWidth, buttonHeight)];
    [serviceButton setTitle:@"Start"];
    [serviceButton setBezelStyle:NSRoundedBezelStyle];
    [serviceButton setTarget:self];
    [serviceButton setAction:@selector(serviceButtonClicked:)];
    [serviceButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [self addSubview:serviceButton];
    serviceButton_ = serviceButton;

    const float sectionGap = 8;
    const float sectionHeight = 178;
    int i;
    for(i=0;i<2;i++) {
      NSBox *box=[[[NSBox alloc] initWithFrame:NSMakeRect(8,
          NSMinY(boxFrame)-(i+1)*(sectionHeight+sectionGap),
          NSWidth(frame)-16,sectionHeight)] autorelease];
      [box setTitle:i==0 ? @"Contacts" : @"Calendars"];
      [box setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin]; [self addSubview:box];
      NSView *content=[box contentView]; float width=NSWidth([content bounds]);
      syncIcon_[i]=[[[NSImageView alloc] initWithFrame:NSMakeRect(6,122,24,24)] autorelease];
      [syncIcon_[i] setAutoresizingMask:NSViewMinYMargin]; [content addSubview:syncIcon_[i]];
      syncDetails_[i]=RCStatusLabel(content,NSMakeRect(36,36,width-42,114));

    }
    [self startUpdating];
  }
  return self;
}

- (void)dealloc;
{
  [statusTimer_ invalidate];
  [statusTimer_ release];
  [serviceButton_ setTarget:nil];
  [serviceButton_ release];
  [statusLabel_ release];
  [serviceController_ release];
  [super dealloc];
}

- (void)startUpdating;
{
  if (statusTimer_ != nil) {
    return;
  }
  [self updateServiceStatus:nil];
  statusTimer_ = [[NSTimer scheduledTimerWithTimeInterval:2.0
                                                   target:self
                                                 selector:@selector(updateServiceStatus:)
                                                 userInfo:nil
                                                  repeats:YES] retain];
}

- (void)stopUpdating;
{
  [statusTimer_ invalidate];
  [statusTimer_ release];
  statusTimer_ = nil;
}

- (void)serviceButtonClicked:(id)sender;
{
  NSString *errorMessage = nil;
  BOOL succeeded;

  (void)sender;
  [serviceButton_ setEnabled:NO];
  if (!serviceRunning_) {
    [statusLabel_ setStringValue:@"Starting..."];
    [statusLabel_ display];
    succeeded = [serviceController_ startServiceWithError:&errorMessage];
  } else {
    stopInProgress_=YES;
    [statusLabel_ setStringValue:@"Stopping…"];
    [NSThread detachNewThreadSelector:@selector(stopServiceInBackground:) toTarget:self withObject:nil];
    return;
  }

  if (!succeeded) {
    [statusLabel_ setStringValue:@"Error"];
    NSRunAlertPanel(@"Retro Cloud Sync",
        errorMessage != nil ? errorMessage : @"Unknown service error",
        @"OK", nil, nil);
    [statusLabel_ setStringValue:@"Error"];
  } else {
    serviceRunning_ = !serviceRunning_;
    [statusLabel_ setStringValue:serviceRunning_ ? @"Running" : @"Stopped"];
    [serviceButton_ setTitle:serviceRunning_ ? @"Stop" : @"Start"];
  }
  [serviceButton_ setEnabled:YES];
}

- (void)stopServiceInBackground:(id)unused;
{
  (void)unused;
  NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
  RCServiceController *controller=[[RCServiceController alloc] init];
  NSString *error=nil;
  @try {
    if(![controller stopServiceWithError:&error] && !error) error=@"Could not stop the daemon";
  } @catch(NSException *exception) { error=@"Could not complete the stop request"; }
  [self performSelectorOnMainThread:@selector(stopServiceFinished:) withObject:error waitUntilDone:NO];
  [controller release]; [pool release];
}
- (void)stopServiceFinished:(NSString *)errorMessage;
{
  stopInProgress_=NO;
  [self updateServiceStatus:nil];
  [serviceButton_ setEnabled:YES];
  if(errorMessage) NSRunAlertPanel(@"Retro Cloud Sync",@"%@",@"OK",nil,nil,errorMessage);
}

- (void)updateServiceStatus:(NSTimer *)timer;
{
  (void)timer;
  [self updateSyncStatus];
  serviceRunning_ = [serviceController_ isServiceRunning];
  if(stopInProgress_) { [statusLabel_ setStringValue:@"Stopping…"]; return; }
  if (serviceRunning_) {
    [statusLabel_ setStringValue:@"Running"];
    [serviceButton_ setTitle:@"Stop"];
  } else {
    [statusLabel_ setStringValue:@"Stopped"];
    [serviceButton_ setTitle:@"Start"];
  }
}

- (void)updateSyncStatus;
{
  NSString *path=[[[RCConfiguration configurationPath] stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"Status.plist"];
  NSDictionary *snapshot=[NSDictionary dictionaryWithContentsOfFile:path];
  int pid=[[snapshot objectForKey:@"PID"] intValue];
  BOOL live=[[snapshot objectForKey:@"Running"] boolValue] && pid>0 &&
      (kill(pid,0)==0 || errno==EPERM) && [serviceController_ isServiceRunning];
  int i;
  for(i=0;i<2;i++) {
    id entry=[snapshot objectForKey:i==0 ? @"Contacts" : @"Calendars"];
    NSDictionary *s=[entry isKindOfClass:[NSDictionary class]] ? entry : nil;
    NSString *phase=[s objectForKey:@"Phase"], *code=[s objectForKey:@"ErrorCode"];
    BOOL disabled=[phase isEqual:@"Disabled"];
    NSString *message=@"Waiting for daemon status";
    if([phase isEqual:@"UpToDate"]) message=@"Up to date";
    else if([phase isEqual:@"Stopping"]) message=@"Stopping — saving progress…";
    else if([phase isEqual:@"Waiting"]) message=@"Waiting to sync";
    else if([phase isEqual:@"Downloading"]) message=@"Downloading from iCloud…";
    else if([phase isEqual:@"Applying"]) message=i==0 ? @"Applying to Address Book…" : @"Applying to iCal…";
    else if([phase isEqual:@"Uploading"]) message=@"Uploading to iCloud…";
    else if([phase isEqual:@"Attention"]) message=@"Changes need attention";
    if([code isEqual:@"Credentials"]) message=@"Saved password unavailable — check Keychain";
    else if([code isEqual:@"Configuration"]) message=@"Check your account settings — see log";
    else if([code isEqual:@"Database"]) message=@"Could not open the sync database";
    else if([code isEqual:@"Download"]) message=@"Could not download from iCloud — see log";
    else if([code isEqual:@"Apply"]) message=@"Could not apply local changes — see log";
    else if([code isEqual:@"Upload"]) message=@"Could not finish uploading — see log";
    if(disabled) message=@"Disabled";
    else if(!live && s) message=@"Paused — background service stopped";
    [syncIcon_[i] setImage:RCStatusIcon(live && !disabled ? [s objectForKey:@"Severity"] : @"yellow",!live || disabled)];
    id next=[s objectForKey:@"NextAttempt"]; long pending=[[s objectForKey:@"PendingCount"] longValue];
    NSString *heading=code ? @"Next retry" : @"Next sync";
    NSString *detail=disabled ? @"Disabled" : !live ? @"Not scheduled" : @"Waiting for schedule";
    if(live && !disabled && [next isKindOfClass:[NSDate class]])
      detail=RCStatusDate(next);
    if(pending>0) {
      heading=@"Pending items";
      detail=[NSString stringWithFormat:@"%ld%@",pending,live ? @" — see log" : @""];
    }
    NSAttributedString *details=RCStatusDetails(message,
        RCStatusDate([s objectForKey:@"LastSuccess"]),heading,detail);
    [syncDetails_[i] setAttributedStringValue:details];
    [syncDetails_[i] setToolTip:[details string]];
  }
}
@end
