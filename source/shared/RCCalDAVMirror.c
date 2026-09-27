#include "RCCalDAVMirror.h"
#include "RCDAVSyncState.h"
#include "RCDAVStaging.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int RCCalDAVHistoryStart(const char *today, int years, char start[17], RCError *error)
{
  struct icaltimetype date;
  size_t i;
  if (!today || strlen(today) != 8 || (years != 1 && years != 2)) goto invalid;
  for (i = 0; i < 8; i++)
    if (today[i] < '0' || today[i] > '9') goto invalid;
  date = icaltime_from_string(today);
  if (!icaltime_is_valid_time(date) || date.year <= years || date.month < 1 ||
      date.month > 12 || date.day < 1 ||
      date.day > icaltime_days_in_month(date.month, date.year)) goto invalid;
  date.year -= years;
  if (date.day > icaltime_days_in_month(date.month, date.year))
    date.day = icaltime_days_in_month(date.month, date.year);
  snprintf(start, 17, "%04d%02d%02dT000000Z", date.year, date.month, date.day);
  return 1;
invalid:
  RCErrorSet(error, 1, "Calendar history requires a valid UTC date and 1 or 2 years");
  return 0;
}
static const char principalRequest[] =
    "<?xml version=\"1.0\"?><d:propfind "
    "xmlns:d=\"DAV:\"><d:prop><d:current-user-principal/></d:prop></d:propfind>";
static const char homeRequest[] = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\" "
                                  "xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><"
                                  "c:calendar-home-set/></d:prop></d:propfind>";
static void progress(const RCCardDAVMirrorConfig *c, RCLogLevel level, const char *message)
{
  if (c->progress)
    c->progress(level, message, c->progressContext);
}
static int calendarChanges(const RCDAVResource *changes, size_t count,
                            void *context, RCError *error)
{
  (void)changes; (void)error;
  if (count) *(int *)context = 1;
  return 1;
}
typedef struct {
  RCCalendarStore *store;
  long long calendar;
  int keep;
  char *token;
} RCCalendarFetch;
static int commitCalendar(int action, const char *href, const char *etag,
    const unsigned char *body, size_t length, void *context, RCError *error)
{
  RCCalendarFetch *fetch = context;
  if (action == RCDAVStageSeen) {
    int current;
    if (!RCCalendarStoreSeen(fetch->store, fetch->calendar, href, etag, &current, error)) return 0;
    if (current) return 1;
    RCErrorSet(error, 1, "Calendar mirror changed during download"); return 0;
  }
  return RCCalendarStoreSave(fetch->store, fetch->calendar, href, etag, body, length, error);
}
int RCCalDAVMirrorFetch(const RCCardDAVMirrorConfig *config, RCCalendarStore *store,
                        RCCardDAVMirrorResult *result, RCError *error)
{
  return RCCalDAVMirrorFetchSince(config, store, NULL, result, error);
}

int RCCalDAVMirrorFetchSince(const RCCardDAVMirrorConfig *config, RCCalendarStore *store,
                             const char *start, RCCardDAVMirrorResult *result, RCError *error)
{
  RCHTTPClientConfig http;
  RCHTTPClient *client = NULL;
  RCDAVCollection *collections = NULL;
  RCDAVResource *resources = NULL;
  size_t count = 0, resourceCount = 0, i, j;
  char *principal = NULL, *home = NULL;
  int success = 0, started = 0;
  RCDAVSyncState state;
  char *token = NULL, *scope = NULL, *next = NULL;
  RCError local, finishError;
  sqlite3 *stage = NULL;
  RCCalendarFetch *fetches = NULL;
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
  if (!sqlite3_get_autocommit(store->db)) {
    RCErrorSet(error, 1, "Calendar download requires an idle mirror transaction"); goto done;
  }
  stage = RCDAVStageOpen(error);
  if (!client || !stage) goto done;
  state.db = store->db; state.account = store->account;
  progress(config, RCLogDebug, "Discovering calendar principal and home");
  if (!RCDAVDiscoverHref(client, config->serviceURL, principalRequest,
                         "current-user-principal", "DAV:", &principal, error) ||
      !RCDAVDiscoverHref(client, principal, homeRequest, "calendar-home-set",
                         "urn:ietf:params:xml:ns:caldav", &home, error) ||
      !RCDAVListCollections(client, home, "calendar", "urn:ietf:params:xml:ns:caldav",
                            &collections, &count, error))
    goto done;
  result->collectionCount = (long)count;
  fetches = calloc(count ? count : 1, sizeof(*fetches));
  if (!fetches) { RCErrorSet(error, 1, "Could not stage calendar collections"); goto done; }
  for (i = 0; i < count; i++) {
    if (RCCheckCancellation(error)) goto done;
    if (!RCDAVSyncStateLoad(&state, collections[i].url, &token, &scope, error)) goto done;
    if (collections[i].supportsSync && token && scope && !strcmp(scope, start ? start : "")) {
      int changed = 0;
      int status;
      progress(config, RCLogDebug, "Checking calendar sync token");
      status = RCDAVSyncCollection(client, collections[i].url, token,
                                   calendarChanges, &changed, &next, error);
      if (status == RCDAVSyncFailed) goto done;
      if (status == RCDAVSyncComplete && !changed) {
        /* Preserve the previously complete window. A rolling cutoff or changed
           preference takes the inventory path even if the server is unchanged. */
        fetches[i].keep = 1;
        progress(config, RCLogDebug, "Calendar unchanged; retaining history window");
        goto collection_complete;
      }
      if (status == RCDAVSyncFallback) {
        RCErrorClear(error);
        progress(config, RCLogInfo, "Sync token unavailable; refreshing calendar history window");
      }
    }
    if (!(start ? RCDAVListCalendarResourcesSince(client, collections[i].url, start,
                                                  &resources, &resourceCount, error)
                : RCDAVListResources(client, collections[i].url, &resources,
                                     &resourceCount, error)))
      goto done;
    result->listedResourceCount += (long)resourceCount;
    for (j = 0; j < resourceCount; j++) {
      if (RCCheckCancellation(error)) goto done;
      int current, staged;
      RCHTTPResponse response;
      if (!RCDAVMirrorResourceCurrent(store->db, store->account, 1, collections[i].url,
          resources[j].url, resources[j].etag, &current, error) ||
          !RCDAVStageHasResource(stage, (long long)i, resources[j].url, &staged, error))
        goto done;
      if (current && !staged) {
        if (!RCDAVStageSave(stage, (long long)i, RCDAVStageSeen, resources[j].url,
            resources[j].etag, NULL, 0, error)) goto done;
        result->unchangedResourceCount++;
        continue;
      }
      progress(config, RCLogDebug, "Downloading changed calendar resource");
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
      if (!RCDAVStageSave(stage, (long long)i, RCDAVStageDownloaded, resources[j].url,
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
collection_complete:
    /* Snapshot token precedes the inventory. Changes during its GETs will be
       reported again next time, rather than skipped by a later token read. */
    {
      const char *saved = next ? next : collections[i].syncToken;
      fetches[i].token = saved ? strdup(saved) : NULL;
      if (saved && !fetches[i].token) { RCErrorSet(error, 1, "Could not stage calendar token"); goto done; }
    }
    free(token); free(scope); free(next); token = NULL; scope = NULL; next = NULL;
  }
  if (RCCheckCancellation(error) || !RCCalendarStoreBeginScopedRun(store, start != NULL, error)) goto done;
  started = 1;
  for (i = 0; i < count; i++) {
    RCCalendarFetch *fetch = &fetches[i]; fetch->store = store;
    if (RCCheckCancellation(error) || !RCCalendarStoreCollection(store, &collections[i], &fetch->calendar, error)) goto done;
    if (fetch->keep) {
      if (!RCCalendarStoreSQL(store, error,
          "UPDATE calendar_resources SET seen_run=%lld WHERE calendar_id=%lld "
          "AND remote_missing=0 AND scope_excluded=0", store->run, fetch->calendar)) goto done;
      result->unchangedResourceCount += sqlite3_changes(store->db);
    }
    if (!RCDAVStageApply(stage, (long long)i, commitCalendar, fetch, error) ||
        !RCDAVSyncStateSave(&state, collections[i].url, fetch->token, start, store->run, error)) goto done;
  }
  if (!RCDAVSyncStateFinish(&state, store->run, error)) goto done;
  if (RCCheckCancellation(error)) goto done;
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
  if (fetches) for (i = 0; i < count; i++) free(fetches[i].token);
  free(fetches);
  sqlite3_close(stage);
  free(principal);
  free(home);
  free(token); free(scope); free(next);
  RCHTTPClientDestroy(client);
  return success;
}
