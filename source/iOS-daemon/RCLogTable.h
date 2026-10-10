#import <UIKit/UIKit.h>
@interface RCLogTable : UITableViewController { NSArray *lines_; NSTimer *refreshTimer_; }
- (void)refresh;
@end
