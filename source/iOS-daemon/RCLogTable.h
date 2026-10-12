#import <AltivecCocoa/AICollectionTableViewController.h>
#import <AltivecCocoa/AICollectionController.h>
#import <UIKit/UIKit.h>
@interface RCLogTable : AICollectionTableViewController { NSArray *lines_; AICollectionController *loader_; NSTimer *refreshTimer_; }
- (void)refresh;
@end
