#import <UIKit/UIKit.h>
#import <AltivecCocoa/AICollectionController.h>
@interface RCLogViewController : UIViewController {
  UITextView *textView_;
  AICollectionController *loader_;
  NSTimer *refreshTimer_;
}
- (void)refresh;
@end
