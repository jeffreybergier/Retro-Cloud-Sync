//
//  DaemonStatusView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class RCServiceController;

@interface DaemonStatusView : NSView {
 @private
  NSSegmentedControl *serviceControl_;
  NSTextField *statusLabel_;
  NSTimer *statusTimer_;
  RCServiceController *serviceController_;
}

// Starts periodic daemon status checks if they are not already active.
- (void)startUpdating;

// Stops periodic daemon status checks and breaks the timer retain cycle.
- (void)stopUpdating;
@end
