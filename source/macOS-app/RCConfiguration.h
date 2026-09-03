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
+ (BOOL)validateConfiguration:(NSDictionary *)configuration
                         error:(NSString **)errorMessage;
+ (NSDictionary *)contactsConfigurationFromConfiguration:
    (NSDictionary *)configuration;
+ (BOOL)saveContactsEnabled:(BOOL)enabled
           calendarsEnabled:(BOOL)calendarsEnabled
                   username:(NSString *)username
               syncInterval:(unsigned int)syncInterval
                      error:(NSString **)errorMessage;
+ (BOOL)saveMailProxy:(NSDictionary *)mailProxy
                 error:(NSString **)errorMessage;

@end
