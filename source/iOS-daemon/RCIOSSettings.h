#import <UIKit/UIKit.h>
@interface RCIOSSettings : UITableViewController {
  NSDictionary *status_;
  NSTimer *refreshTimer_;
}
- (void)refresh;
@end

UIViewController *RCIOSRootController(void);
