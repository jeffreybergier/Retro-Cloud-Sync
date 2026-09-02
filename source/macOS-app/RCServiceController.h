//
//  RCServiceController.h
//  RetroCloudSync
//

#import <Foundation/Foundation.h>

@interface RCServiceController : NSObject
- (BOOL)isServiceRunning;
- (BOOL)startServiceWithError:(NSString **)errorMessage;
- (BOOL)stopServiceWithError:(NSString **)errorMessage;
@end
