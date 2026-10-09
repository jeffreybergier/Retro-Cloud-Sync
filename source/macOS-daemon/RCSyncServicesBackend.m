#import "RCSyncServicesBackend.h"
#import "RCSyncBackend.h"
#import "RCTwoWayNative.h"
#import "RCTwoWayInternal.h"
#import "RCSyncConflictSession.h"
#import "RCSyncServicesBridge.h"
#import "RCCalendarSyncServicesBridge.h"
#import "RCCalendarOperations.h"
#import "RCAutorelease.h"
#import "RCLogger.h"
#include <sys/stat.h>
#include <string.h>

static BOOL Accept(void *receiver, NSDictionary *receipt, NSDictionary *scopes,
    BOOL deletion, NSDictionary **newer, RCError *error)
{
  return deletion ? RCSyncAcceptUpload((ISyncClient *)receiver,receipt,newer,error) :
      RCSyncAcceptMappedUpload((ISyncClient *)receiver,receipt,scopes,newer,error);
}
/* Resolve through the same Sync Services client used for publication. Every
   decision becomes a conditional successor plus an exact native receipt in one
   transaction; replay can never refresh an old operation's precondition. */
static BOOL RecoverConflicts(RCTwoWayContext *c, ISyncClient *client, NSDictionary *byHref,
    NSDictionary *aliases, RCError *error)
{
  RCWriteJournal *j=&c->journal; sqlite3_stmt *q=NULL;
  NSMutableArray *pending=[NSMutableArray array]; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT o.id,i.receipt,i.paths,r.resource FROM write_operations o "
      "JOIN two_way_intents i ON i.operation_id=o.id LEFT JOIN two_way_resources r ON r.operation_id=o.id "
      "WHERE o.account_id=? AND o.state='conflict' ORDER BY o.id",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        [pending addObject:[NSArray arrayWithObjects:
            [NSNumber numberWithLongLong:sqlite3_column_int64(q,0)],RCTwoWayUnarchive(q,1),RCTwoWayUnarchive(q,2),
            sqlite3_column_type(q,3)==SQLITE_NULL ? (id)[NSNull null] : RCTwoWayUnarchive(q,3),nil]];
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read production conflicts"); return NO; }
  NSEnumerator *it=[pending objectEnumerator]; NSArray *item;
  while ((item=[it nextObject])) {
    NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
    @try {
      RCWriteOperation o;
      if (!RCWriteJournalGet(j,[[item objectAtIndex:0] longLongValue],&o,error)) return NO;
      const char *reason="unsupported-conflict-mapping";
      NSDictionary *anchor=[item objectAtIndex:3];
      if (anchor==(id)[NSNull null]) {
        /* Older installations have no saved graph. Reconstruct only where the
           existing projector can prove the published resource's identity. */
        NSDictionary *current=[byHref objectForKey:[NSString stringWithUTF8String:o.href]];
        NSData *body=[NSData dataWithBytes:o.baseBody ?: o.desiredBody length:o.baseBody ? o.baseLength : o.desiredLength];
        anchor=current && c->projectVerified ? c->projectVerified(c->context,current,body,error) : nil;
        if (anchor) anchor=RCTwoWayMapResource(anchor,aliases);
      }
      if (!anchor || !c->projectVerified) goto attention;
      NSMutableDictionary *remote=nil;
      if (o.httpStatus==200 && RCWriteETagIsStrong(o.resultETag)) {
        NSMutableDictionary *importedIDs=[NSMutableDictionary dictionary];
        NSEnumerator *aliasIDs=[aliases keyEnumerator]; NSString *importedID;
        while ((importedID=[aliasIDs nextObject])) [importedIDs setObject:importedID forKey:[aliases objectForKey:importedID]];
        NSDictionary *projected=c->projectVerified(c->context,RCTwoWayMapResource(anchor,importedIDs),
            [NSData dataWithBytes:o.resultBody length:o.resultLength],error);
        if (projected) projected=RCTwoWayMapResource(projected,aliases);
        if (!projected) { reason="conflict-identity-or-mapping-changed"; goto attention; }
        remote=[NSMutableDictionary dictionaryWithDictionary:projected];
        [remote setObject:[NSString stringWithUTF8String:o.resultETag] forKey:@"etag"];
      } else if (o.httpStatus!=404 || !strcmp(o.kind,"create")) {
        reason="unusable-conflict-revision"; goto attention;
      }
      {
        NSMutableSet *targets=[NSMutableSet setWithArray:[[anchor objectForKey:@"graph"] allKeys]];
        if (remote) [targets addObjectsFromArray:[[remote objectForKey:@"graph"] allKeys]];
        NSDictionary *truth=RCSyncResolveResourceConflict(client,remote ? [remote objectForKey:@"graph"] :
            [NSDictionary dictionary],[targets allObjects],error);
        if (!truth) { reason="system-conflict-pending"; goto attention; }
        NSString *root=[anchor objectForKey:@"root"];
        BOOL deleting=![truth objectForKey:root];
        if (deleting && [RCTwoWaySubgraph(truth,[[item objectAtIndex:1] allKeys]) count]) goto attention;
        NSDictionary *base=remote ?: anchor;
        NSMutableDictionary *desired=deleting ? RCTwoWayDeletion(base,truth) :
            RCTwoWayEncodeFields(c->encode,c->context,base,truth,root,error);
        if (!desired) goto attention;
        NSMutableDictionary *receipt=[NSMutableDictionary dictionaryWithDictionary:[desired objectForKey:@"graph"]];
        [targets addObjectsFromArray:[[item objectAtIndex:1] allKeys]];
        NSEnumerator *ids=[targets objectEnumerator]; NSString *key;
        while ((key=[ids nextObject])) if (![truth objectForKey:key] && ![[desired objectForKey:@"graph"] objectForKey:key]) [receipt setObject:[NSNull null] forKey:key];
        NSData *body=[desired objectForKey:@"body"];
        NSData *encoded=[NSKeyedArchiver archivedDataWithRootObject:receipt];
        long long successor=0;
        if (!RCTwoWaySQL(j,error,"BEGIN IMMEDIATE")) { RCWriteOperationClear(&o); return NO; }
        BOOL ok=RCWriteJournalResolveConflict(j,o.id,deleting ? "delete" : remote ? "update" : "create",
            [body bytes],[body length],[encoded bytes],[encoded length],&successor,error) &&
            RCTwoWaySaveIntent(j,successor,receipt,[desired objectForKey:@"paths"],[desired objectForKey:@"fieldScopes"],error) &&
            RCTwoWaySaveResource(j,successor,base,error) && RCTwoWaySavePendingFields(j,root,desired,error) && RCTwoWaySQL(j,error,"COMMIT");
        if (!ok) { RCTwoWaySQL(j,NULL,"ROLLBACK"); RCWriteOperationClear(&o); return NO; }
        RCLogger(RCLogInfo, NULL, "Recovery", @"Conflict decision saved; replacement queued for server verification (operation=%lld, successor=%lld)", o.id, successor);
        RCWriteOperationClear(&o); continue;
      }
  attention:
      RCErrorClear(error);
      if (!RCWriteJournalConflictAttention(j,o.id,reason,error)) { RCWriteOperationClear(&o); return NO; }
      RCLogger(RCLogWarning, NULL, "Recovery", @"Conflict needs attention; local edit preserved (operation=%lld, reason=%s)", o.id, reason);
      RCWriteOperationClear(&o);
    } @catch(id exception) {
      RCDrainPoolPreservingException(&resourcePool,exception); @throw;
    } @finally { [resourcePool release]; }
  }
  return YES;
}
static BOOL Exchange(RCTwoWayContext *c, BOOL twoWay, RCError *error)

{
  (void)twoWay; /* Legacy one-way uses its complete-graph publisher. */
  RCWriteJournal *j=&c->journal;
  ISyncSession *session=nil;
  sqlite3_stmt *q=NULL;
  BOOL ok=NO;
  const char *phase="registration";
  RCErrorClear(error);
  c->didPublish=NO; c->didPublishAll=NO;
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
    NSMutableDictionary *aliases=RCTwoWayAliases(j,error), *byHref=[NSMutableDictionary dictionary];
    NSEnumerator *it=[c->resources objectEnumerator]; NSDictionary *resource;
    while ((resource=[it nextObject])) [byHref setObject:resource forKey:[resource objectForKey:@"href"]];
    phase="verified-write completion";
    if (!aliases || !RCTwoWayComplete(c,byHref,aliases,Accept,client,error)) goto done;
    phase="conflict recovery";
    if (!RecoverConflicts(c,client,byHref,aliases,error)) goto done;
    NSMutableDictionary *graph=[NSMutableDictionary dictionaryWithDictionary:RCTwoWayRemap(c->graph,aliases)];
    NSMutableArray *resources=[NSMutableArray array];
    NSMutableSet *known=[NSMutableSet set], *busy=[NSMutableSet set], *excluded=[NSMutableSet set];
    it=[c->resources objectEnumerator];
    while ((resource=[it nextObject])) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        RCSessionCheck();
        NSDictionary *r=RCTwoWayMapResource(resource,aliases);
        [resources addObject:r]; [known addObject:[r objectForKey:@"root"]];
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
    /* Find unresolved native intent before publishing any newer remote graph. */
    if (sqlite3_prepare_v2(j->db,"SELECT o.href,i.receipt,r.resource FROM write_operations o JOIN two_way_intents i ON i.operation_id=o.id "
        "LEFT JOIN two_way_resources r ON r.operation_id=o.id "
        "WHERE o.account_id=? AND o.state NOT IN ('acknowledged','cancelled')",-1,&q,NULL)!=SQLITE_OK) goto sqlError;
    sqlite3_bind_int64(q,1,j->account); int step;
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        NSString *href=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
        NSDictionary *receipt=RCTwoWayUnarchive(q,1);
        [busy addObjectsFromArray:[receipt allKeys]];
        resource=[byHref objectForKey:href];
        if (resource) [busy addObjectsFromArray:[[RCTwoWayMapResource(resource,aliases) objectForKey:@"graph"] allKeys]];
        NSMutableDictionary *pendingGraph=[NSMutableDictionary dictionaryWithDictionary:receipt];
        if (sqlite3_column_type(q,2)!=SQLITE_NULL) {
          NSDictionary *saved=RCTwoWayUnarchive(q,2);
          [pendingGraph addEntriesFromDictionary:[saved objectForKey:@"graph"]];
          [busy addObjectsFromArray:[[saved objectForKey:@"graph"] allKeys]];
        }
        if (resource) [pendingGraph addEntriesFromDictionary:[RCTwoWayMapResource(resource,aliases) objectForKey:@"graph"]];
        NSEnumerator *pendingRecords=[pendingGraph objectEnumerator]; id pendingRecord;
        while ((pendingRecord=[pendingRecords nextObject])) if ([pendingRecord isKindOfClass:[NSDictionary class]])
          [busy addObjectsFromArray:[pendingRecord objectForKey:@"calendar"] ?: [NSArray array]];
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
    if (step!=SQLITE_DONE) goto sqlError;
    sqlite3_finalize(q); q=NULL;
    if(!contacts && !RCCalendarProtectOperations(j,resources,graph,busy,error)) goto done;
    NSDictionary *published=RCTwoWayPublishedGraph(j,error);
    if (!published) goto done;
    [known addObjectsFromArray:[busy allObjects]];
    [known addObjectsFromArray:[published allKeys]];
    [known addObjectsFromArray:[aliases allValues]];
    /* A deleted/filtered imported identity is not a new native creation, even
       when upgrading an older journal without a publication checkpoint. */
    const char *identitySQL=contacts ?
        "SELECT 'contact-'||c.sync_record_id FROM contacts c JOIN collections b ON b.id=c.collection_id WHERE b.account_id=?" :
        "SELECT 'cal-'||i.sync_id FROM sync_record_ids i JOIN calendar_resources r ON i.owner='resource-'||r.id JOIN calendars c ON c.id=r.calendar_id WHERE c.account_id=?";
    if (sqlite3_prepare_v2(j->db,identitySQL,-1,&q,NULL)!=SQLITE_OK) goto sqlError;
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        NSString *imported=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
        [known addObject:[aliases objectForKey:imported] ?: imported];
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
    if (step!=SQLITE_DONE) goto sqlError;
    sqlite3_finalize(q); q=NULL;
    /* Fast publication leaves unresolved resource snapshots untouched. Keep
       their calendar containers untouched too, including inverse relationships. */
    if ([busy count]) RCLogger(RCLogWarning, NULL, "Apply", @"Preserving %lu unresolved Sync Services records; eligible records can continue", (unsigned long)[busy count]);
    phase="session start";
    session=RCBeginSession(client,entities);
    if (!session) { RCErrorSet(error,1,"Could not begin two-way sync session"); goto done; }
    it=[entities objectEnumerator]; NSString *entity;
    while ((entity=[it nextObject])) if ([session shouldReplaceAllRecordsOnClientForEntityName:entity]) {
      RCErrorSet(error,1,"Two-way sync requires recovery from a truth reset; no uploads queued"); goto done;
    }
    phase="remote graph publication";
    if ([busy count]) {
      it=[entities objectEnumerator];
      while ((entity=[it nextObject])) if ([session shouldPushAllRecordsForEntityName:entity]) {
        RCErrorSet(error,1,"Pending writes require a fast session before resynchronization"); goto done;
      }
    } else [session clientWantsToPushAllRecordsForEntityNames:entities];
    it=[graph keyEnumerator]; NSString *key;
    while ((key=[it nextObject])) if (![busy containsObject:key])
      RCSessionPush(session,[graph objectForKey:key],key);
    if ([busy count]) {
      it=[published keyEnumerator];
      while ((key=[it nextObject])) if (![graph objectForKey:key] && ![busy containsObject:key])
        RCSessionDelete(session,key);
    }
    phase="local change collection";
    if (!RCPrepareToPull(session,pullEntities)) {
      RCErrorSet(error,1,"Two-way merge is pending"); goto done;
    }
    NSMutableDictionary *checkpoint=[NSMutableDictionary dictionaryWithDictionary:graph];
    it=[busy objectEnumerator];
    while ((key=[it nextObject])) {
      if ([published objectForKey:key]) [checkpoint setObject:[published objectForKey:key] forKey:key];
      else [checkpoint removeObjectForKey:key];
    }
    BOOL publishedAll=[busy count]==0;
    NSMutableSet *localDeletes=[NSMutableSet set];
    NSEnumerator *changes=[session changeEnumeratorForEntityNames:pullEntities]; ISyncChange *changeRecord;
    while ((changeRecord=[changes nextObject])) if ([changeRecord type]==ISyncChangeTypeDelete)
      [localDeletes addObject:[changeRecord recordIdentifier]];
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
      /* Exceptions belong to their master's conditional PUT, never a new href. */
      if (!contacts && [[[truth objectForKey:key] objectForKey:@"main event"] count]) {
        NSArray *parents=[[truth objectForKey:key] objectForKey:@"main event"];
        BOOL owned=NO; NSEnumerator *owners=[resources objectEnumerator]; NSDictionary *owner;
        while ((owner=[owners nextObject])) if ([parents count]==1 &&
            [[owner objectForKey:@"root"] isEqual:[parents objectAtIndex:0]] && [owner objectForKey:@"body"] &&
            [[[truth objectForKey:[parents objectAtIndex:0]] objectForKey:@"detached events"] containsObject:key]) owned=YES;
        if (!owned && !RCTwoWayAttention(j,key,"unsupported-detached-parent",error)) goto done;
        continue;
      }
      [resources addObject:[NSDictionary dictionaryWithObject:key forKey:@"root"]];
    }
    if(!contacts && !RCCalendarCollectOperations(j,truth,graph,resources,busy,error)) goto done;
    phase="local mapping and journaling";
    it=[resources objectEnumerator];
    while ((resource=[it nextObject])) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        RCSessionCheck();
        NSString *root=[resource objectForKey:@"root"];
        if ([busy containsObject:root]) continue;
        BOOL creating=![resource objectForKey:@"body"];
        BOOL deleting=![truth objectForKey:root];
        if (deleting && ![localDeletes containsObject:root]) {
          if (!RCTwoWayAttention(j,root,"missing-native-delete-receipt",error)) goto done;
          continue;
        }
        NSDictionary *old=[resource objectForKey:@"graph"];
        if (!creating && RCTwoWayGraphsEqual(old,RCTwoWaySubgraph(truth,[old allKeys]))) {
          if (sqlite3_prepare_v2(j->db,"SELECT 1 FROM two_way_pending_fields WHERE account_id=? AND root_id=?",-1,&q,NULL)!=SQLITE_OK) goto sqlError;
          sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
          step=sqlite3_step(q); sqlite3_finalize(q); q=NULL;
          if (step==SQLITE_DONE) continue;
          if (step!=SQLITE_ROW) goto sqlError;
        }
        RCError mappingError; RCErrorClear(&mappingError);
        NSMutableDictionary *desired=deleting ? RCTwoWayDeletion(resource,truth) :
            RCTwoWayEncodeFields(c->encode,c->context,creating ? nil : resource,truth,root,&mappingError);
        if (!desired) {
          RCLogger(RCLogWarning, NULL, "Apply", @"Local edit cannot be uploaded (resource=%@, record=%@, action=%s): %s",
              [resource objectForKey:@"key"] ?: @"new",root,creating ? "create" : deleting ? "delete" : "update",
              mappingError.code ? mappingError.message : deleting ? "RCTwoWayDeletion would discard related native records" : "Mapper returned no representable resource");
          if (!RCTwoWayAttention(j,root,"unsupported-local-mapping",error)) goto done;
          continue;
        }
        if (!RCTwoWaySavePendingFields(j,root,desired,error)) goto done;
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
        while ((oldID=[oldIDs nextObject])) if (![truth objectForKey:oldID] && ![[desired objectForKey:@"graph"] objectForKey:oldID]) [receipt setObject:[NSNull null] forKey:oldID];
        NSString *change=[[NSProcessInfo processInfo] globallyUniqueString];
        if (!RCWriteJournalEnqueue(j,[change UTF8String],[resourceKey UTF8String],[href UTF8String],
            deleting ? "delete" : creating ? "create" : "update",revision,[body bytes],[body length],&operation,error) ||
            !RCTwoWaySaveIntent(j,operation,receipt,[desired objectForKey:@"paths"],[desired objectForKey:@"fieldScopes"],error) ||
            !RCTwoWaySaveResource(j,operation,creating ? desired : resource,error) ||
            !RCTwoWaySQL(j,error,"DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason<>'unsupported-fields';COMMIT",j->account,[root UTF8String])) goto done;
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
    /* Mingling completed the push. Close the pull without accepting or refusing
       pending native changes, so they remain available on the next session.
       Only checkpoint publication after all work and session closure succeed. */
    RCSessionCheck();
    [session cancelSyncing]; session=nil;
    if (!RCTwoWaySavePublished(j,checkpoint,error)) goto done;
    c->didPublish=YES; c->didPublishAll=publishedAll;
    ok=YES; goto done;
  sqlError:
    RCErrorSet(error,1,"Could not read two-way account state");
  } @catch (NSException *exception) {
    RCErrorSet(error,1,"Two-way Sync Services operation failed during %s (%s)",phase,[[exception name] UTF8String]);
  }
done:
  sqlite3_finalize(q);
  if (!sqlite3_get_autocommit(j->db)) RCTwoWaySQL(j,NULL,"ROLLBACK");
  @try { if (session && ![session isCancelled]) [session cancelSyncing]; }
  @catch (NSException *exception) { (void)exception; ok=NO; RCErrorSet(error,1,"Could not close two-way session"); }
  return ok;
}

int RCSyncServicesTwoWayContacts(RCContactStore *store,const char *description,long *count,RCError *error)
{ return RCExchangeContacts(store,description,Exchange,YES,count,error); }
int RCSyncServicesTwoWayCalendars(RCCalendarStore *store,const char *description,long *count,RCError *error)
{ return RCExchangeCalendars(store,description,Exchange,NO,YES,count,error); }
static int Contacts(RCContactStore *store,const char *description,BOOL twoWay,long *count,RCError *error)
{
  return twoWay ? RCSyncServicesTwoWayContacts(store,description,count,error) :
      RCSyncServicesPushContacts(store,description,count,error);
}
static int Calendars(RCCalendarStore *store,const char *description,BOOL twoWay,long *count,RCError *error)
{
  return twoWay ? RCSyncServicesTwoWayCalendars(store,description,count,error) :
      RCSyncServicesPushCalendars(store,description,0,count,error);
}
static void Request(BOOL contacts,BOOL calendars) { (void)contacts; (void)calendars; }
static BOOL Wait(BOOL contacts,RCError *error)
{ (void)contacts; RCErrorClear(error); return !RCCheckCancellation(error); }
const RCSyncBackend RCSyncServicesBackend = { "mac-syncservices", Request, Wait, Contacts, Calendars };

BOOL RCSyncServicesExchange(RCTwoWayContext *context,RCError *error)
{ return Exchange(context,YES,error); }
