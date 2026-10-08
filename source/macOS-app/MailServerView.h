//
//  MailServerView.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@interface MailServerView : NSView
#if defined(__LP64__)
    <NSTextFieldDelegate>
#endif
{
 @private
  NSTextField *imapLocalPortField_;
  NSTextField *imapServerField_;
  NSTextField *imapServerPortField_;
  NSTextField *smtpLocalPortField_;
  NSTextField *smtpServerField_;
  NSTextField *smtpServerPortField_;
  BOOL showingError_;
  NSString *pendingErrorMessage_;
}

- (void)reloadSettings;

@end
