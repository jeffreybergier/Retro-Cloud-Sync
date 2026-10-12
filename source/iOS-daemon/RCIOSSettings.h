#import <AltivecCocoa/AICollectionTableViewController.h>
#import <UIKit/UIKit.h>
@interface RCIOSSettings : AICollectionTableViewController {
  NSDictionary *status_;
  NSTimer *refreshTimer_;
}
- (void)refresh;
@end

UIViewController *RCIOSRootController(void);
