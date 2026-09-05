//
//  RCConfiguration.h
//  RetroCloudSync
//

#import <Foundation/Foundation.h>

@interface RCConfiguration : NSObject

+ (NSString *)configurationPath;
+ (NSDictionary *)defaultConfiguration;
+ (NSDictionary *)loadConfigurationWithError:(NSString **)errorMessage;
+ (BOOL)saveConfiguration:(NSDictionary *)configuration
                     error:(NSString **)errorMessage;
+ (BOOL)ensureConfigurationExistsWithError:(NSString **)errorMessage;
+ (NSDictionary *)contactsConfigurationFromConfiguration:
    (NSDictionary *)configuration;
+ (BOOL)saveContactsSyncMode:(NSString *)contactsSyncMode
           calendarsSyncMode:(NSString *)calendarsSyncMode
                     username:(NSString *)username
                 syncInterval:(long long)syncInterval
                        error:(NSString **)errorMessage;
+ (BOOL)saveMailProxy:(NSDictionary *)mailProxy
                 error:(NSString **)errorMessage;

@end
