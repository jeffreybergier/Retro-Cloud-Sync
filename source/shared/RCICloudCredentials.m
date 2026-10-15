#import <AltivecCocoa/AIKeychainStore.h>
#include "RCICloudCredentials.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static AIKeychainStore *RCStore(void)
{
  AIKeychainStore *store = [[[AIKeychainStore alloc]
      initWithService:@"com.altivecintelligence.rcloud.icloud"] autorelease];
  [store setLabel:@"rCloud iCloud Account"];
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

static const int kRCMemoryError = -108;
static OSStatus RCCreateAccess(const char *daemonPath, SecAccessRef *access)
{
  SecTrustedApplicationRef application = NULL;
  SecTrustedApplicationRef daemon = NULL;
  CFMutableArrayRef trusted = NULL;
  OSStatus status;

  status = SecTrustedApplicationCreateFromPath(NULL, &application);
  if (status != noErr) goto finished;
  status = SecTrustedApplicationCreateFromPath(daemonPath, &daemon);
  if (status != noErr) goto finished;
  trusted = CFArrayCreateMutable(NULL, 2, &kCFTypeArrayCallBacks);
  if (trusted == NULL) {
    status = kRCMemoryError;
    goto finished;
  }
  CFArrayAppendValue(trusted, application);
  CFArrayAppendValue(trusted, daemon);
  status = SecAccessCreate(CFSTR("rCloud iCloud Account"), trusted,
                           access);

finished:
  if (trusted != NULL) CFRelease(trusted);
  if (daemon != NULL) CFRelease(daemon);
  if (application != NULL) CFRelease(application);
  return status;
}

int RCICloudCredentialsSave(const char *username, const void *password,
                           size_t length, const char *path, RCError *error)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSError *nativeError = nil;
  AIKeychainStore *store = RCStore();
  BOOL result = NO;
  RCErrorClear(error);
  if (!username || !*username || !password || !length || length > UINT_MAX) {
    RCErrorSet(error, -50, "Invalid iCloud credential parameters");
    [pool drain]; return 0;
  }
  {
    SecAccessRef access = NULL;
    OSStatus status;
    if (!path || !*path) {
      RCErrorSet(error, -50, "Invalid daemon path"); [pool drain]; return 0;
    }
    status = RCCreateAccess(path, &access);
    if (status != noErr) {
      RCErrorSet(error, (int)status, "Could not create credential access rules");
      [pool drain]; return 0;
    }
    [store setAccess:access];
    CFRelease(access);
  }
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
  if (!username || !*username) { [pool drain]; return 1; }
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
