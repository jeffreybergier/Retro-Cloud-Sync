#import <AltivecCocoa/AICollectionTableViewController.h>
#import <UIKit/UIKit.h>
@interface RCMailTable : AICollectionTableViewController <UITextFieldDelegate> {
  NSArray *fields_; NSMutableDictionary *config_; BOOL unreadable_;
}
- (void)save;
@end
