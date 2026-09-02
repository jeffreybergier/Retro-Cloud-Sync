//
//  PreferencesWindowController.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class DaemonStatusView;

@interface PreferencesWindowController : NSWindowController {
 @private
  DaemonStatusView *daemonStatusView_;
}
@end
