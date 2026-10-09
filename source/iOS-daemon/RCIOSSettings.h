#import <UIKit/UIKit.h>
@interface RCIOSSettings : UITableViewController {
  NSDictionary *status_;
  NSTimer *refreshTimer_;
}
@end

UIViewController *RCIOSRootController(void);
