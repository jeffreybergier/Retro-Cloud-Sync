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

    serviceController_ = [[RCServiceController alloc] init];

    serviceBox = [[[NSBox alloc]
        initWithFrame:NSMakeRect(16, 232, 448, 72)] autorelease];
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
    [statusLabel setStringValue:@"Stopped"];
    [self addSubview:statusLabel];
    statusLabel_ = statusLabel;

    serviceButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(368, 246, 88, 26)];
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
    succeeded = [serviceController_ stopServiceWithError:&errorMessage];
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

- (void)updateServiceStatus:(NSTimer *)timer;
{
  (void)timer;
  serviceRunning_ = [serviceController_ isServiceRunning];
  if (serviceRunning_) {
    [statusLabel_ setStringValue:@"Running"];
    [serviceButton_ setTitle:@"Stop"];
  } else {
    [statusLabel_ setStringValue:@"Stopped"];
    [serviceButton_ setTitle:@"Start"];
  }
}

@end
