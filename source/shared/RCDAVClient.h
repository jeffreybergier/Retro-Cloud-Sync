#ifndef RC_DAV_CLIENT_H
#define RC_DAV_CLIENT_H
#include "RCHTTPClient.h"
typedef struct {
  char *url;
  char *displayName;
  char *description;
  char *color;
} RCDAVCollection;
typedef struct {
  char *url;
  char *etag;
} RCDAVResource;
int RCDAVDiscoverHref(RCHTTPClient *, const char *, const char *, const char *,
                      const char *, char **, RCError *);
int RCDAVListCollections(RCHTTPClient *, const char *, const char *, const char *,
                         RCDAVCollection **, size_t *, RCError *);
int RCDAVListResources(RCHTTPClient *, const char *, RCDAVResource **, size_t *,
                       RCError *);
void RCDAVFreeCollections(RCDAVCollection *, size_t);
void RCDAVFreeResources(RCDAVResource *, size_t);
#endif
