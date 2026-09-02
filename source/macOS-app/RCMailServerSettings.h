//
//  RCMailServerSettings.h
//  RetroCloudSync
//

#import <Foundation/Foundation.h>

@interface RCMailServerSettings : NSObject

+ (NSString *)configurationPath;
+ (NSDictionary *)defaultConfiguration;
+ (NSDictionary *)loadConfigurationWithError:(NSString **)errorMessage;
+ (BOOL)saveConfiguration:(NSDictionary *)configuration
                     error:(NSString **)errorMessage;
+ (BOOL)ensureConfigurationExistsWithError:(NSString **)errorMessage;
+ (BOOL)validateConfiguration:(NSDictionary *)configuration
                         error:(NSString **)errorMessage;

@end
