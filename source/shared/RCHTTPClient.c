#include "RCHTTPClient.h"

#include <AltivecCore/curl/curl.h>

#include <ctype.h>
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

int RCHTTPClientRequest(RCHTTPClient *client, const char *method,
                        const char *url, const char *depth,
                        const char *contentType, const void *body,
                        size_t bodyLength, RCHTTPResponse *response,
                        RCError *error)
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
    if (contentType != NULL) {
      snprintf(contentTypeHeader, sizeof(contentTypeHeader),
               "Content-Type: %.140s", contentType);
      headers = curl_slist_append(headers, contentTypeHeader);
    }
    headers = curl_slist_append(headers, "Accept: application/xml, text/vcard, text/calendar, */*");

    curl_easy_setopt(curl, CURLOPT_URL, currentURL);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(curl, CURLOPT_USERNAME, client->username);
    curl_easy_setopt(curl, CURLOPT_PASSWORD, client->password);
    curl_easy_setopt(curl, CURLOPT_HTTPAUTH, (long)CURLAUTH_BASIC);
    curl_easy_setopt(curl, CURLOPT_CAINFO, client->certificatePath);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, (long)CURLPROTO_HTTPS);
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, (long)CURLPROTO_HTTPS);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, client->userAgent);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, RCReceiveBody);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &writeContext);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, RCReceiveHeader);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, response);
    if (body != NULL || bodyLength != 0) {
      curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
      curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)bodyLength);
    }

    curlResult = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response->statusCode);
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effectiveURL);
    response->effectiveURL = RCCopyString(effectiveURL != NULL ?
                                          effectiveURL : currentURL);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (curlResult != CURLE_OK) {
      RCErrorSet(error, (int)curlResult,
                 writeContext.exceededLimit ? "HTTP response exceeded size limit" :
                 "DAV request failed: %s", curl_easy_strerror(curlResult));
      free(currentURL);
      return 0;
    }
    if (response->statusCode == 301 || response->statusCode == 302 ||
        response->statusCode == 307 || response->statusCode == 308) {
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
  }
  free(currentURL);
  RCErrorSet(error, 1, "Too many DAV redirects");
  return 0;
}
