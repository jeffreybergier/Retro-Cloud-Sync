#import "RCCalendarGraph.h"
#import "RCAutorelease.h"
#import "RCSyncConflictSession.h"
#import "RCLogger.h"
#import "RCCalendarSyncServicesBridge.h"
#import "RCCalendarSyncClient.h"
#import "RCTwoWaySync.h"
#import "RCCalendarTime.h"
#import "RCCalendarRecurrence.h"
#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static NSString *const testIdentifier = @"com.altivecintelligence.calendars.test.v1";
static NSString *String(const char *s)
{
  return s ? [NSString stringWithUTF8String:s] : nil;
}
static NSString *Entity(NSString *s)
{
  return [@"com.apple.calendars." stringByAppendingString:s];
}
static void Text(NSMutableDictionary *d, NSString *key, const char *value)
{
  NSString *s = String(value);
  if (s)
    [d setObject:s forKey:key];
}
static NSMutableDictionary *Record(NSString *entity)
{
  return [NSMutableDictionary dictionaryWithObject:Entity(entity)
                                            forKey:ISyncRecordEntityNameKey];
}
static void Link(NSMutableDictionary *d, NSString *key, NSString *id)
{
  [d setObject:id ? [NSArray arrayWithObject:id] : [NSArray array] forKey:key];
}
int RCSyncServicesPushCalendars(RCCalendarStore *store, const char *descriptionPath,
                                int testClient, long *count, RCError *error)
{
  ISyncSession *session = nil;
  sqlite3_stmt *q = NULL;
  NSMutableDictionary *records = [NSMutableDictionary dictionary],
                      *calendarRecords = [NSMutableDictionary dictionary];
  NSMutableArray *updates = [NSMutableArray array];
  NSString *clientID = nil;
  long long generation = 0;
  int success = 0, step = SQLITE_DONE;
  RCErrorClear(error);
  if (count)
    *count = 0;
  @try {
    if (sqlite3_prepare_v2(store->db,
                           "SELECT sync_id,generation FROM accounts WHERE id=?", -1, &q,
                           NULL) != SQLITE_OK)
      goto sqlError;
    sqlite3_bind_int64(q, 1, store->account);
    if (sqlite3_step(q) != SQLITE_ROW)
      goto sqlError;
    clientID =
        testClient
            ? testIdentifier
            : RCCalendarSyncClientIdentifier(
                  String((const char *)sqlite3_column_text(q, 0)));
    generation = sqlite3_column_int64(q, 1);
    sqlite3_finalize(q);
    q = NULL;
    if (!generation) {
      RCErrorSet(error, 1, "Calendar mirror has no complete inventory yet");
      goto done;
    }
    if (sqlite3_prepare_v2(store->db,
                           "SELECT id,sync_id,display_name,description FROM calendars "
                           "WHERE account_id=? AND remote_missing=0 ORDER BY id",
                           -1, &q, NULL) != SQLITE_OK)
      goto sqlError;
    sqlite3_bind_int64(q, 1, store->account);
    while ((step = sqlite3_step(q)) == SQLITE_ROW) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        RCSessionCheck();
        NSString *id = [@"calendar-"
            stringByAppendingString:String((const char *)sqlite3_column_text(q, 1))];
        NSMutableDictionary *record = Record(@"Calendar");
        NSString *title = String((const char *)sqlite3_column_text(q, 2));
        /* Calendar identity is title + read-only in Tiger. Include a stable short
           suffix so equal remote titles cannot merge with each other. */
        [record setObject:RCCalendarNativeTitle(RCCalendarStoreWriteJournal(store),id,title) forKey:@"title"];
        Text(record, @"notes", (const char *)sqlite3_column_text(q, 3));
        /* iCal turns imported calendars into writable local calendars. Declaring
           read-only here changes its identity on the next iCal sync and duplicates
           the calendar. One-way behavior is enforced by the push-only client. */
        [record setObject:[NSNumber numberWithBool:NO] forKey:@"read only"];
        [record setObject:[NSMutableArray array] forKey:@"events"];
        Link(record, @"tasks", nil);
        [calendarRecords
            setObject:id
               forKey:[NSNumber numberWithLongLong:sqlite3_column_int64(q, 0)]];
        [records setObject:record forKey:id];
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
    if (step != SQLITE_DONE)
      goto sqlError;
    sqlite3_finalize(q);
    q = NULL;
    if (sqlite3_prepare_v2(
            store->db,
            "SELECT r.id,r.calendar_id,r.raw_ical,r.export_ical,r.parse_error,r.etag FROM "
            "calendar_resources r JOIN calendars c ON "
            "c.id=r.calendar_id WHERE c.account_id=? AND "
            "c.remote_missing=0 AND r.remote_missing=0 AND r.scope_excluded=0 ORDER BY r.id",
            -1, &q, NULL) != SQLITE_OK)
      goto sqlError;
    sqlite3_bind_int64(q, 1, store->account);
    while ((step = sqlite3_step(q)) == SQLITE_ROW) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        RCSessionCheck();
        long long resource = sqlite3_column_int64(q, 0);
        NSString *calendarID = [calendarRecords
            objectForKey:[NSNumber numberWithLongLong:sqlite3_column_int64(q, 1)]];
        RCError mappingError;
        NSMutableDictionary *mapped = nil;
        NSMutableDictionary *update = [NSMutableDictionary
            dictionaryWithObject:[NSNumber numberWithLongLong:resource]
                          forKey:@"resource"];
        RCErrorClear(&mappingError);
        if (sqlite3_column_type(q, 4) != SQLITE_NULL)
          RCErrorSet(&mappingError, 1, "%s", sqlite3_column_text(q, 4));
        else
          mapped = RCCalendarResourceGraph(store, resource, calendarID, sqlite3_column_blob(q, 2),
                               (size_t)sqlite3_column_bytes(q, 2), &mappingError);
        if (mapped) {
          [update setObject:String((const char *)sqlite3_column_text(q, 5)) ?: @""
                     forKey:@"etag"];
          [update setObject:[NSData dataWithBytes:sqlite3_column_blob(q, 2)
                                           length:(NSUInteger)sqlite3_column_bytes(q, 2)]
                     forKey:@"raw"];
          [update setObject:@"exported" forKey:@"status"];
        } else {
          [update setObject:String(mappingError.message) forKey:@"error"];
          if (sqlite3_column_type(q, 3) != SQLITE_NULL) {
            RCError oldError;
            mapped = RCCalendarResourceGraph(store, resource, calendarID, sqlite3_column_blob(q, 3),
                                 (size_t)sqlite3_column_bytes(q, 3), &oldError);
            if (!mapped) {
              RCErrorSet(
                  error, 1,
                  "Could not reconstruct previously exported calendar resource %lld",
                  resource);
              goto done;
            }
          }
          [update setObject:mapped ? @"retained previous" : @"unsupported"
                     forKey:@"status"];
          RCLogger(RCLogWarning, "Calendars", "Apply", @"Calendar resource %lld: %s (%@)", resource, mappingError.message,
                [update objectForKey:@"status"]);
        }
        [updates addObject:update];
        if (mapped) {
          NSEnumerator *keys = [mapped keyEnumerator];
          NSString *key;
          while ((key = [keys nextObject])) {
            NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
            @try {
              NSDictionary *r = [mapped objectForKey:key];
              if ([[r objectForKey:ISyncRecordEntityNameKey] isEqual:Entity(@"Event")])
                [[[records objectForKey:calendarID] objectForKey:@"events"] addObject:key];
              [records setObject:r forKey:key];
            } @catch(id exception) {
              RCDrainPoolPreservingException(&resourcePool,exception); @throw;
            } @finally { [resourcePool release]; }
          }
        }
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
    if (step != SQLITE_DONE)
      goto sqlError;
    sqlite3_finalize(q);
    q = NULL;
    {
      RCWriteJournal journal=RCCalendarStoreWriteJournal(store);
      NSDictionary *aliased=RCTwoWayApplyAliases(&journal,records,error);
      if (!aliased) goto done;
      [records setDictionary:aliased];
      ISyncManager *manager = [ISyncManager sharedManager];
      NSDictionary *description =
          [NSDictionary dictionaryWithContentsOfFile:String(descriptionPath)];
      NSArray *entities = [[description objectForKey:@"Entities"] allKeys];
      ISyncClient *client;
      NSEnumerator *keys;
      NSString *key;
      NSMutableArray *pull = [NSMutableArray array];
      if (![manager isEnabled]) {
        NSError *reason = [manager respondsToSelector:@selector(syncDisabledReason)]
            ? [manager performSelector:@selector(syncDisabledReason)] : nil;
        if (reason != nil)
          RCErrorSet(error, 1, "Calendar Sync Services is disabled or unavailable (reason %ld)",
                     (long)[reason code]);
        else RCErrorSet(error, 1, "Calendar Sync Services is disabled or unavailable");
        goto done;
      }
      if (![entities count]) {
        RCErrorSet(error, 1, "Calendar Sync Services client description is unavailable");
        goto done;
      }
      client = [manager registerClientWithIdentifier:clientID
                                 descriptionFilePath:String(descriptionPath)];
      if (!client) {
        RCErrorSet(error, 1, "Could not register calendar Sync Services client");
        goto done;
      }
      [client setEnabled:YES forEntityNames:entities];
      session = RCBeginSession(client,entities);
      if (!session) {
        RCErrorSet(error, 1, "Could not begin calendar Sync Services session");
        goto done;
      }
      [session clientWantsToPushAllRecordsForEntityNames:entities];
      keys = [records keyEnumerator];
      while ((key = [keys nextObject])) {
        NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
        @try {
          NSDictionary *record = [records objectForKey:key];
          if (![session shouldPushChangesForEntityName:
                            [record objectForKey:ISyncRecordEntityNameKey]]) {
            RCErrorSet(error, 1, "Sync Services did not permit the calendar push");
            goto done;
          }
          RCSessionPush(session,record,key);
        } @catch(id exception) {
          RCDrainPoolPreservingException(&resourcePool,exception); @throw;
        } @finally { [resourcePool release]; }
      }
      keys = [entities objectEnumerator];
      while ((key = [keys nextObject]))
        if ([session shouldPullChangesForEntityName:key])
          [pull addObject:key];
      /* Push-only sessions still have to enter mingling before finishing. */
      if (!RCPrepareToPull(session,pull)) {
        RCErrorSet(error, 1, "Calendar Sync Services could not mingle records");
        goto done;
      }
      if ([pull count]) {
        ISyncChange *change;
        NSEnumerator *changes;
        changes = [session changeEnumeratorForEntityNames:pull];
        while ((change = [changes nextObject]))
          if ([change type] != ISyncChangeTypeDelete)
            [session
                clientRefusedChangesForRecordWithIdentifier:[change recordIdentifier]];
        [session clientCommittedAcceptedChanges];
      }
      [session finishSyncing];
      session = nil;
    }
    /* IDs already live in SQLite before the session. If this commit fails,
       replay reconstructs exactly the same graph on the next attempt. */
    if (!RCCalendarStoreSQL(store, error, "BEGIN IMMEDIATE"))
      goto done;
    {
      NSEnumerator *it = [updates objectEnumerator];
      NSDictionary *update;
      if (sqlite3_prepare_v2(store->db,
                             "UPDATE calendar_resources SET "
                             "export_etag=CASE WHEN ?1 IS NOT NULL THEN ?5 ELSE export_etag END,"
                             "export_ical=COALESCE(?1,export_ical),export_status=?2,"
                             "export_error=?3 WHERE id=?4",
                             -1, &q, NULL) != SQLITE_OK)
        goto sqlError;
      while ((update = [it nextObject])) {
        NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
        @try {
          NSData *raw = [update objectForKey:@"raw"];
          sqlite3_reset(q);
          sqlite3_clear_bindings(q);
          if (raw)
            sqlite3_bind_blob(q, 1, [raw bytes], (int)[raw length], SQLITE_TRANSIENT);
          sqlite3_bind_text(q, 2, [[update objectForKey:@"status"] UTF8String], -1,
                            SQLITE_TRANSIENT);
          sqlite3_bind_text(q, 3, [[update objectForKey:@"error"] UTF8String], -1,
                            SQLITE_TRANSIENT);
          sqlite3_bind_int64(q, 4, [[update objectForKey:@"resource"] longLongValue]);
          sqlite3_bind_text(q, 5, [[update objectForKey:@"etag"] UTF8String], -1, SQLITE_TRANSIENT);
          if (sqlite3_step(q) != SQLITE_DONE)
            goto sqlError;
        } @catch(id exception) {
          RCDrainPoolPreservingException(&resourcePool,exception); @throw;
        } @finally { [resourcePool release]; }
      }
      sqlite3_finalize(q);
      q = NULL;
    }
    if (!RCCalendarStoreSnapshotWriteBases(store, generation, error)) goto done;
    if (!RCCalendarStoreSQL(
            store, error,
            "UPDATE accounts SET published_generation=%lld WHERE id=%lld;COMMIT",
            generation, store->account))
      goto done;
    if (count)
      *count = (long)[records count];
    success = 1;
    goto done;
  sqlError:
    RCErrorSet(error, 1, "Calendar export database error: %s",
               sqlite3_errmsg(store->db));
  } @catch (NSException *exception) {
    RCErrorSet(error, 1, "Calendar Sync Services: %s", [[exception name] UTF8String]);
  }
done:
  sqlite3_finalize(q);
  if (session) {
    @try {
      [session cancelSyncing];
    } @catch (NSException *exception) {
      RCLogger(RCLogWarning, "Calendars", "Apply", @"Could not cancel Sync Services session: %@", [exception name]);
    }
  }
  if (!success && !sqlite3_get_autocommit(store->db))
    RCCalendarStoreSQL(store, NULL, "ROLLBACK");
  return success;
}
int RCSyncServicesUnregisterCalendarTestClient(RCError *error)
{
  @try {
    ISyncManager *manager = [ISyncManager sharedManager];
    ISyncClient *client = [manager clientWithIdentifier:testIdentifier];
    if (client)
      [manager unregisterClient:client];
    return 1;
  } @catch (NSException *exception) {
    RCErrorSet(error, 1, "Could not unregister calendar test client: %s",
               [[exception name] UTF8String]);
  }
  return 0;
}
