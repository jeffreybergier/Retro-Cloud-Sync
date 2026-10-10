#import <UIKit/UIKit.h>
@interface RCAccountTable : UITableViewController <UITextFieldDelegate> {
  NSMutableDictionary *config_; NSMutableDictionary *settings_; UITextField *username_; UITextField *password_; BOOL unreadable_;
}
- (void)save;
- (void)resetAccount;
@end
