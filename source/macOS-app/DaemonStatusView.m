//
//  DaemonStatusView.m
//  RetroCloudSync
//

#import "DaemonStatusView.h"

#import "RCServiceController.h"

@interface DaemonStatusView (Private)
- (void)serviceControlClicked:(id)sender;
- (void)updateServiceStatus:(NSTimer *)timer;
@end

@implementation DaemonStatusView

- (id)initWithFrame:(NSRect)frame;
{
  self = [super initWithFrame:frame];
  if (self != nil) {
    NSSegmentedControl *serviceControl;
    NSTextField *statusLabel;

    serviceController_ = [[RCServiceController alloc] init];

    serviceControl = [[[NSSegmentedControl alloc]
        initWithFrame:NSMakeRect(24, 254, 152, 28)] autorelease];
    [serviceControl setSegmentCount:2];
    [serviceControl setLabel:@"Start" forSegment:0];
    [serviceControl setLabel:@"Stop" forSegment:1];
    [serviceControl setWidth:76 forSegment:0];
    [serviceControl setWidth:76 forSegment:1];
    [(NSSegmentedCell *)[serviceControl cell]
        setTrackingMode:NSSegmentSwitchTrackingMomentary];
    [serviceControl setTarget:self];
    [serviceControl setAction:@selector(serviceControlClicked:)];
    [self addSubview:serviceControl];
    serviceControl_ = [serviceControl retain];

    statusLabel = [[[NSTextField alloc]
        initWithFrame:NSMakeRect(192, 256, 264, 24)] autorelease];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setStringValue:@"Checking daemon status..."];
    [self addSubview:statusLabel];
    statusLabel_ = [statusLabel retain];

    [self startUpdating];
  }
  return self;
}

- (void)dealloc;
{
  [statusTimer_ invalidate];
  [statusTimer_ release];
  [serviceControl_ setTarget:nil];
  [serviceControl_ release];
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
  [statusTimer_ autorelease];
  statusTimer_ = nil;
}

- (void)serviceControlClicked:(id)sender;
{
  NSInteger selectedSegment = [sender selectedSegment];
  NSString *errorMessage = nil;
  BOOL succeeded;

  [serviceControl_ setEnabled:NO];
  if (selectedSegment == 0) {
    [statusLabel_ setStringValue:@"Starting daemon..."];
    succeeded = [serviceController_ startServiceWithError:&errorMessage];
  } else {
    [statusLabel_ setStringValue:@"Stopping daemon..."];
    succeeded = [serviceController_ stopServiceWithError:&errorMessage];
  }

  if (!succeeded) {
    [statusLabel_ setStringValue:errorMessage];
  } else {
    [self updateServiceStatus:nil];
  }
  [serviceControl_ setEnabled:YES];
}

- (void)updateServiceStatus:(NSTimer *)timer;
{
  (void)timer;
  if ([serviceController_ isServiceRunning]) {
    [statusLabel_ setStringValue:@"Daemon is running"];
  } else {
    [statusLabel_ setStringValue:@"Daemon is stopped"];
  }
}

@end
