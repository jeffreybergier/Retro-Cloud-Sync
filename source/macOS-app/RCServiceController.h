//
//  RCServiceController.h
//  RetroCloudSync
//

#import <Foundation/Foundation.h>

@interface RCServiceController : NSObject
- (BOOL)isServiceRunning;
- (BOOL)prepareServiceFilesWithError:(NSString **)errorMessage;
- (NSString *)installedDaemonPath;
- (BOOL)startServiceWithError:(NSString **)errorMessage;
- (BOOL)stopServiceWithError:(NSString **)errorMessage;
@end
