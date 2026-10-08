//
//  AppDelegate.h
//  RetroCloudSync
//

#import <AppKit/AppKit.h>

@class PreferencesWindowController;

@interface AppDelegate : NSObject
#if defined(__LP64__)
    <NSApplicationDelegate>
#endif
{
 @private
  PreferencesWindowController *preferencesWindowController_;
}
@end
