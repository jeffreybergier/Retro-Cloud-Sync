//
//  PreferencesWindowController.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class DaemonStatusView;
@class MailServerView;
@class ContactsView;
@class DaemonLogView;

@interface PreferencesWindowController : NSWindowController {
 @private
  DaemonStatusView *daemonStatusView_;
  MailServerView *mailServerView_;
  ContactsView *contactsView_;
  DaemonLogView *daemonLogView_;
  NSToolbar *toolbar_;
  NSImage *daemonToolbarImage_;
  NSImage *mailToolbarImage_;
  NSImage *contactsToolbarImage_;
  NSImage *logToolbarImage_;
  NSView *visibleView_;
}
@end
