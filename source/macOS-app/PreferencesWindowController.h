//
//  PreferencesWindowController.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class DaemonStatusView;
@class MailServerView;

@interface PreferencesWindowController : NSWindowController {
 @private
  DaemonStatusView *daemonStatusView_;
  MailServerView *mailServerView_;
  NSToolbar *toolbar_;
  NSImage *daemonToolbarImage_;
  NSImage *mailToolbarImage_;
  NSView *visibleView_;
}
@end
