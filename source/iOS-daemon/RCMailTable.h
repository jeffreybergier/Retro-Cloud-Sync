#import <UIKit/UIKit.h>
@interface RCMailTable : UITableViewController <UITextFieldDelegate> {
  UISwitch *enabled_; NSArray *fields_; NSMutableDictionary *config_; BOOL unreadable_;
}
- (void)save;
@end
