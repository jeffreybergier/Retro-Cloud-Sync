//
//  PreferencesWindowController.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class DaemonStatusView;
@class MailServerView;
@class ContactsView;

@interface PreferencesWindowController : NSWindowController {
 @private
  DaemonStatusView *daemonStatusView_;
  MailServerView *mailServerView_;
  ContactsView *contactsView_;
  NSToolbar *toolbar_;
  NSImage *daemonToolbarImage_;
  NSImage *mailToolbarImage_;
  NSImage *contactsToolbarImage_;
  NSView *visibleView_;
}
@end
