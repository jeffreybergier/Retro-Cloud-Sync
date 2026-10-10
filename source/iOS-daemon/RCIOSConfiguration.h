#import <UIKit/UIKit.h>
extern NSString *const RCIOSSettingsDirectory;
NSString *RCIOSConfigPath(void);
void RCIOSMessage(NSString *title, NSString *message);
BOOL RCIOSSaveConfiguration(NSDictionary *config);
