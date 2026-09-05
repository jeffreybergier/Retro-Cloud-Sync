//
//  ContactsView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class RCIntervalSlider;

@interface ContactsView : NSView {
 @private
  NSMatrix *contactsSyncMatrix_;
  NSMatrix *calendarsSyncMatrix_;
  NSTextField *usernameField_;
  NSSecureTextField *passwordField_;
  RCIntervalSlider *intervalSlider_;
  NSTextField *intervalLabel_;
  long long syncIntervalSeconds_;
  NSButton *accountButton_;
  BOOL hasCredentials_;
}

- (void)reloadSettings;

@end
