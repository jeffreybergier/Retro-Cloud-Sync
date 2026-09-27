#include "RCCardDAVMirror.h"

#include "RCVCard.h"
#include "RCDAVClient.h"
#include "RCDAVStaging.h"

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
                       RCLogLevel level, const char *message)
{
  if (config->progress != NULL) {
    config->progress(level, message, config->progressContext);
  }
}

typedef struct {
  const RCCardDAVMirrorConfig *config;
  RCHTTPClient *client;
  RCContactStore *store;
  long long collection, run;
  sqlite3 *stage;
  const char *collectionURL;
  long long stageCollection;
  int keep;
  char *token;
  RCCardDAVMirrorResult *result;
} RCContactFetch;

static int RCApplyContactChanges(const RCDAVResource *resources, size_t resourceCount,
                                  void *context, RCError *error)
{
  RCContactFetch *fetch = context;
  const RCCardDAVMirrorConfig *config = fetch->config;
  RCHTTPClient *client = fetch->client;
  RCContactStore *store = fetch->store;
  RCDAVSyncState state = RCContactStoreDAVSyncState(store);
  RCCardDAVMirrorResult *result = fetch->result;
  size_t index;
  result->listedResourceCount += (long)resourceCount;
  for (index = 0; index < resourceCount; index++) {
    if (RCCheckCancellation(error)) return 0;
    int current, staged;
    if (resources[index].etag == NULL) {
      if (!RCDAVStageSave(fetch->stage, fetch->stageCollection, RCDAVStageDeleted,
          resources[index].url, NULL, NULL, 0, error)) return 0;
      continue;
    }
    if (!RCDAVMirrorResourceCurrent(state.db, state.account, 0, fetch->collectionURL,
        resources[index].url, resources[index].etag, &current, error) ||
        !RCDAVStageHasResource(fetch->stage, fetch->stageCollection,
          resources[index].url, &staged, error))
      return 0;
    if (current && !staged) {
      if (!RCDAVStageSave(fetch->stage, fetch->stageCollection, RCDAVStageSeen,
          resources[index].url, resources[index].etag, NULL, 0, error)) return 0;
      result->unchangedResourceCount++;
    } else {
      RCHTTPResponse response;
      const char *etag;
      RCHTTPResponseInit(&response);
      RCProgress(config, RCLogDebug, "Downloading changed contact");
      if (!RCHTTPClientRequest(client, "GET", resources[index].url, NULL,
          NULL, NULL, 0, &response, error)) {
        RCHTTPResponseClear(&response);
        return 0;
      }
      if (response.statusCode != 200) {
        RCErrorSet(error, (int)response.statusCode,
                   "Contact GET returned HTTP %ld", response.statusCode);
        RCHTTPResponseClear(&response);
        return 0;
      }
      etag = response.etag != NULL ? response.etag : resources[index].etag;
      if (!RCDAVStageSave(fetch->stage, fetch->stageCollection, RCDAVStageDownloaded,
          resources[index].url, etag, response.body, response.bodyLength, error)) {
        RCHTTPResponseClear(&response);
        return 0;
      }
      result->downloadedResourceCount++;
      RCHTTPResponseClear(&response);
    }
  }
  return 1;
}

static int RCCommitContact(int action, const char *href, const char *etag,
    const unsigned char *body, size_t length, void *context, RCError *error)
{
  RCContactFetch *fetch = context;
  int parseFailed;
  if (action == RCDAVStageDeleted)
    return RCContactStoreSyncDelete(fetch->store, fetch->collection, href, fetch->run, error);
  if (action == RCDAVStageSeen)
    return RCContactStoreMarkSeen(fetch->store, fetch->collection, href, fetch->run, error);
  if (!RCContactStoreSaveResource(fetch->store, fetch->collection, fetch->run,
      href, etag, body, length, &parseFailed, error)) return 0;
  if (parseFailed) RCProgress(fetch->config, RCLogWarning,
      "Invalid contact retained; keeping its last usable version if available");
  return 1;
}

static int RCFetchCollection(const RCCardDAVMirrorConfig *config,
                             RCHTTPClient *client, RCContactStore *store,
                             const RCDAVCollection *collection,
                             RCContactFetch *fetch,
                             RCCardDAVMirrorResult *result, RCError *error)
{
  RCDAVResource *resources = NULL;
  size_t resourceCount = 0;
  RCDAVSyncState state = RCContactStoreDAVSyncState(store);
  char *token = NULL, *scope = NULL, *next = NULL;
  int success = 0, attempt;
  fetch->config = config; fetch->client = client; fetch->store = store;
  fetch->collectionURL = collection->url; fetch->result = result;
  if (!RCDAVSyncStateLoad(&state, collection->url, &token, &scope, error)) goto finished;
  if (collection->supportsSync) {
    /* A rejected/expired delta retries an initial sync. Discard staged early
       pages when a later page rejects its continuation token. */
    for (attempt = 0; attempt < (token ? 2 : 1); attempt++) {
      const char *base = attempt == 0 ? token : NULL;
      RCCardDAVMirrorResult before = *result;
      int status;
      fetch->keep = base != NULL;
      RCProgress(config, RCLogDebug, base ? "Fetching contact changes" : "Fetching initial contact sync inventory");
      status = RCDAVSyncCollection(client, collection->url, base,
                                   RCApplyContactChanges, fetch, &next, error);
      if (status == RCDAVSyncFailed) goto finished;
      if (status == RCDAVSyncComplete) {
        goto complete;
      }
      if (!RCDAVStageReset(fetch->stage, fetch->stageCollection, error))
        goto finished;
      fetch->keep = 0;
      *result = before;
      RCErrorClear(error);
      RCProgress(config, RCLogInfo, "Sync token unavailable; rebuilding contact inventory");
    }
  }
  RCProgress(config, RCLogDebug, "Listing contacts");
  if (!RCDAVListResources(client, collection->url, &resources, &resourceCount, error) ||
      !RCApplyContactChanges(resources, resourceCount, fetch, error)) goto finished;
complete:
  fetch->token = next; next = NULL;
  success = 1;
finished:
  free(token); free(scope); free(next);
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
  sqlite3 *stage = NULL;
  RCContactFetch *fetches = NULL;

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
  if (!RCContactStoreIsAccount(store, config->username)) {
    RCErrorSet(error, 1, "CardDAV credentials do not match the contact database account");
    return 0;
  }
  memset(&httpConfig, 0, sizeof(httpConfig));
  httpConfig.username = config->username;
  httpConfig.password = config->password;
  httpConfig.certificatePath = config->certificatePath;
  httpConfig.allowedHostSuffix = config->allowedHostSuffix;
  httpConfig.userAgent = "RetroCloudSync-CardDAV/0.1";
  client = RCHTTPClientCreate(&httpConfig, error);
  if (!sqlite3_get_autocommit(RCContactStoreDAVSyncState(store).db)) {
    RCErrorSet(error, 1, "Contact download requires an idle mirror transaction"); goto finished;
  }
  stage = RCDAVStageOpen(error);
  if (client == NULL || stage == NULL)
    goto finished;
  RCProgress(config, RCLogDebug, "Discovering CardDAV principal");
  if (!RCDAVDiscoverHref(client, config->serviceURL, kPrincipalRequest,
      "current-user-principal", kDAVNamespace, &principalURL, error))
    goto finished;
  RCProgress(config, RCLogDebug, "Discovering address-book home");
  if (!RCDAVDiscoverHref(client, principalURL, kHomeRequest,
      "addressbook-home-set", kCardDAVNamespace, &homeURL, error))
    goto finished;
  RCProgress(config, RCLogDebug, "Discovering address books");
  if (!RCDAVListCollections(client, homeURL, "addressbook", kCardDAVNamespace, &collections, &collectionCount,
                         error)) goto finished;
  result->collectionCount = (long)collectionCount;
  fetches = calloc(collectionCount ? collectionCount : 1, sizeof(*fetches));
  if (!fetches) { RCErrorSet(error, 1, "Could not stage contact collections"); goto finished; }
  for (index = 0; index < collectionCount; index++) {
    if (RCCheckCancellation(error)) goto finished;
    fetches[index].stage = stage; fetches[index].stageCollection = (long long)index;
    if (!RCFetchCollection(config, client, store, &collections[index],
                           &fetches[index], result, error)) goto finished;
  }
  if (RCCheckCancellation(error) || !RCContactStoreBeginRun(store, &runIdentifier, error)) goto finished;
  runStarted = 1;
  {
    RCDAVSyncState state = RCContactStoreDAVSyncState(store);
    for (index = 0; index < collectionCount; index++) {
      RCContactFetch *fetch = &fetches[index]; fetch->run = runIdentifier;
      if (RCCheckCancellation(error) ||
          !RCContactStoreGetCollection(store, collections[index].url, collections[index].displayName, &fetch->collection, error) ||
          (fetch->keep && !RCContactStoreKeepCollection(store, fetch->collection, runIdentifier, error)) ||
          !RCDAVStageApply(stage, (long long)index, RCCommitContact, fetch, error) ||
          !RCDAVSyncStateSave(&state, collections[index].url, fetch->token, "", runIdentifier, error) ||
          !RCContactStoreFinishCollection(store, fetch->collection, runIdentifier, error)) goto finished;
    }
    if (!RCDAVSyncStateFinish(&state, runIdentifier, error)) goto finished;
  }
  if (RCCheckCancellation(error)) goto finished;
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
  if (fetches) for (index = 0; index < collectionCount; index++) free(fetches[index].token);
  free(fetches);
  sqlite3_close(stage);
  free(principalURL);
  free(homeURL);
  RCHTTPClientDestroy(client);
  return success;
}
