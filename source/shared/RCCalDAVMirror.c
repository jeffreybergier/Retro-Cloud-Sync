#include "RCCalDAVMirror.h"
#include <stdlib.h>
#include <string.h>
static const char principalRequest[] =
    "<?xml version=\"1.0\"?><d:propfind "
    "xmlns:d=\"DAV:\"><d:prop><d:current-user-principal/></d:prop></d:propfind>";
static const char homeRequest[] = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\" "
                                  "xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><"
                                  "c:calendar-home-set/></d:prop></d:propfind>";
static void progress(const RCCardDAVMirrorConfig *c, const char *message)
{
  if (c->progress)
    c->progress(message, c->progressContext);
}
int RCCalDAVMirrorFetch(const RCCardDAVMirrorConfig *config, RCCalendarStore *store,
                        RCCardDAVMirrorResult *result, RCError *error)
{
  RCHTTPClientConfig http;
  RCHTTPClient *client = NULL;
  RCDAVCollection *collections = NULL;
  RCDAVResource *resources = NULL;
  size_t count = 0, resourceCount = 0, i, j;
  char *principal = NULL, *home = NULL;
  int success = 0, started = 0;
  RCError local, finishError;
  if (!error)
    error = &local;
  RCErrorClear(error);
  if (!config || !store || !result) {
    RCErrorSet(error, 1, "Calendar mirror configuration is missing");
    return 0;
  }
  memset(result, 0, sizeof(*result));
  memset(&http, 0, sizeof(http));
  http.username = config->username;
  http.password = config->password;
  http.certificatePath = config->certificatePath;
  http.allowedHostSuffix = config->allowedHostSuffix;
  http.userAgent = "RetroCloudSync-CalDAV/0.1";
  client = RCHTTPClientCreate(&http, error);
  if (!client || !RCCalendarStoreBeginRun(store, error))
    goto done;
  started = 1;
  progress(config, "Discovering calendar principal and home");
  if (!RCDAVDiscoverHref(client, config->serviceURL, principalRequest,
                         "current-user-principal", "DAV:", &principal, error) ||
      !RCDAVDiscoverHref(client, principal, homeRequest, "calendar-home-set",
                         "urn:ietf:params:xml:ns:caldav", &home, error) ||
      !RCDAVListCollections(client, home, "calendar", "urn:ietf:params:xml:ns:caldav",
                            &collections, &count, error))
    goto done;
  result->collectionCount = (long)count;
  for (i = 0; i < count; i++) {
    long long calendar;
    if (!RCCalendarStoreCollection(store, &collections[i], &calendar, error) ||
        !RCDAVListResources(client, collections[i].url, &resources, &resourceCount,
                            error))
      goto done;
    result->listedResourceCount += (long)resourceCount;
    for (j = 0; j < resourceCount; j++) {
      int current;
      RCHTTPResponse response;
      if (!RCCalendarStoreSeen(store, calendar, resources[j].url, resources[j].etag,
                               &current, error))
        goto done;
      if (current) {
        result->unchangedResourceCount++;
        continue;
      }
      progress(config, "Downloading changed calendar resource");
      RCHTTPResponseInit(&response);
      if (!RCHTTPClientRequest(client, "GET", resources[j].url, NULL, NULL, NULL, 0,
                               &response, error)) {
        RCHTTPResponseClear(&response);
        goto done;
      }
      if (response.statusCode != 200) {
        RCErrorSet(error, (int)response.statusCode, "Calendar GET returned HTTP %ld",
                   response.statusCode);
        RCHTTPResponseClear(&response);
        goto done;
      }
      if (!RCCalendarStoreSave(store, calendar, resources[j].url,
                               response.etag ? response.etag : resources[j].etag,
                               response.body, response.bodyLength, error)) {
        RCHTTPResponseClear(&response);
        goto done;
      }
      RCHTTPResponseClear(&response);
      result->downloadedResourceCount++;
    }
    RCDAVFreeResources(resources, resourceCount);
    resources = NULL;
    resourceCount = 0;
  }
  success = 1;
done:
  if (started) {
    RCErrorClear(&finishError);
    if (!RCCalendarStoreFinishRun(store, success, success ? NULL : error->message,
                                  &finishError) &&
        success) {
      *error = finishError;
      success = 0;
    }
  }
  RCDAVFreeResources(resources, resourceCount);
  RCDAVFreeCollections(collections, count);
  free(principal);
  free(home);
  RCHTTPClientDestroy(client);
  return success;
}
