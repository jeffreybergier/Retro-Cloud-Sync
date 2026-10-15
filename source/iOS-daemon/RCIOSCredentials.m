#import <AltivecCocoa/AIKeychainStore.h>
#include "RCICloudCredentials.h"
#include "RCIOSCredentialIdentity.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static AIKeychainStore *RCStore(void)
{
  AIKeychainStore *store = [[[AIKeychainStore alloc]
      initWithService:@"com.altivecintelligence.rcloud.icloud"] autorelease];
  [store setAccessGroup:@RCIOS_KEYCHAIN_GROUP];
  [store setAccessibility:AIKeychainAccessibilityAfterFirstUnlockThisDeviceOnly];
  [store setUpdatesAccessPolicy:YES];
  return store;
}

static int RCResult(BOOL result, NSError *nativeError, RCError *error)
{
  if (!result) RCErrorSet(error, nativeError ? (int)[nativeError code] : -50,
      "Account Keychain operation failed (%ld)",
      nativeError ? (long)[nativeError code] : -50L);
  return result ? 1 : 0;
}


int RCICloudCredentialsSave(const char *username, const void *password,
                           size_t length, const char *path, RCError *error)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSError *nativeError = nil;
  AIKeychainStore *store = RCStore();
  BOOL result = NO;
  RCErrorClear(error);
  if (!username || !*username || !password || !length || length > 4096) {
    RCErrorSet(error, -50, "Invalid iCloud credential parameters");
    [pool drain]; return 0;
  }
  (void)path;
  result = [store setData:[NSData dataWithBytes:password length:length]
      forKey:[NSString stringWithUTF8String:username] error:&nativeError];
  result = RCResult(result, nativeError, error);
  [pool drain];
  return result;
}

int RCICloudCredentialsCopyPassword(const char *username, char **password,
                                   size_t *length, RCError *error)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSError *nativeError = nil;
  NSData *data = nil;
  int result = 0;
  RCErrorClear(error);
  if (password) *password = NULL;
  if (length) *length = 0;
  if (!username || !*username || !password || !length) {
    RCErrorSet(error, -50, "Invalid iCloud credential parameters");
    [pool drain]; return 0;
  }
  data = [RCStore() dataForKey:[NSString stringWithUTF8String:username]
                       error:&nativeError];
  if (data) {
    if (![data length] || [data length] > 4096) {
      RCErrorSet(error, AIKeychainErrorDecode, "Invalid stored credential length");
      [pool drain]; return 0;
    }
    *password = (char *)calloc([data length] + 1, 1);
    if (*password) {
      *length = [data length];
      if (*length) memcpy(*password, [data bytes], *length);
      result = 1;
    } else RCErrorSet(error, -108, "Out of memory reading credentials");
  } else RCResult(NO, nativeError, error);
  [pool drain];
  return result;
}

int RCICloudCredentialsCopyUsername(const char *username, char **saved,
                                   RCError *error)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSError *nativeError = nil;
  int result = 0;
  RCErrorClear(error);
  if (saved) *saved = NULL;
  if (!username || !*username || !saved) {
    RCErrorSet(error, -50, "Invalid iCloud account parameters");
    [pool drain]; return 0;
  }
  if ([RCStore() containsKey:[NSString stringWithUTF8String:username]
                       error:&nativeError]) {
    *saved = strdup(username);
    if (*saved) result = 1;
    else RCErrorSet(error, -108, "Out of memory reading saved account");
  } else RCResult(NO, nativeError, error);
  [pool drain];
  return result;
}

int RCICloudCredentialsRemove(const char *username, RCError *error)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSError *nativeError = nil;
  BOOL result;
  RCErrorClear(error);

  result = [RCStore() removeItemForKey:username ?
      [NSString stringWithUTF8String:username] : nil error:&nativeError];
  if ([nativeError code] == errSecItemNotFound) result = YES;
  result = RCResult(result, nativeError, error);
  [pool drain];
  return result;
}

void RCICloudCredentialsClearPassword(char *password, size_t length)
{
  if (password) {
    volatile unsigned char *bytes = (volatile unsigned char *)password;
    while (length--) *bytes++ = 0;
    free(password);
  }
}
