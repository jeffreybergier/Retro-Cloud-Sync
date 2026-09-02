//
//  DaemonStatusView.m
//  RetroCloudSync
//

#import "DaemonStatusView.h"

#import "RCServiceController.h"

@interface DaemonStatusView (Private)
- (void)serviceButtonClicked:(id)sender;
- (void)updateServiceStatus:(NSTimer *)timer;
@end

@implementation DaemonStatusView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    NSBox *serviceBox;
    NSButton *serviceButton;
    NSTextField *statusTitle;
    NSTextField *statusLabel;
    NSTextField *detailLabel;

    serviceController_ = [[RCServiceController alloc] init];

    serviceBox = [[[NSBox alloc]
        initWithFrame:NSMakeRect(16, 206, 448, 98)] autorelease];
    [serviceBox setTitle:@"Background Service"];
    [self addSubview:serviceBox];

    statusTitle = [[[NSTextField alloc]
        initWithFrame:NSMakeRect(30, 253, 78, 20)] autorelease];
    [statusTitle setBezeled:NO];
    [statusTitle setDrawsBackground:NO];
    [statusTitle setEditable:NO];
    [statusTitle setSelectable:NO];
    [statusTitle setAlignment:NSRightTextAlignment];
    [statusTitle setStringValue:@"Status:"];
    [self addSubview:statusTitle];

    statusLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(116, 253, 220, 20)];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setStringValue:@"Checking..."];
    [self addSubview:statusLabel];
    statusLabel_ = statusLabel;

    detailLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(116, 228, 240, 18)];
    [detailLabel setBezeled:NO];
    [detailLabel setDrawsBackground:NO];
    [detailLabel setEditable:NO];
    [detailLabel setSelectable:NO];
    [detailLabel setFont:
        [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [detailLabel setStringValue:@"Checking daemon status..."];
    [self addSubview:detailLabel];
    detailLabel_ = detailLabel;

    serviceButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(368, 238, 88, 26)];
    [serviceButton setTitle:@"Start"];
    [serviceButton setBezelStyle:NSRoundedBezelStyle];
    [serviceButton setTarget:self];
    [serviceButton setAction:@selector(serviceButtonClicked:)];
    [self addSubview:serviceButton];
    serviceButton_ = serviceButton;

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
  [detailLabel_ release];
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
  [detailLabel_ setTextColor:[NSColor controlTextColor]];
  if (!serviceRunning_) {
    [statusLabel_ setStringValue:@"Starting..."];
    [detailLabel_ setStringValue:@""];
    succeeded = [serviceController_ startServiceWithError:&errorMessage];
  } else {
    [statusLabel_ setStringValue:@"Stopping..."];
    [detailLabel_ setStringValue:@""];
    succeeded = [serviceController_ stopServiceWithError:&errorMessage];
  }

  if (!succeeded) {
    [self updateServiceStatus:nil];
    [detailLabel_ setTextColor:[NSColor redColor]];
    [detailLabel_ setStringValue:errorMessage];
  } else {
    [self updateServiceStatus:nil];
  }
  [serviceButton_ setEnabled:YES];
}

- (void)updateServiceStatus:(NSTimer *)timer;
{
  (void)timer;
  serviceRunning_ = [serviceController_ isServiceRunning];
  [detailLabel_ setTextColor:[NSColor controlTextColor]];
  if (serviceRunning_) {
    [statusLabel_ setStringValue:@"Running"];
    [detailLabel_ setStringValue:@"The daemon is running normally."];
    [serviceButton_ setTitle:@"Stop"];
  } else {
    [statusLabel_ setStringValue:@"Stopped"];
    [detailLabel_ setStringValue:@"The daemon is not running."];
    [serviceButton_ setTitle:@"Start"];
  }
}

@end
