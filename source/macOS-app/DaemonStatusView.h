//
//  DaemonStatusView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class RCServiceController;

@interface DaemonStatusView : NSView {
 @private
  NSButton *serviceButton_;
  NSTextField *statusLabel_;
  NSImageView *serviceIcon_;
  NSTimer *statusTimer_;
  RCServiceController *serviceController_;
  BOOL serviceRunning_;
  BOOL stopInProgress_;
  NSTextField *syncDetails_[2];
  NSImageView *syncIcon_[2];
}

// Starts periodic daemon status checks if they are not already active.
- (void)startUpdating;

// Stops periodic daemon status checks and breaks the timer retain cycle.
- (void)stopUpdating;
@end
