//
//  AXTestRunner.h
//  RetroCloudSyncTests
//

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

@interface AXTestRunner : NSObject {
 @private
  NSString *applicationPath_;
  NSString *screenshotsDirectory_;
  NSTask *applicationTask_;
  AXUIElementRef applicationElement_;
  AXUIElementRef windowElement_;
}

// Initializes a runner for the app bundle at |applicationPath|.
- (id)initWithApplicationPath:(NSString *)applicationPath
         screenshotsDirectory:(NSString *)screenshotsDirectory;

// Prints the current Accessibility hierarchy without changing service state.
- (BOOL)dumpAccessibilityTree;

// Exercises both preferences panels, then runs the daemon Start/Stop test.
- (BOOL)runTests;
@end
