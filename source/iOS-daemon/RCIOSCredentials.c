#include "RCICloudCredentials.h"
#include <Security/Security.h>
#include <stdlib.h>
#include <string.h>
static CFMutableDictionaryRef Query(const char *username,RCError *error) {
  if(!username || !*username) { RCErrorSet(error,-50,"Invalid account name"); return NULL; }
  CFStringRef account=CFStringCreateWithCString(NULL,username,kCFStringEncodingUTF8);
  if(!account) { RCErrorSet(error,-50,"Invalid account encoding"); return NULL; }
  CFMutableDictionaryRef q=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(q,kSecClass,kSecClassGenericPassword);
  CFDictionarySetValue(q,kSecAttrService,CFSTR("com.altivecintelligence.rcloud.icloud"));
  CFDictionarySetValue(q,kSecAttrAccount,account); CFRelease(account); return q;
}
static int Result(OSStatus status,RCError *error) {
  if(status!=errSecSuccess) RCErrorSet(error,(int)status,"Account Keychain operation failed (%ld)",(long)status);
  return status==errSecSuccess;
}
int RCICloudCredentialsSave(const char *username,const void *password,size_t length,const char *path,RCError *error) {
  (void)path; RCErrorClear(error);
  if(!password || !length || length>4096) { RCErrorSet(error,-50,"Invalid password length"); return 0; }
  CFMutableDictionaryRef query=Query(username,error); if(!query) return 0;
  CFDataRef data=CFDataCreate(NULL,password,length);
  CFMutableDictionaryRef update=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(update,kSecValueData,data);
  CFDictionarySetValue(update,kSecAttrAccessible,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
  OSStatus status=SecItemUpdate(query,update);
  if(status==errSecItemNotFound) {
    CFDictionarySetValue(query,kSecValueData,data);
    CFDictionarySetValue(query,kSecAttrAccessible,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
    status=SecItemAdd(query,NULL);
  }
  CFRelease(update); CFRelease(data); CFRelease(query); return Result(status,error);
}
int RCICloudCredentialsCopyPassword(const char *username,char **password,size_t *length,RCError *error) {
  RCErrorClear(error); if(!password || !length) return Result(errSecParam,error);
  *password=NULL; *length=0; CFMutableDictionaryRef query=Query(username,error); if(!query) return 0;
  CFDictionarySetValue(query,kSecReturnData,kCFBooleanTrue);
  CFTypeRef result=NULL; OSStatus status=SecItemCopyMatching(query,&result); CFRelease(query);
  if(status!=errSecSuccess) return Result(status,error);
  if(!result || CFGetTypeID(result)!=CFDataGetTypeID() || CFDataGetLength(result)<=0 || CFDataGetLength(result)>4096) {
    if(result) CFRelease(result); return Result(errSecDecode,error);
  }
  *length=CFDataGetLength(result); *password=calloc(*length+1,1);
  if(*password) memcpy(*password,CFDataGetBytePtr(result),*length);
  CFRelease(result); if(!*password) { *length=0; return Result(errSecAllocate,error); } return 1;
}
int RCICloudCredentialsCopyUsername(const char *username,char **saved,RCError *error) {
  RCErrorClear(error);
  if(!saved) return Result(errSecParam,error); *saved=NULL;
  CFMutableDictionaryRef query=Query(username,error); if(!query) return 0;
  OSStatus status=SecItemCopyMatching(query,NULL); CFRelease(query);
  if(status!=errSecSuccess) return Result(status,error);
  *saved=strdup(username); return *saved ? 1 : Result(errSecAllocate,error);
}
int RCICloudCredentialsRemove(const char *username,RCError *error) {
  RCErrorClear(error);
  CFMutableDictionaryRef query=Query(username,error); if(!query) return 0;
  OSStatus status=SecItemDelete(query); CFRelease(query);
  return Result(status==errSecItemNotFound ? errSecSuccess : status,error);
}
void RCICloudCredentialsClearPassword(char *password,size_t length) {
  if(password) { volatile unsigned char *p=(volatile unsigned char *)password; while(length--) *p++=0; free(password); }
}
