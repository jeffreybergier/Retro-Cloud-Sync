//
//  MailServerView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@interface MailServerView : NSView {
 @private
  NSTextField *imapLocalPortField_;
  NSTextField *imapServerField_;
  NSTextField *imapServerPortField_;
  NSTextField *smtpLocalPortField_;
  NSTextField *smtpServerField_;
  NSTextField *smtpServerPortField_;
}

- (void)reloadSettings;

@end
