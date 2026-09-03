//
//  DaemonLogView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@interface DaemonLogView : NSView {
 @private
  NSTextView *textView_;
  NSTextField *pathLabel_;
  NSTimer *refreshTimer_;
  NSString *logPath_;
}

- (void)reloadLog;
- (void)startUpdating;
- (void)stopUpdating;
@end
