#import "RCNativeCalendarRecovery.h"
#import "RCTwoWayNative.h"
#import "RCTwoWayInternal.h"
#import "RCLogger.h"
#if TARGET_OS_IPHONE
#import "../iOS-daemon/RCIOSNativeBackend.h"
#endif

static BOOL RepairCalendar(RCCalendarStore *store,NSString *root,BOOL removeExcluded,RCError *error)
{
  RCWriteJournal j=RCCalendarStoreWriteJournal(store);
  sqlite3_stmt *q=NULL; NSDictionary *saved=nil; NSData *body=nil;
  NSString *etag=nil; long long generation=0; BOOL ok=NO;
  id<RCNativeStore> native=nil;
  RCErrorClear(error);
  /* Bind both native ownership and downloaded data to the same account and
     href. Do not adopt another resource or fall back to an older export. */
  if(sqlite3_prepare_v2(j.db,"SELECT resource,native,snapshot FROM native_store_resources WHERE account_id=? AND root=? AND pending=0",-1,&q,NULL)!=SQLITE_OK) goto done;
  sqlite3_bind_int64(q,1,j.account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
  if(sqlite3_step(q)!=SQLITE_ROW) goto done;
  NSMutableDictionary *old=[NSMutableDictionary dictionaryWithDictionary:RCTwoWayUnarchive(q,0)];
  [old setObject:RCTwoWayUnarchive(q,1) forKey:@"_ids"];
  [old setObject:RCTwoWayUnarchive(q,2) forKey:@"_snapshot"]; saved=old;
  sqlite3_finalize(q); q=NULL;
  if(sqlite3_prepare_v2(j.db,
      "SELECT r.raw_ical,r.etag,a.generation FROM calendar_resources r JOIN calendars c ON c.id=r.calendar_id JOIN accounts a ON a.id=c.account_id "
      "WHERE c.account_id=? AND r.href=? AND c.remote_missing=0 AND r.remote_missing=0 AND r.scope_excluded=? AND r.parse_error IS NULL "
      "AND NOT EXISTS(SELECT 1 FROM write_operations o WHERE o.account_id=c.account_id AND o.href=r.href AND o.state NOT IN ('acknowledged','cancelled')) "
      "AND NOT EXISTS(SELECT 1 FROM two_way_pending_fields f WHERE f.account_id=c.account_id AND f.root_id=?)",-1,&q,NULL)!=SQLITE_OK) goto done;
  sqlite3_bind_int64(q,1,j.account);
  sqlite3_bind_text(q,2,[[saved objectForKey:@"href"] UTF8String],-1,SQLITE_TRANSIENT);
  sqlite3_bind_int(q,3,removeExcluded ? 1 : 0);
  sqlite3_bind_text(q,4,[root UTF8String],-1,SQLITE_TRANSIENT);
  if(sqlite3_step(q)!=SQLITE_ROW) goto done;
  body=[NSData dataWithBytes:sqlite3_column_blob(q,0) length:sqlite3_column_bytes(q,0)];
  if(sqlite3_column_type(q,1)==SQLITE_NULL) goto done;
  etag=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,1)]; generation=sqlite3_column_int64(q,2);
  sqlite3_finalize(q); q=NULL;
  /* Native-only databases need not have the legacy calendar-action table. */
  if(sqlite3_prepare_v2(j.db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='calendar_actions'",-1,&q,NULL)!=SQLITE_OK) goto done;
  int step=sqlite3_step(q); sqlite3_finalize(q); q=NULL;
  if(step==SQLITE_ROW) {
    if(sqlite3_prepare_v2(j.db,"SELECT 1 FROM calendar_actions WHERE account_id=? AND state<>'done' LIMIT 1",-1,&q,NULL)!=SQLITE_OK) goto done;
    sqlite3_bind_int64(q,1,j.account); step=sqlite3_step(q);
    sqlite3_finalize(q); q=NULL;
    if(step!=SQLITE_DONE) goto done;
  } else if(step!=SQLITE_DONE) goto done;
  if(removeExcluded) {
    /* Explicit local removal never implies a cloud tombstone or upload. */
    RCTwoWayContext c={j,@"explicit-excluded-calendar-removal",nil,@"com.apple.calendars.Event",
        [NSArray arrayWithObject:saved],[saved objectForKey:@"graph"],RCCalendarEncodeLocal,store,NO,RCCalendarProjectVerified,NO};
#if TARGET_OS_IPHONE
    native=RCCreateIOSNativeStore(&c,error);
#else
    native=RCCreateMacNativeStore(&c,error);
#endif
    if(!native || ![native removeResource:saved error:error]) goto done;
    NSDictionary *remaining=[native readResource:saved error:error];
    if(!remaining || [remaining count] || error->code) goto done;
    ok=RCTwoWaySQL(&j,error,"DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason LIKE 'native-series-%%'",j.account,[root UTF8String]);
    goto done;
  }
  NSMutableDictionary *resource=[NSMutableDictionary dictionaryWithDictionary:saved];
  [resource removeObjectForKey:@"_ids"]; [resource removeObjectForKey:@"_snapshot"];
  NSDictionary *projected=RCCalendarProjectVerified(store,resource,body,error);
  if(!projected || error->code) goto done;
  resource=[NSMutableDictionary dictionaryWithDictionary:projected];
  [resource setObject:etag forKey:@"etag"]; [resource setObject:[NSNumber numberWithLongLong:generation] forKey:@"revision"];
  RCTwoWayContext c={j,@"explicit-calendar-restoration",nil,@"com.apple.calendars.Event",
      [NSArray arrayWithObject:resource],[resource objectForKey:@"graph"],RCCalendarEncodeLocal,store,NO,RCCalendarProjectVerified,NO};
#if TARGET_OS_IPHONE
  native=RCCreateIOSNativeStore(&c,error);
#else
  native=RCCreateMacNativeStore(&c,error);
#endif
  if(!native) goto done;
  NSDictionary *truth=[native readResource:saved error:error];
  if(![truth objectForKey:root] || error->code) goto done;
  if(![native canPublishResource:resource error:error] || ![native publishResource:resource error:error]) goto done;
  /* Publication's durable receipt and fresh native date verification precede
     clearing attention. Do not advance account-wide success or prune history. */
  if(!RCTwoWaySQL(&j,error,"BEGIN IMMEDIATE")) goto done;
  if(!RCWriteJournalSetBase(&j,[[resource objectForKey:@"key"] UTF8String],[[resource objectForKey:@"href"] UTF8String],
      [etag UTF8String],[body bytes],[body length],generation,error) ||
      !RCTwoWaySQL(&j,error,"DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND (reason LIKE 'native-series-%%' OR reason='native-publication-pending')",j.account,[root UTF8String]) ||
      !RCTwoWaySQL(&j,error,"COMMIT")) { RCTwoWaySQL(&j,NULL,"ROLLBACK"); goto done; }
  RCLogger(RCLogInfo,"Calendars","Recovery",@"Explicitly restored owned local event from committed cloud download (record=%@)",root);
  ok=YES;
done:
  sqlite3_finalize(q); [native release];
  if(!ok && !error->code) RCErrorSet(error,1,"Calendar restoration requires an existing owned record, current download and no pending writes");
  return ok;
}

BOOL RCNativeRestoreCalendar(RCCalendarStore *store,NSString *root,RCError *error)
{ return RepairCalendar(store,root,NO,error); }
BOOL RCNativeRemoveExcludedCalendar(RCCalendarStore *store,NSString *root,RCError *error)
{ return RepairCalendar(store,root,YES,error); }
