#import "RCTwoWaySync.h"
#import "RCSyncConflictSession.h"
#import "RCSyncRecordEquality.h"
#include "RCDAVWriter.h"
#include <sys/stat.h>
#include <stdarg.h>
#include <time.h>

BOOL RCTwoWaySQL(RCWriteJournal *j, RCError *error, const char *format, ...)
{
  va_list args;
  char *sql;
  int result;
  va_start(args,format); sql=sqlite3_vmprintf(format,args); va_end(args);
  if (!sql) { RCErrorSet(error,1,"Could not allocate two-way database query"); return NO; }
  result=sqlite3_exec(j->db,sql,NULL,NULL,NULL); sqlite3_free(sql);
  if (result!=SQLITE_OK) RCErrorSet(error,1,"Two-way state database failed");
  return result==SQLITE_OK;
}
BOOL RCTwoWayInitialize(RCWriteJournal *j, RCError *error)
{
  return RCTwoWaySQL(j,error,
      "CREATE TABLE IF NOT EXISTS two_way_intents("
      "operation_id INTEGER PRIMARY KEY,receipt BLOB NOT NULL,paths BLOB NOT NULL);"
      "CREATE TABLE IF NOT EXISTS two_way_aliases(account_id INTEGER NOT NULL,"
      "imported_id TEXT NOT NULL,native_id TEXT NOT NULL,PRIMARY KEY(account_id,imported_id));"
      "CREATE TABLE IF NOT EXISTS two_way_excluded(account_id INTEGER NOT NULL,"
      "record_id TEXT NOT NULL,PRIMARY KEY(account_id,record_id));"
      "CREATE TABLE IF NOT EXISTS two_way_accounts(account_id INTEGER PRIMARY KEY);"
      "CREATE TABLE IF NOT EXISTS two_way_attention(account_id INTEGER NOT NULL,"
      "record_id TEXT NOT NULL,reason TEXT NOT NULL,PRIMARY KEY(account_id,record_id));");
}
NSString *RCTwoWayNewIdentifier(void)
{
  CFUUIDRef uuid=CFUUIDCreate(kCFAllocatorDefault);
  if (!uuid) return nil;
  NSString *result=(NSString *)CFUUIDCreateString(kCFAllocatorDefault,uuid);
  CFRelease(uuid);
  return [result autorelease];
}
NSString *RCTwoWayString(id value)
{
  if ([value isKindOfClass:[NSURL class]]) return [value absoluteString];
  return [value isKindOfClass:[NSString class]] ? value : @"";
}
NSString *RCTwoWayEscape(NSString *value)
{
  NSMutableString *s=[NSMutableString stringWithString:RCTwoWayString(value)];
  [s replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"\r" withString:@"\n" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@";" withString:@"\\;" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"," withString:@"\\," options:0 range:NSMakeRange(0,[s length])];
  return s;
}
BOOL RCTwoWayRecordsEqual(NSDictionary *a, NSDictionary *b)
{
  return RCNativeRecordsEqual(a,b);
}
NSDictionary *RCTwoWaySubgraph(NSDictionary *graph, NSArray *ids)
{
  NSMutableDictionary *result=[NSMutableDictionary dictionary];
  NSEnumerator *it=[ids objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) if ([graph objectForKey:key])
    [result setObject:[graph objectForKey:key] forKey:key];
  return result;
}
NSDictionary *RCTwoWayRemap(NSDictionary *graph, NSDictionary *aliases)
{
  NSMutableDictionary *result=[NSMutableDictionary dictionary];
  NSEnumerator *it=[graph keyEnumerator]; NSString *key;
  while ((key=[it nextObject])) {
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:[graph objectForKey:key]];
    NSEnumerator *fields=[[record allKeys] objectEnumerator]; NSString *field;
    while ((field=[fields nextObject])) {
      id value=[record objectForKey:field];
      if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *mapped=[NSMutableArray array];
        NSEnumerator *values=[value objectEnumerator]; id item;
        while ((item=[values nextObject]))
          [mapped addObject:([item isKindOfClass:[NSString class]] ? [aliases objectForKey:item] : nil) ?: item];
        [record setObject:mapped forKey:field];
      }
    }
    [result setObject:record forKey:[aliases objectForKey:key] ?: key];
  }
  return result;
}
static id Unarchive(sqlite3_stmt *q, int col)
{
  return [NSKeyedUnarchiver unarchiveObjectWithData:
      [NSData dataWithBytes:sqlite3_column_blob(q,col) length:sqlite3_column_bytes(q,col)]];
}
static BOOL SaveIntent(RCWriteJournal *j, long long operation, NSDictionary *receipt,
                       NSDictionary *paths, RCError *error)
{
  NSData *r=[NSKeyedArchiver archivedDataWithRootObject:receipt];
  NSData *p=[NSKeyedArchiver archivedDataWithRootObject:paths];
  sqlite3_stmt *q=NULL; BOOL ok=NO;
  if (sqlite3_prepare_v2(j->db,"INSERT INTO two_way_intents VALUES(?,?,?)",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,operation);
    sqlite3_bind_blob(q,2,[r bytes],(int)[r length],SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,3,[p bytes],(int)[p length],SQLITE_TRANSIENT);
    ok=sqlite3_step(q)==SQLITE_DONE;
  }
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(error,1,"Could not commit native write receipt");
  return ok;
}
static NSMutableDictionary *Aliases(RCWriteJournal *j, RCError *error)
{
  NSMutableDictionary *result=[NSMutableDictionary dictionary];
  sqlite3_stmt *q=NULL; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT imported_id,native_id FROM two_way_aliases WHERE account_id=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW)
      [result setObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,1)]
          forKey:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)]];
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read native identities"); return nil; }
  return result;
}
NSDictionary *RCTwoWayApplyAliases(RCWriteJournal *j, NSDictionary *graph, RCError *error)
{
  if (!RCTwoWayInitialize(j,error)) return nil;
  NSDictionary *aliases=Aliases(j,error);
  return aliases ? RCTwoWayRemap(graph,aliases) : nil;
}
static NSDictionary *MapResource(NSDictionary *resource, NSDictionary *aliases)
{
  NSMutableDictionary *r=[NSMutableDictionary dictionaryWithDictionary:resource];
  NSMutableDictionary *paths=[NSMutableDictionary dictionary];
  NSEnumerator *it=[[r objectForKey:@"paths"] keyEnumerator]; NSString *path;
  while ((path=[it nextObject])) {
    NSString *key=[[r objectForKey:@"paths"] objectForKey:path];
    [paths setObject:[aliases objectForKey:key] ?: key forKey:path];
  }
  [r setObject:paths forKey:@"paths"];
  [r setObject:RCTwoWayRemap([r objectForKey:@"graph"],aliases) forKey:@"graph"];
  [r setObject:[aliases objectForKey:[r objectForKey:@"root"]] ?: [r objectForKey:@"root"] forKey:@"root"];
  return r;
}
BOOL RCTwoWayGraphsEqual(NSDictionary *a, NSDictionary *b)
{
  return RCNativeGraphsEqual(a,b);
}
static NSDictionary *LiveReceipt(NSDictionary *receipt)
{
  NSMutableDictionary *live=[NSMutableDictionary dictionaryWithDictionary:receipt];
  NSEnumerator *it=[receipt keyEnumerator]; NSString *identifier;
  while ((identifier=[it nextObject])) if ([receipt objectForKey:identifier]==[NSNull null]) [live removeObjectForKey:identifier];
  return live;
}
static BOOL Attention(RCWriteJournal *j, NSString *root, const char *reason, RCError *error)
{
  NSLog(@"Two-way sync: %s (local change retained)",reason);
  return RCTwoWaySQL(j,error,"INSERT OR REPLACE INTO two_way_attention VALUES(%lld,%Q,%Q)",
      j->account,[root UTF8String],reason);
}
/* The mirror must contain exactly the verified revision before accepting a
   local change. Aliases commit first, making a crash before/after acceptance
   replayable without allocating a second identity for a native creation. */
static BOOL Complete(RCTwoWayContext *c, ISyncClient *client, NSDictionary *byHref,
                     NSMutableDictionary *aliases, RCError *error)
{
  RCWriteJournal *j=&c->journal;
  sqlite3_stmt *q=NULL; NSMutableArray *pending=[NSMutableArray array]; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT o.id,i.receipt,i.paths FROM write_operations o JOIN two_way_intents i "
      "ON i.operation_id=o.id WHERE o.account_id=? AND o.state='applied' ORDER BY o.id",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW)
      [pending addObject:[NSArray arrayWithObjects:[NSNumber numberWithLongLong:sqlite3_column_int64(q,0)],
          Unarchive(q,1),Unarchive(q,2),nil]];
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read verified writes"); return NO; }
  NSEnumerator *it=[pending objectEnumerator]; NSArray *item;
  while ((item=[it nextObject])) {
    RCWriteOperation o;
    if (!RCWriteJournalGet(j,[[item objectAtIndex:0] longLongValue],&o,error)) return NO;
    NSDictionary *resource=[byHref objectForKey:[NSString stringWithUTF8String:o.href]];
    NSDictionary *receipt=[item objectAtIndex:1], *wantedPaths=[item objectAtIndex:2];
    NSMutableDictionary *newAliases=[NSMutableDictionary dictionary];
    NSData *verifiedBody=[NSData dataWithBytes:o.resultBody length:o.resultLength];
    NSDictionary *verified=resource;
    BOOL matched=resource && [[resource objectForKey:@"etag"] isEqual:[NSString stringWithUTF8String:o.resultETag ?: ""]] &&
        [[resource objectForKey:@"body"] isEqual:verifiedBody];
    if (!matched && resource && c->projectVerified && o.resultETag && o.resultLength) {
      /* The writer has already GET-verified this immutable result. A later
         download need not still have the same ETag. Validate that result, then
         acknowledge only its exact native receipt before publishing the newer
         remote graph. Never send another PUT or replace the saved receipt. */
      RCError projectionError; RCErrorClear(&projectionError);
      verified=c->projectVerified(c->context,resource,verifiedBody,&projectionError);
      matched=verified!=nil;
    }
    NSEnumerator *paths=[wantedPaths keyEnumerator]; NSString *path;
    while (matched && (path=[paths nextObject])) {
      NSString *imported=[[verified objectForKey:@"paths"] objectForKey:path];
      if (!imported) matched=NO;
      else [newAliases setObject:[wantedPaths objectForKey:path] forKey:imported];
    }
    if (matched) matched=RCTwoWayGraphsEqual(RCTwoWayRemap([verified objectForKey:@"graph"],newAliases),LiveReceipt(receipt));
    if (!matched) {
      Attention(j,[[receipt allKeys] count] ? [[receipt allKeys] objectAtIndex:0] : @"unknown",
          "verified-write-awaits-matching-mirror",error);
      RCWriteOperationClear(&o); continue;
    }
    if (!RCTwoWaySQL(j,error,"BEGIN IMMEDIATE")) { RCWriteOperationClear(&o); return NO; }
    paths=[newAliases keyEnumerator]; NSString *identifier;
    while ((identifier=[paths nextObject])) {
      if (!RCTwoWaySQL(j,error,"INSERT OR REPLACE INTO two_way_aliases VALUES(%lld,%Q,%Q)",j->account,
          [identifier UTF8String],[[newAliases objectForKey:identifier] UTF8String])) break;
    }
    if (identifier || !RCTwoWaySQL(j,error,"COMMIT")) {
      RCTwoWaySQL(j,NULL,"ROLLBACK"); RCWriteOperationClear(&o); return NO;
    }
    [aliases addEntriesFromDictionary:newAliases];
    if (RCSyncAcceptConflictResolution(client,receipt,error)) {
      if (!RCWriteJournalAcknowledge(j,o.id,error)) { RCWriteOperationClear(&o); return NO; }
      NSEnumerator *completedIDs=[receipt keyEnumerator]; NSString *completedID;
      while ((completedID=[completedIDs nextObject])) if (!RCTwoWaySQL(j,error,
          "DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason IN ('verified-write-awaits-matching-mirror','verified-write-awaits-local-acceptance')",
          j->account,[completedID UTF8String])) { RCWriteOperationClear(&o); return NO; }
    } else {
      NSLog(@"Two-way acceptance deferred: %s",error->message);
      Attention(j,[[receipt allKeys] objectAtIndex:0],"verified-write-awaits-local-acceptance",NULL);
      RCErrorClear(error);
    }
    RCWriteOperationClear(&o);
  }
  return YES;
}
BOOL RCTwoWayExchange(RCTwoWayContext *c, RCError *error)
{
  RCWriteJournal *j=&c->journal;
  ISyncSession *session=nil;
  sqlite3_stmt *q=NULL;
  BOOL ok=NO;
  const char *phase="registration";
  RCErrorClear(error);
  c->didPublish=NO;
  if (!RCTwoWayInitialize(j,error)) return NO;
  BOOL contacts=[c->rootEntity isEqual:@"com.apple.contacts.Contact"];
  /* Opting into two-way contacts includes the Mac's existing address book.
     Retire exclusions saved by earlier versions for this account as well. */
  if (contacts && !RCTwoWaySQL(j,error,"DELETE FROM two_way_excluded WHERE account_id=%lld",j->account)) return NO;
  @try {
    NSMutableDictionary *description=[NSMutableDictionary dictionaryWithContentsOfFile:c->descriptionPath];
    NSString *path=[c->descriptionPath stringByAppendingString:@".two-way.plist"];
    /* Tiger ignores an empty/absent PushOnlyEntities list on update, and
       compares descriptions without the direction flags. A distinct display
       name plus a nonempty list updates capabilities in place, preserving IDs.
       These entity types have no reverse mapper and stay import-only. */
    NSString *importOnly=[c->rootEntity isEqual:@"com.apple.calendars.Event"] ?
        @"com.apple.calendars.Task" : @"com.apple.contacts.SmartGroup";
    [description setObject:[NSArray arrayWithObject:importOnly] forKey:@"PushOnlyEntities"];
    [description setObject:[([description objectForKey:@"DisplayName"] ?: @"Retro Cloud Sync") stringByAppendingString:@" (2-way)"] forKey:@"DisplayName"];
    if (!description || ![description writeToFile:path atomically:YES] || chmod([path fileSystemRepresentation],0600)) {
      RCErrorSet(error,1,"Could not prepare two-way client description"); goto done;
    }
    ISyncManager *manager=[ISyncManager sharedManager];
    ISyncClient *client=[manager registerClientWithIdentifier:c->clientIdentifier descriptionFilePath:path];
    NSArray *entities=[[description objectForKey:@"Entities"] allKeys];
    if (!client || ![manager isEnabled] || ![entities count]) {
      RCErrorSet(error,1,"Two-way Sync Services client is unavailable"); goto done;
    }
    [client setEnabled:YES forEntityNames:entities];
    NSMutableArray *pullEntities=[NSMutableArray arrayWithArray:entities];
    [pullEntities removeObject:importOnly];
    NSEnumerator *capabilities=[pullEntities objectEnumerator]; NSString *capability;
    while ((capability=[capabilities nextObject])) if (![client canPullChangesForEntityName:capability] || ![client canPushChangesForEntityName:capability]) {
      RCErrorSet(error,1,"Two-way registration lacks bidirectional capability for an enabled entity"); goto done;
    }
    NSMutableDictionary *aliases=Aliases(j,error), *byHref=[NSMutableDictionary dictionary];
    NSEnumerator *it=[c->resources objectEnumerator]; NSDictionary *resource;
    while ((resource=[it nextObject])) [byHref setObject:resource forKey:[resource objectForKey:@"href"]];
    phase="verified-write completion";
    if (!aliases || !Complete(c,client,byHref,aliases,error)) goto done;
    NSMutableDictionary *graph=[NSMutableDictionary dictionaryWithDictionary:RCTwoWayRemap(c->graph,aliases)];
    NSMutableArray *resources=[NSMutableArray array];
    NSMutableSet *known=[NSMutableSet set], *busy=[NSMutableSet set], *excluded=[NSMutableSet set];
    it=[c->resources objectEnumerator];
    while ((resource=[it nextObject])) {
      NSDictionary *r=MapResource(resource,aliases);
      [resources addObject:r]; [known addObject:[r objectForKey:@"root"]];
    }
    /* Find unresolved native intent before publishing any newer remote graph. */
    if (sqlite3_prepare_v2(j->db,"SELECT o.href,i.receipt FROM write_operations o JOIN two_way_intents i ON i.operation_id=o.id "
        "WHERE o.account_id=? AND o.state NOT IN ('acknowledged','cancelled')",-1,&q,NULL)!=SQLITE_OK) goto sqlError;
    sqlite3_bind_int64(q,1,j->account); int step;
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      NSString *href=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
      NSDictionary *receipt=Unarchive(q,1);
      [busy addObjectsFromArray:[receipt allKeys]];
      resource=[byHref objectForKey:href];
      if (resource) [busy addObject:[MapResource(resource,aliases) objectForKey:@"root"]];
    }
    if (step!=SQLITE_DONE) goto sqlError;
    sqlite3_finalize(q); q=NULL;
    /* Do not push a newer download while writes/acceptance remain unresolved.
       This conservative gate preserves pending local edits across retries. */
    if ([busy count]) { NSLog(@"Two-way sync has pending writes or conflicts; publication deferred"); ok=YES; goto done; }
    phase="session start";
    session=[ISyncSession beginSessionWithClient:client entityNames:entities
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
    if (!session) { RCErrorSet(error,1,"Could not begin two-way sync session"); goto done; }
    it=[entities objectEnumerator]; NSString *entity;
    while ((entity=[it nextObject])) if ([session shouldReplaceAllRecordsOnClientForEntityName:entity]) {
      RCErrorSet(error,1,"Two-way sync requires recovery from a truth reset; no uploads queued"); goto done;
    }
    phase="remote graph publication";
    [session clientWantsToPushAllRecordsForEntityNames:entities];
    it=[graph keyEnumerator]; NSString *key;
    while ((key=[it nextObject])) [session pushChangesFromRecord:[graph objectForKey:key] withIdentifier:key];
    phase="local change collection";
    if (![session prepareToPullChangesForEntityNames:pullEntities beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]) {
      RCErrorSet(error,1,"Two-way merge is pending"); goto done;
    }
    c->didPublish=YES;
    NSMutableDictionary *truth=[NSMutableDictionary dictionary];
    it=[entities objectEnumerator];
    while ((entity=[it nextObject])) [truth addEntriesFromDictionary:[[session snapshotOfRecordsInTruth]
        recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:entity forKey:ISyncRecordEntityNameKey]]];
    if (sqlite3_prepare_v2(j->db,"SELECT record_id FROM two_way_excluded WHERE account_id=?",-1,&q,NULL)!=SQLITE_OK) goto sqlError;
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) [excluded addObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)]];
    if (step!=SQLITE_DONE) goto sqlError;
    sqlite3_finalize(q); q=NULL;
    if (sqlite3_prepare_v2(j->db,"SELECT account_id FROM two_way_accounts WHERE account_id=?",-1,&q,NULL)!=SQLITE_OK) goto sqlError;
    sqlite3_bind_int64(q,1,j->account); step=sqlite3_step(q);
    if (step!=SQLITE_ROW && step!=SQLITE_DONE) goto sqlError;
    BOOL first=step==SQLITE_DONE;
    sqlite3_finalize(q); q=NULL;
    if (first) {
      if (!RCTwoWaySQL(j,error,"BEGIN IMMEDIATE")) goto done;
      it=[truth keyEnumerator];
      while ((key=[it nextObject])) if (!contacts && [[[truth objectForKey:key] objectForKey:ISyncRecordEntityNameKey] isEqual:c->rootEntity] && ![known containsObject:key]) {
        /* Events already created inside an imported calendar belong to this
           account, even if the first two-way session previously failed. Never
           interpret retained remote identities as new local events. */
        BOOL eligible=NO;
        if ([c->rootEntity isEqual:@"com.apple.calendars.Event"]) {
          NSArray *calendars=[[truth objectForKey:key] objectForKey:@"calendar"];
          if ([calendars count]==1 && [[[graph objectForKey:[calendars objectAtIndex:0]] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Calendar"]) {
            sqlite3_stmt *identity=NULL;
            if (sqlite3_prepare_v2(j->db,"SELECT 1 FROM sync_record_ids WHERE 'cal-'||sync_id=? UNION ALL SELECT 1 FROM two_way_aliases WHERE account_id=? AND native_id=? LIMIT 1",-1,&identity,NULL)!=SQLITE_OK) goto sqlError;
            sqlite3_bind_text(identity,1,[key UTF8String],-1,SQLITE_TRANSIENT);
            sqlite3_bind_int64(identity,2,j->account);
            sqlite3_bind_text(identity,3,[key UTF8String],-1,SQLITE_TRANSIENT);
            int identityStep=sqlite3_step(identity); sqlite3_finalize(identity);
            if (identityStep!=SQLITE_ROW && identityStep!=SQLITE_DONE) goto sqlError;
            eligible=identityStep==SQLITE_DONE;
          }
        }
        if (eligible) continue;
        [excluded addObject:key];
        if (!RCTwoWaySQL(j,error,"INSERT OR IGNORE INTO two_way_excluded VALUES(%lld,%Q)",j->account,[key UTF8String])) goto done;
      }
      if (!RCTwoWaySQL(j,error,"INSERT INTO two_way_accounts VALUES(%lld);COMMIT",j->account)) goto done;
    }
    it=[truth keyEnumerator];
    while ((key=[it nextObject])) if ([[[truth objectForKey:key] objectForKey:ISyncRecordEntityNameKey] isEqual:c->rootEntity] &&
        ![known containsObject:key] && ![excluded containsObject:key]) {
      [resources addObject:[NSDictionary dictionaryWithObject:key forKey:@"root"]];
    }
    phase="local mapping and journaling";
    it=[resources objectEnumerator];
    while ((resource=[it nextObject])) {
      NSString *root=[resource objectForKey:@"root"];
      BOOL creating=![resource objectForKey:@"body"];
      if (![truth objectForKey:root]) {
        if (!Attention(j,root,"remote-deletion-disabled",error)) goto done;
        continue;
      }
      NSDictionary *old=[resource objectForKey:@"graph"];
      if (!creating && RCTwoWayGraphsEqual(old,RCTwoWaySubgraph(truth,[old allKeys]))) continue;
      RCError mappingError; RCErrorClear(&mappingError);
      NSMutableDictionary *desired=c->encode(c->context,creating ? nil : resource,truth,root,&mappingError);
      if (!desired) {
        if (mappingError.code) NSLog(@"Two-way mapping deferred: %s",mappingError.message);
        if (!Attention(j,root,"unsupported-local-mapping",error)) goto done;
        continue;
      }
      NSData *body=[desired objectForKey:@"body"];
      if (!creating && [body isEqual:[resource objectForKey:@"body"]]) continue;
      NSString *href=[desired objectForKey:@"href"], *resourceKey=[desired objectForKey:@"key"];
      long long revision=creating ? 0 : [[resource objectForKey:@"revision"] longLongValue], operation=0;
      if (!RCTwoWaySQL(j,error,"BEGIN IMMEDIATE")) goto done;
      if (!creating && !RCWriteJournalSetBase(j,[resourceKey UTF8String],[href UTF8String],
          [[resource objectForKey:@"etag"] UTF8String],[[resource objectForKey:@"body"] bytes],
          [[resource objectForKey:@"body"] length],revision,error)) goto done;
      NSMutableDictionary *receipt=[NSMutableDictionary dictionaryWithDictionary:[desired objectForKey:@"graph"]];
      NSEnumerator *oldIDs=[old keyEnumerator]; NSString *oldID;
      while ((oldID=[oldIDs nextObject])) if (![truth objectForKey:oldID]) [receipt setObject:[NSNull null] forKey:oldID];
      NSString *change=[[NSProcessInfo processInfo] globallyUniqueString];
      if (!RCWriteJournalEnqueue(j,[change UTF8String],[resourceKey UTF8String],[href UTF8String],
          creating ? "create" : "update",revision,[body bytes],[body length],&operation,error) ||
          !SaveIntent(j,operation,receipt,[desired objectForKey:@"paths"],error) ||
          !RCTwoWaySQL(j,error,"DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q;COMMIT",j->account,[root UTF8String])) goto done;
    }
    /* No refusal and no acceptance before verified remote success. Cancellation
       commits neither pending nor unrelated native changes. */
    [session cancelSyncing]; session=nil;
    ok=YES; goto done;
  sqlError:
    RCErrorSet(error,1,"Could not read two-way account state");
  } @catch (NSException *exception) {
    NSLog(@"Two-way Sync Services exception during %s: %@",phase,[exception name]);
    RCErrorSet(error,1,"Two-way Sync Services operation failed during %s (%s)",phase,[[exception name] UTF8String]);
  }
done:
  sqlite3_finalize(q);
  if (!sqlite3_get_autocommit(j->db)) RCTwoWaySQL(j,NULL,"ROLLBACK");
  @try { if (session && ![session isCancelled]) [session cancelSyncing]; }
  @catch (NSException *exception) { (void)exception; ok=NO; RCErrorSet(error,1,"Could not close two-way session"); }
  return ok;
}
int RCTwoWayRunWrites(RCWriteJournal *j, RCHTTPClient *http, const char *type, RCError *error)
{
  long long operation; int count=0;
  if (!http || !RCTwoWayInitialize(j,error)) return -1;
  while (count<100) {
    if (!RCWriteJournalNext(j,time(NULL),&operation,error)) return -1;
    if (!operation) break;
    /* Only this coordinator's PUTs are authorized, never old experimental
       operations or remote deletion. */
    sqlite3_stmt *q=NULL;
    int step=SQLITE_ERROR;
    if (sqlite3_prepare_v2(j->db,"SELECT 1 FROM two_way_intents i JOIN write_operations o ON o.id=i.operation_id "
        "WHERE o.id=? AND o.account_id=? AND o.kind IN ('create','update')",-1,&q,NULL)==SQLITE_OK) {
      sqlite3_bind_int64(q,1,operation); sqlite3_bind_int64(q,2,j->account); step=sqlite3_step(q);
    }
    sqlite3_finalize(q);
    if (step!=SQLITE_ROW) { RCErrorSet(error,1,"Unowned outgoing operation requires inspection"); return -1; }
    count++;
    if (!RCDAVWriterAttempt(j,operation,http,type,time(NULL),error)) return -1;
  }
  return count;
}
