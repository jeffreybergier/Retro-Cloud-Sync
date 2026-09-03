#include "RCICloudCredentials.h"

#include <Security/Security.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static const char kRCService[] = "com.retrocloudsync.icloud";
static const char kRCLabel[] = "Retro Cloud Sync iCloud Account";
static const int kRCParameterError = -50;
static const int kRCMemoryError = -108;

static void RCSetSecurityError(RCError *error, OSStatus status,
                               const char *operation)
{
  RCErrorSet(error, (int)status, "%s (Keychain error %ld)", operation,
             (long)status);
}

static OSStatus RCFindItem(const char *username, UInt32 *passwordLength,
                           void **passwordData, SecKeychainItemRef *item)
{
  return SecKeychainFindGenericPassword(NULL, (UInt32)strlen(kRCService),
      kRCService, (UInt32)strlen(username), username, passwordLength,
      passwordData, item);
}

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
  status = SecAccessCreate(CFSTR("Retro Cloud Sync iCloud Account"), trusted,
                           access);

finished:
  if (trusted != NULL) CFRelease(trusted);
  if (daemon != NULL) CFRelease(daemon);
  if (application != NULL) CFRelease(application);
  return status;
}

int RCICloudCredentialsSave(const char *username, const void *password,
                            size_t passwordLength,
                            const char *installedDaemonPath, RCError *error)
{
  SecKeychainItemRef item = NULL;
  SecAccessRef access = NULL;
  OSStatus status;

  if (username == NULL || username[0] == '\0' || password == NULL ||
      passwordLength == 0 || passwordLength > UINT_MAX ||
      installedDaemonPath == NULL || installedDaemonPath[0] == '\0') {
    RCErrorSet(error, kRCParameterError,
               "Invalid iCloud credential parameters");
    return 0;
  }
  status = RCCreateAccess(installedDaemonPath, &access);
  if (status != noErr) {
    RCSetSecurityError(error, status,
                       "Could not create iCloud credential access rules");
    return 0;
  }
  status = RCFindItem(username, NULL, NULL, &item);
  if (status == noErr) {
    status = SecKeychainItemSetAccess(item, access);
    if (status == noErr) {
      status = SecKeychainItemModifyAttributesAndData(item, NULL,
          (UInt32)passwordLength, password);
    }
  } else if (status == errSecItemNotFound) {
    SecKeychainAttribute attributes[3];
    SecKeychainAttributeList attributeList;

    attributes[0].tag = kSecServiceItemAttr;
    attributes[0].length = (UInt32)strlen(kRCService);
    attributes[0].data = (void *)kRCService;
    attributes[1].tag = kSecAccountItemAttr;
    attributes[1].length = (UInt32)strlen(username);
    attributes[1].data = (void *)username;
    attributes[2].tag = kSecLabelItemAttr;
    attributes[2].length = (UInt32)strlen(kRCLabel);
    attributes[2].data = (void *)kRCLabel;
    attributeList.count = 3;
    attributeList.attr = attributes;
    status = SecKeychainItemCreateFromContent(kSecGenericPasswordItemClass,
        &attributeList, (UInt32)passwordLength, password, NULL, access, &item);
  }
  if (item != NULL) CFRelease(item);
  CFRelease(access);
  if (status != noErr) {
    RCSetSecurityError(error, status, "Could not save iCloud credentials");
    return 0;
  }
  return 1;
}

int RCICloudCredentialsCopyPassword(const char *username, char **password,
                                    size_t *passwordLength, RCError *error)
{
  UInt32 keychainLength = 0;
  void *keychainData = NULL;
  OSStatus status;
  char *copy;

  if (password == NULL || passwordLength == NULL || username == NULL ||
      username[0] == '\0') {
    RCErrorSet(error, kRCParameterError,
               "Invalid iCloud credential parameters");
    return 0;
  }
  *password = NULL;
  *passwordLength = 0;
  status = RCFindItem(username, &keychainLength, &keychainData, NULL);
  if (status != noErr) {
    RCSetSecurityError(error, status,
        status == errSecItemNotFound ? "iCloud credentials are not configured" :
                                      "Could not read iCloud credentials");
    return 0;
  }
  copy = (char *)malloc((size_t)keychainLength + 1);
  if (copy == NULL) {
    SecKeychainItemFreeContent(NULL, keychainData);
    RCErrorSet(error, kRCMemoryError,
               "Out of memory reading iCloud credentials");
    return 0;
  }
  if (keychainLength != 0) memcpy(copy, keychainData, keychainLength);
  copy[keychainLength] = '\0';
  SecKeychainItemFreeContent(NULL, keychainData);
  *password = copy;
  *passwordLength = keychainLength;
  return 1;
}

int RCICloudCredentialsExist(const char *username)
{
  SecKeychainItemRef item = NULL;
  OSStatus status;

  if (username == NULL || username[0] == '\0') return 0;
  status = RCFindItem(username, NULL, NULL, &item);
  if (item != NULL) CFRelease(item);
  return status == noErr;
}

int RCICloudCredentialsRefreshAccess(const char *username,
                                     const char *installedDaemonPath,
                                     RCError *error)
{
  SecKeychainItemRef item = NULL;
  SecAccessRef access = NULL;
  OSStatus status;

  if (username == NULL || username[0] == '\0' ||
      installedDaemonPath == NULL || installedDaemonPath[0] == '\0') {
    RCErrorSet(error, kRCParameterError,
               "Invalid iCloud credential parameters");
    return 0;
  }
  status = RCFindItem(username, NULL, NULL, &item);
  if (status != noErr) {
    RCSetSecurityError(error, status, "Could not locate iCloud credentials");
    return 0;
  }
  status = RCCreateAccess(installedDaemonPath, &access);
  if (status == noErr) status = SecKeychainItemSetAccess(item, access);
  if (access != NULL) CFRelease(access);
  CFRelease(item);
  if (status != noErr) {
    RCSetSecurityError(error, status,
                       "Could not update iCloud credential access rules");
    return 0;
  }
  return 1;
}

int RCICloudCredentialsRemove(const char *username, RCError *error)
{
  SecKeychainItemRef item = NULL;
  OSStatus status;

  if (username == NULL || username[0] == '\0') return 1;
  status = RCFindItem(username, NULL, NULL, &item);
  if (status == errSecItemNotFound) return 1;
  if (status == noErr) status = SecKeychainItemDelete(item);
  if (item != NULL) CFRelease(item);
  if (status != noErr) {
    RCSetSecurityError(error, status, "Could not remove iCloud credentials");
    return 0;
  }
  return 1;
}

void RCICloudCredentialsClearPassword(char *password, size_t passwordLength)
{
  volatile unsigned char *bytes = (volatile unsigned char *)password;
  size_t index;

  if (password == NULL) return;
  for (index = 0; index < passwordLength; index++) bytes[index] = 0;
  free(password);
}
