//
//  ContactsView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@interface ContactsView : NSView {
 @private
  NSButton *enabledButton_;
  NSButton *calendarsEnabledButton_;
  NSTextField *usernameField_;
  NSSecureTextField *passwordField_;
  NSTextField *intervalField_;
}

- (void)reloadSettings;

@end
