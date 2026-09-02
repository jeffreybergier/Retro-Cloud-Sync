#ifndef RC_CARDDAV_MIRROR_H
#define RC_CARDDAV_MIRROR_H

#include "RCContactStore.h"
#include "RCHTTPClient.h"

typedef void (*RCCardDAVProgressCallback)(const char *message, void *context);

typedef struct {
  const char *serviceURL;
  const char *username;
  const char *password;
  const char *certificatePath;
  const char *allowedHostSuffix;
  RCCardDAVProgressCallback progress;
  void *progressContext;
} RCCardDAVMirrorConfig;

typedef struct {
  long collectionCount;
  long listedResourceCount;
  long downloadedResourceCount;
  long unchangedResourceCount;
} RCCardDAVMirrorResult;

int RCCardDAVMirrorFetch(const RCCardDAVMirrorConfig *config,
                         RCContactStore *store,
                         RCCardDAVMirrorResult *result,
                         RCError *error);

#endif
