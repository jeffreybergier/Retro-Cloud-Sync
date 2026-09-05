#include "RCCardDAVMirror.h"

#include "RCVCard.h"
#include "RCDAVClient.h"

#include <libxml/parser.h>
#include <libxml/tree.h>

#include <stdlib.h>
#include <string.h>
#include <strings.h>

static const char kDAVNamespace[] = "DAV:";
static const char kCardDAVNamespace[] = "urn:ietf:params:xml:ns:carddav";

static const char kPrincipalRequest[] =
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
  "<d:propfind xmlns:d=\"DAV:\"><d:prop>"
  "<d:current-user-principal/>"
  "</d:prop></d:propfind>";

static const char kHomeRequest[] =
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
  "<d:propfind xmlns:d=\"DAV:\" "
  "xmlns:c=\"urn:ietf:params:xml:ns:carddav\"><d:prop>"
  "<c:addressbook-home-set/>"
  "</d:prop></d:propfind>";

static void RCProgress(const RCCardDAVMirrorConfig *config,
                       const char *message)
{
  if (config->progress != NULL) {
    config->progress(message, config->progressContext);
  }
}

static int RCFetchCollection(const RCCardDAVMirrorConfig *config,
                             RCHTTPClient *client, RCContactStore *store,
                             const RCDAVCollection *collection,
                             long long runIdentifier,
                             RCCardDAVMirrorResult *result, RCError *error)
{
  RCDAVResource *resources = NULL;
  size_t resourceCount = 0;
  size_t index;
  long long collectionIdentifier;
  int success = 0;

  RCProgress(config, "Listing contacts");
  if (!RCContactStoreGetCollection(store, collection->url,
                                   collection->displayName,
                                   &collectionIdentifier, error) ||
      !RCDAVListResources(client, collection->url, &resources, &resourceCount,
                       error)) goto finished;
  result->listedResourceCount += (long)resourceCount;
  for (index = 0; index < resourceCount; index++) {
    int current;
    if (!RCContactStoreResourceIsCurrent(store, collectionIdentifier,
        resources[index].url, resources[index].etag, &current, error))
      goto finished;
    if (current) {
      if (!RCContactStoreMarkSeen(store, collectionIdentifier,
          resources[index].url, runIdentifier, error)) goto finished;
      result->unchangedResourceCount++;
    } else {
      RCHTTPResponse response;
      RCVCardDocument document;
      const char *etag;
      RCHTTPResponseInit(&response);
      RCVCardDocumentInit(&document);
      RCProgress(config, "Downloading changed contact");
      if (!RCHTTPClientRequest(client, "GET", resources[index].url, NULL,
          NULL, NULL, 0, &response, error)) {
        RCHTTPResponseClear(&response);
        goto finished;
      }
      if (response.statusCode != 200) {
        RCErrorSet(error, (int)response.statusCode,
                   "Contact GET returned HTTP %ld", response.statusCode);
        RCHTTPResponseClear(&response);
        goto finished;
      }
      if (!RCVCardParse(response.body, response.bodyLength, &document, error)) {
        RCHTTPResponseClear(&response);
        goto finished;
      }
      etag = response.etag != NULL ? response.etag : resources[index].etag;
      if (!RCContactStoreSaveVCard(store, collectionIdentifier, runIdentifier,
          resources[index].url, etag, response.body, response.bodyLength,
          &document, error)) {
        RCVCardDocumentClear(&document);
        RCHTTPResponseClear(&response);
        goto finished;
      }
      result->downloadedResourceCount++;
      RCVCardDocumentClear(&document);
      RCHTTPResponseClear(&response);
    }
  }
  if (!RCContactStoreFinishCollection(store, collectionIdentifier,
                                      runIdentifier, error)) goto finished;
  success = 1;

finished:
  RCDAVFreeResources(resources, resourceCount);
  return success;
}

int RCCardDAVMirrorFetch(const RCCardDAVMirrorConfig *config,
                         RCContactStore *store, RCCardDAVMirrorResult *result,
                         RCError *error)
{
  RCHTTPClientConfig httpConfig;
  RCHTTPClient *client = NULL;
  char *principalURL = NULL;
  char *homeURL = NULL;
  RCDAVCollection *collections = NULL;
  size_t collectionCount = 0;
  size_t index;
  long long runIdentifier = 0;
  int runStarted = 0;
  int success = 0;
  RCError finishError;
  RCError localError;

  if (error == NULL) error = &localError;
  RCErrorClear(error);
  if (result == NULL) {
    RCErrorSet(error, 1, "CardDAV mirror result is missing");
    return 0;
  }
  memset(result, 0, sizeof(*result));
  if (config == NULL || store == NULL || config->serviceURL == NULL ||
      config->username == NULL || config->password == NULL ||
      config->certificatePath == NULL) {
    RCErrorSet(error, 1, "CardDAV mirror configuration is incomplete");
    return 0;
  }
  memset(&httpConfig, 0, sizeof(httpConfig));
  httpConfig.username = config->username;
  httpConfig.password = config->password;
  httpConfig.certificatePath = config->certificatePath;
  httpConfig.allowedHostSuffix = config->allowedHostSuffix;
  httpConfig.userAgent = "RetroCloudSync-CardDAV/0.1";
  client = RCHTTPClientCreate(&httpConfig, error);
  if (client == NULL || !RCContactStoreBeginRun(store, &runIdentifier, error))
    goto finished;
  runStarted = 1;
  RCProgress(config, "Discovering CardDAV principal");
  if (!RCDAVDiscoverHref(client, config->serviceURL, kPrincipalRequest,
      "current-user-principal", kDAVNamespace, &principalURL, error))
    goto finished;
  RCProgress(config, "Discovering address-book home");
  if (!RCDAVDiscoverHref(client, principalURL, kHomeRequest,
      "addressbook-home-set", kCardDAVNamespace, &homeURL, error))
    goto finished;
  RCProgress(config, "Discovering address books");
  if (!RCDAVListCollections(client, homeURL, "addressbook", kCardDAVNamespace, &collections, &collectionCount,
                         error)) goto finished;
  if (collectionCount == 0) {
    RCErrorSet(error, 1, "No CardDAV address books were found");
    goto finished;
  }
  result->collectionCount = (long)collectionCount;
  for (index = 0; index < collectionCount; index++) {
    if (!RCFetchCollection(config, client, store, &collections[index],
                           runIdentifier, result, error)) goto finished;
  }
  success = 1;

finished:
  if (runStarted) {
    RCErrorClear(&finishError);
    if (!RCContactStoreFinishRun(store, runIdentifier, success,
        success ? NULL : error->message,
        &finishError) && success) {
      if (error != NULL) *error = finishError;
      success = 0;
    }
  }
  RCDAVFreeCollections(collections, collectionCount);
  free(principalURL);
  free(homeURL);
  RCHTTPClientDestroy(client);
  return success;
}
