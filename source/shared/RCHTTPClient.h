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

#endif
