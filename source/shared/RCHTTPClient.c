#include "RCHTTPClient.h"
#include "RCWriteJournal.h"

#ifdef __APPLE__
#include <AltivecCore/curl/curl.h>
#else
#include <curl/curl.h>
#endif

#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define RC_HTTP_REDIRECT_LIMIT 5
#define RC_HTTP_DEFAULT_RESPONSE_LIMIT (32U * 1024U * 1024U)

struct RCHTTPClient {
  char *username;
  char *password;
  char *certificatePath;
  char *allowedHostSuffix;
  char *userAgent;
  size_t maximumResponseBytes;
};

typedef struct {
  RCHTTPResponse *response;
  size_t maximumBytes;
  int exceededLimit;
} RCWriteContext;

static int RCCancelTransfer(void *context, curl_off_t totalDownload,
    curl_off_t downloaded, curl_off_t totalUpload, curl_off_t uploaded)
{
  (void)context; (void)totalDownload; (void)downloaded;
  (void)totalUpload; (void)uploaded;
  return RCStopRequested != 0;
}

static char *RCCopyString(const char *string)
{
  size_t length;
  char *copy;

  if (string == NULL) {
    return NULL;
  }
  length = strlen(string);
  copy = (char *)malloc(length + 1);
  if (copy != NULL) {
    memcpy(copy, string, length + 1);
  }
  return copy;
}

static char *RCCopyHeaderValue(const char *value, size_t length)
{
  char *copy;

  while (length > 0 && (*value == ' ' || *value == '\t')) {
    value++;
    length--;
  }
  while (length > 0 && (value[length - 1] == '\r' ||
                         value[length - 1] == '\n' ||
                         value[length - 1] == ' ' ||
                         value[length - 1] == '\t')) {
    length--;
  }
  copy = (char *)malloc(length + 1);
  if (copy != NULL) {
    memcpy(copy, value, length);
    copy[length] = '\0';
  }
  return copy;
}

static void RCReplaceString(char **destination, char *replacement)
{
  free(*destination);
  *destination = replacement;
}

static size_t RCReceiveBody(char *bytes, size_t size, size_t count,
                            void *contextPointer)
{
  RCWriteContext *context = (RCWriteContext *)contextPointer;
  size_t byteCount = size * count;
  size_t newLength;
  unsigned char *newBody;

  if (size != 0 && byteCount / size != count) {
    context->exceededLimit = 1;
    return 0;
  }
  if (byteCount > context->maximumBytes - context->response->bodyLength) {
    context->exceededLimit = 1;
    return 0;
  }
  newLength = context->response->bodyLength + byteCount;
  newBody = (unsigned char *)realloc(context->response->body, newLength + 1);
  if (newBody == NULL) {
    return 0;
  }
  memcpy(newBody + context->response->bodyLength, bytes, byteCount);
  newBody[newLength] = '\0';
  context->response->body = newBody;
  context->response->bodyLength = newLength;
  return byteCount;
}

static size_t RCReceiveHeader(char *bytes, size_t size, size_t count,
                              void *responsePointer)
{
  RCHTTPResponse *response = (RCHTTPResponse *)responsePointer;
  size_t byteCount = size * count;
  const char *colon = (const char *)memchr(bytes, ':', byteCount);
  size_t nameLength;
  char *value;

  if (colon == NULL) {
    return byteCount;
  }
  nameLength = (size_t)(colon - bytes);
  value = RCCopyHeaderValue(colon + 1, byteCount - nameLength - 1);
  if (value == NULL) {
    return 0;
  }
  if (nameLength == 8 && strncasecmp(bytes, "Location", 8) == 0) {
    RCReplaceString(&response->location, value);
  } else if (nameLength == 4 && strncasecmp(bytes, "ETag", 4) == 0) {
    RCReplaceString(&response->etag, value);
  } else if (nameLength == 12 &&
             strncasecmp(bytes, "Content-Type", 12) == 0) {
    RCReplaceString(&response->contentType, value);
  } else {
    free(value);
  }
  return byteCount;
}

static int RCHostHasSuffix(const char *host, const char *suffix)
{
  size_t hostLength;
  size_t suffixLength;

  if (suffix == NULL || suffix[0] == '\0') {
    return 1;
  }
  hostLength = strlen(host);
  suffixLength = strlen(suffix);
  if (hostLength < suffixLength) {
    return 0;
  }
  return strcasecmp(host + hostLength - suffixLength, suffix) == 0;
}

static int RCValidateDestination(const char *url, const char *hostSuffix,
                                 RCError *error)
{
  CURLU *parsed = curl_url();
  char *scheme = NULL;
  char *host = NULL;
  int valid = 0;

  if (parsed == NULL ||
      curl_url_set(parsed, CURLUPART_URL, url, CURLU_DISALLOW_USER) != CURLUE_OK ||
      curl_url_get(parsed, CURLUPART_SCHEME, &scheme, 0) != CURLUE_OK ||
      curl_url_get(parsed, CURLUPART_HOST, &host, 0) != CURLUE_OK) {
    RCErrorSet(error, 1, "Invalid HTTPS URL");
    goto finished;
  }
  if (strcasecmp(scheme, "https") != 0) {
    RCErrorSet(error, 1, "Refusing non-HTTPS DAV destination");
    goto finished;
  }
  if (!RCHostHasSuffix(host, hostSuffix)) {
    RCErrorSet(error, 1, "Refusing DAV credentials for unexpected host");
    goto finished;
  }
  valid = 1;

finished:
  curl_free(scheme);
  curl_free(host);
  if (parsed != NULL) {
    curl_url_cleanup(parsed);
  }
  return valid;
}

void RCHTTPResponseInit(RCHTTPResponse *response)
{
  memset(response, 0, sizeof(*response));
}

void RCHTTPResponseClear(RCHTTPResponse *response)
{
  if (response == NULL) {
    return;
  }
  free(response->effectiveURL);
  free(response->location);
  free(response->etag);
  free(response->contentType);
  free(response->body);
  RCHTTPResponseInit(response);
}

RCHTTPClient *RCHTTPClientCreate(const RCHTTPClientConfig *config,
                                 RCError *error)
{
  RCHTTPClient *client;
  RCError localError;

  if (error == NULL) error = &localError;
  RCErrorClear(error);
  if (config == NULL || config->username == NULL || config->password == NULL ||
      config->certificatePath == NULL) {
    RCErrorSet(error, 1, "HTTP client configuration is incomplete");
    return NULL;
  }
  client = (RCHTTPClient *)calloc(1, sizeof(*client));
  if (client == NULL) {
    RCErrorSet(error, 1, "Out of memory creating HTTP client");
    return NULL;
  }
  client->username = RCCopyString(config->username);
  client->password = RCCopyString(config->password);
  client->certificatePath = RCCopyString(config->certificatePath);
  client->allowedHostSuffix = RCCopyString(config->allowedHostSuffix);
  client->userAgent = RCCopyString(config->userAgent != NULL ?
                                   config->userAgent : "RetroCloudSync/0.1");
  client->maximumResponseBytes = config->maximumResponseBytes != 0 ?
      config->maximumResponseBytes : RC_HTTP_DEFAULT_RESPONSE_LIMIT;
  if (client->username == NULL || client->password == NULL ||
      client->certificatePath == NULL || client->userAgent == NULL) {
    RCHTTPClientDestroy(client);
    RCErrorSet(error, 1, "Out of memory copying HTTP configuration");
    return NULL;
  }
  return client;
}

void RCHTTPClientDestroy(RCHTTPClient *client)
{
  if (client == NULL) {
    return;
  }
  if (client->password != NULL) {
    memset(client->password, 0, strlen(client->password));
  }
  free(client->username);
  free(client->password);
  free(client->certificatePath);
  free(client->allowedHostSuffix);
  free(client->userAgent);
  free(client);
}

int RCURLResolve(const char *baseURL, const char *href, char **resolvedURL,
                 RCError *error)
{
  CURLU *url = curl_url();
  char *curlResult = NULL;
  RCError localError;

  if (error == NULL) error = &localError;
  RCErrorClear(error);
  *resolvedURL = NULL;
  if (url == NULL ||
      curl_url_set(url, CURLUPART_URL, baseURL, CURLU_DISALLOW_USER) != CURLUE_OK ||
      curl_url_set(url, CURLUPART_URL, href, 0) != CURLUE_OK ||
      curl_url_get(url, CURLUPART_URL, &curlResult, 0) != CURLUE_OK) {
    if (url != NULL) {
      curl_url_cleanup(url);
    }
    RCErrorSet(error, 1, "Could not resolve DAV href");
    return 0;
  }
  *resolvedURL = RCCopyString(curlResult);
  curl_free(curlResult);
  curl_url_cleanup(url);
  if (*resolvedURL == NULL) {
    RCErrorSet(error, 1, "Out of memory resolving DAV href");
    return 0;
  }
  return 1;
}

static int RCRequest(RCHTTPClient *client, const char *method,
                        const char *url, const char *depth,
                        const char *contentType, const void *body,
                        size_t bodyLength, RCHTTPResponse *response,
                        RCError *error, const char *ifMatch, int ifNoneMatch, const char *destination)
{
  char *currentURL = RCCopyString(url);
  int redirectCount;
  RCError localError;

  if (error == NULL) error = &localError;
  RCErrorClear(error);
  if (currentURL == NULL) {
    RCErrorSet(error, 1, "Out of memory copying request URL");
    return 0;
  }
  for (redirectCount = 0; redirectCount <= RC_HTTP_REDIRECT_LIMIT;
       redirectCount++) {
    CURL *curl;
    CURLcode curlResult;
    struct curl_slist *headers = NULL;
    RCWriteContext writeContext;
    char depthHeader[32];
    char contentTypeHeader[160];
    char *effectiveURL = NULL;

    if (!RCValidateDestination(currentURL, client->allowedHostSuffix, error)) {
      free(currentURL);
      return 0;
    }
    RCHTTPResponseClear(response);
    curl = curl_easy_init();
    if (curl == NULL) {
      free(currentURL);
      RCErrorSet(error, 1, "Could not create libcurl handle");
      return 0;
    }
    writeContext.response = response;
    writeContext.maximumBytes = client->maximumResponseBytes;
    writeContext.exceededLimit = 0;
    if (depth != NULL) {
      snprintf(depthHeader, sizeof(depthHeader), "Depth: %s", depth);
      headers = curl_slist_append(headers, depthHeader);
    }
    if (destination) {
      size_t size=strlen(destination)+14; char *header=malloc(size);
      if(!header) { curl_slist_free_all(headers); curl_easy_cleanup(curl); free(currentURL); RCErrorSet(error,1,"Out of memory setting MOVE destination"); return 0; }
      snprintf(header,size,"Destination: %s",destination);
      headers=curl_slist_append(headers,header); free(header);
      headers=curl_slist_append(headers,"Overwrite: F");
    }
    if (contentType != NULL) {
      snprintf(contentTypeHeader, sizeof(contentTypeHeader),
               "Content-Type: %.140s", contentType);
      headers = curl_slist_append(headers, contentTypeHeader);
    }
    if (ifMatch != NULL) {
      size_t length = strlen(ifMatch) + 11;
      char *header = (char *)malloc(length);
      struct curl_slist *added;
      if (header == NULL) {
        curl_slist_free_all(headers); curl_easy_cleanup(curl); free(currentURL);
        RCErrorSet(error, 1, "Out of memory setting write precondition"); return 0;
      }
      snprintf(header, length, "If-Match: %s", ifMatch);
      added = curl_slist_append(headers, header);
      free(header);
      if (added == NULL) {
        curl_slist_free_all(headers); curl_easy_cleanup(curl); free(currentURL);
        RCErrorSet(error, 1, "Could not set write precondition"); return 0;
      }
      headers = added;
    } else if (ifNoneMatch) {
      struct curl_slist *added = curl_slist_append(headers, "If-None-Match: *");
      if (added == NULL) {
        curl_slist_free_all(headers); curl_easy_cleanup(curl); free(currentURL);
        RCErrorSet(error, 1, "Could not set create precondition"); return 0;
      }
      headers = added;
    }
    {
      struct curl_slist *added = curl_slist_append(headers,
          "Accept: application/xml, text/vcard, text/calendar, */*");
      if (added == NULL) {
        curl_slist_free_all(headers); curl_easy_cleanup(curl); free(currentURL);
        RCErrorSet(error, 1, "Could not set DAV request headers"); return 0;
      }
      headers = added;
    }

    /* Configuration failure must never turn a conditional write into a
       request with a different method, body or trust policy. */
#define RC_SET_OPTION(option, value) do { \
    curlResult = curl_easy_setopt(curl, (option), (value)); \
    if (curlResult != CURLE_OK) goto request_setup_failed; \
  } while (0)
    RC_SET_OPTION(CURLOPT_URL, currentURL);
    RC_SET_OPTION(CURLOPT_CUSTOMREQUEST, method);
    RC_SET_OPTION(CURLOPT_USERNAME, client->username);
    RC_SET_OPTION(CURLOPT_PASSWORD, client->password);
    RC_SET_OPTION(CURLOPT_HTTPAUTH, (long)CURLAUTH_BASIC);
    RC_SET_OPTION(CURLOPT_CAINFO, client->certificatePath);
    RC_SET_OPTION(CURLOPT_SSL_VERIFYPEER, 1L);
    RC_SET_OPTION(CURLOPT_SSL_VERIFYHOST, 2L);
    RC_SET_OPTION(CURLOPT_PROTOCOLS, (long)CURLPROTO_HTTPS);
    RC_SET_OPTION(CURLOPT_REDIR_PROTOCOLS, (long)CURLPROTO_HTTPS);
    RC_SET_OPTION(CURLOPT_FOLLOWLOCATION, 0L);
    RC_SET_OPTION(CURLOPT_NOSIGNAL, 1L);
    RC_SET_OPTION(CURLOPT_NOPROGRESS, 0L);
    RC_SET_OPTION(CURLOPT_XFERINFOFUNCTION, RCCancelTransfer);
    RC_SET_OPTION(CURLOPT_CONNECTTIMEOUT, 20L);
    RC_SET_OPTION(CURLOPT_TIMEOUT, 120L);
    RC_SET_OPTION(CURLOPT_USERAGENT, client->userAgent);
    RC_SET_OPTION(CURLOPT_HTTPHEADER, headers);
    RC_SET_OPTION(CURLOPT_WRITEFUNCTION, RCReceiveBody);
    RC_SET_OPTION(CURLOPT_WRITEDATA, &writeContext);
    RC_SET_OPTION(CURLOPT_HEADERFUNCTION, RCReceiveHeader);
    RC_SET_OPTION(CURLOPT_HEADERDATA, response);
    if (body != NULL || bodyLength != 0) {
      RC_SET_OPTION(CURLOPT_POSTFIELDS, body);
      RC_SET_OPTION(CURLOPT_POSTFIELDSIZE, (long)bodyLength);
    }

#undef RC_SET_OPTION

    curlResult = RCStopRequested ? CURLE_ABORTED_BY_CALLBACK : curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response->statusCode);
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effectiveURL);
    response->effectiveURL = RCCopyString(effectiveURL != NULL ?
                                          effectiveURL : currentURL);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (RCCheckCancellation(error)) { free(currentURL); return 0; }
    if (curlResult != CURLE_OK) {
      RCErrorSet(error, (int)curlResult,
                 writeContext.exceededLimit ? "HTTP response exceeded size limit" :
                 "DAV request failed: %s", curl_easy_strerror(curlResult));
      free(currentURL);
      return 0;
    }
    if (ifMatch == NULL && !ifNoneMatch &&
        (response->statusCode == 301 || response->statusCode == 302 ||
         response->statusCode == 307 || response->statusCode == 308)) {
      char *redirectURL = NULL;
      if (response->location == NULL || redirectCount == RC_HTTP_REDIRECT_LIMIT ||
          !RCURLResolve(response->effectiveURL, response->location,
                        &redirectURL, error)) {
        if (error->code == 0) {
          RCErrorSet(error, 1, "Invalid or excessive DAV redirects");
        }
        free(currentURL);
        return 0;
      }
      free(currentURL);
      currentURL = redirectURL;
      continue;
    }
    free(currentURL);
    return 1;

request_setup_failed:
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    free(currentURL);
    RCErrorSet(error, (int)curlResult, "Could not configure DAV request: %s",
               curl_easy_strerror(curlResult));
    return 0;
  }
  free(currentURL);
  RCErrorSet(error, 1, "Too many DAV redirects");
  return 0;
}

int RCHTTPClientRequest(RCHTTPClient *client, const char *method, const char *url,
    const char *depth, const char *contentType, const void *body, size_t length,
    RCHTTPResponse *response, RCError *error)
{
  /* Do not allow a future caller to accidentally bypass conditional writes. */
  if (strcasecmp(method, "PUT") == 0 || strcasecmp(method, "DELETE") == 0 || strcasecmp(method,"MOVE") == 0 || strcasecmp(method,"MKCALENDAR") == 0) {
    RCErrorSet(error, 1, "DAV mutations require a conditional request"); return 0;
  }
  return RCRequest(client, method, url, depth, contentType, body, length,
                   response, error, NULL, 0, NULL);
}

int RCHTTPClientConditionalRequest(RCHTTPClient *client, const char *method,
    const char *url, const char *type, const void *body, size_t length,
    const char *ifMatch, int ifNoneMatch, RCHTTPResponse *response, RCError *error)
{
  if (method == NULL || length > LONG_MAX ||
      (strcmp(method,"PUT") && strcmp(method,"DELETE") && strcmp(method,"MKCALENDAR")) ||
      (ifMatch ? (!RCWriteETagIsStrong(ifMatch) || ifNoneMatch) : !ifNoneMatch) ||
      (!strcmp(method,"MKCALENDAR") && (ifMatch || !ifNoneMatch)) ||
      (!strcmp(method,"DELETE") && (!ifMatch || body || length)) ||
      ((!strcmp(method,"PUT") || !strcmp(method,"MKCALENDAR")) && (!body || !length))) {
    RCErrorSet(error, 1, "Invalid conditional DAV mutation"); return 0;
  }
  return RCRequest(client, method, url, NULL, type, body, length,
                   response, error, ifMatch, ifNoneMatch, NULL);
}

int RCHTTPClientMove(RCHTTPClient *client,const char *source,const char *destination,const char *etag,RCHTTPResponse *response,RCError *error)
{
  if(!RCWriteETagIsStrong(etag) || !source || !destination || strchr(destination,'\r') || strchr(destination,'\n') ||
      !RCValidateDestination(destination,client->allowedHostSuffix,error)) { RCErrorSet(error,1,"Invalid conditional MOVE"); return 0; }
  return RCRequest(client,"MOVE",source,NULL,NULL,NULL,0,response,error,etag,0,destination);
}
