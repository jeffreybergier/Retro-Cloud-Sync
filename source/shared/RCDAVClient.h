#ifndef RC_DAV_CLIENT_H
#define RC_DAV_CLIENT_H
#include "RCHTTPClient.h"
typedef struct {
  char *url;
  char *displayName;
  char *description;
  char *color;
  char *syncToken;
  int supportsSync;
} RCDAVCollection;
typedef struct {
  char *url;
  char *etag;
} RCDAVResource;
/* In a sync report only, a NULL ETag denotes an explicit remote deletion. */
typedef int (*RCDAVSyncCallback)(const RCDAVResource *, size_t, void *, RCError *);
enum { RCDAVSyncFailed = 0, RCDAVSyncComplete = 1, RCDAVSyncFallback = 2 };
/* Streams bounded pages; output token is set only after complete success.
   NULL input token requests an initial complete inventory. The caller must
   roll back callback mutations on failure/fallback before doing a full scan. */
int RCDAVSyncCollection(RCHTTPClient *, const char *, const char *,
                        RCDAVSyncCallback, void *, char **, RCError *);
int RCDAVDiscoverHref(RCHTTPClient *, const char *, const char *, const char *,
                      const char *, char **, RCError *);
int RCDAVListCollections(RCHTTPClient *, const char *, const char *, const char *,
                         RCDAVCollection **, size_t *, RCError *);
int RCDAVListResources(RCHTTPClient *, const char *, RCDAVResource **, size_t *,
                       RCError *);
/* Calendar-query inventory; start is a validated UTC YYYYMMDDTHHMMSSZ value.
   No end bound: ongoing recurring series and all future events are included. */
int RCDAVListCalendarResourcesSince(RCHTTPClient *, const char *, const char *,
                                    RCDAVResource **, size_t *, RCError *);
void RCDAVFreeCollections(RCDAVCollection *, size_t);
void RCDAVFreeResources(RCDAVResource *, size_t);
#endif
