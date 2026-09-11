#ifndef RC_HTTP_CLIENT_H
#define RC_HTTP_CLIENT_H

#include "RCError.h"

#include <stddef.h>

typedef struct RCHTTPClient RCHTTPClient;

typedef struct {
  const char *username;
  const char *password;
  const char *certificatePath;
  const char *allowedHostSuffix;
  const char *userAgent;
  size_t maximumResponseBytes;
} RCHTTPClientConfig;

typedef struct {
  long statusCode;
  char *effectiveURL;
  char *location;
  char *etag;
  char *contentType;
  unsigned char *body;
  size_t bodyLength;
} RCHTTPResponse;

RCHTTPClient *RCHTTPClientCreate(const RCHTTPClientConfig *config,
                                 RCError *error);
void RCHTTPClientDestroy(RCHTTPClient *client);

void RCHTTPResponseInit(RCHTTPResponse *response);
void RCHTTPResponseClear(RCHTTPResponse *response);

int RCHTTPClientRequest(RCHTTPClient *client,
                        const char *method,
                        const char *url,
                        const char *depth,
                        const char *contentType,
                        const void *body,
                        size_t bodyLength,
                        RCHTTPResponse *response,
                        RCError *error);

int RCURLResolve(const char *baseURL, const char *href, char **resolvedURL,
                 RCError *error);

/* Conditional mutations never follow redirects: the journal owns a fixed href.
   PUT requires exactly one condition; DELETE requires a strong If-Match.
   MKCALENDAR requires If-None-Match to prevent replacing a collection. */
int RCHTTPClientConditionalRequest(RCHTTPClient *, const char *method,
    const char *url, const char *contentType, const void *body, size_t bodyLength,
    const char *ifMatch, int ifNoneMatch, RCHTTPResponse *, RCError *);

/* MOVE uses a strong source If-Match and Overwrite: F; it never follows redirects. */
int RCHTTPClientMove(RCHTTPClient *,const char *,const char *,const char *,RCHTTPResponse *,RCError *);
#endif
