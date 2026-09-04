//
//  ContactsView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@interface ContactsView : NSView {
 @private
  NSMatrix *contactsSyncMatrix_;
  NSMatrix *calendarsSyncMatrix_;
  NSTextField *usernameField_;
  NSSecureTextField *passwordField_;
  NSTextField *intervalField_;
}

- (void)reloadSettings;

@end
