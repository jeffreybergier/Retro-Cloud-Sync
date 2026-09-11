#import "RCSyncConflictSession.h"
#import "RCSyncRecordEquality.h"
#import "RCSyncFieldScope.h"

static BOOL UsableClient(ISyncClient *client, NSArray *entities, RCError *error)
{
  NSEnumerator *it = [entities objectEnumerator];
  NSString *entity;
  if (!client || ![entities count]) {
    RCErrorSet(error,1,"Conflict recovery has no enabled Sync Services client");
    return NO;
  }
  while ((entity = [it nextObject])) {
    if (![client canPushChangesForEntityName:entity] ||
        ![client canPullChangesForEntityName:entity]) {
      RCErrorSet(error,1,"Conflict recovery requires a two-way Sync Services client");
      return NO;
    }
  }
  return YES;
}

NSDictionary *RCSyncResolveConflict(ISyncClient *client,
    NSDictionary *graph, NSArray *targets, RCError *error)
{
  return RCSyncResolveConflictWithIntent(client,graph,targets,nil,error);
}

NSDictionary *RCSyncResolveConflictWithIntent(ISyncClient *client,
    NSDictionary *graph, NSArray *targets, NSDictionary *expectedLocal, RCError *error)
{
  ISyncSession *session = nil;
  NSDictionary *result = nil;
  NSArray *entities = RCSyncPullableEntities(client);
  NSEnumerator *it;
  NSString *key;
  RCErrorClear(error);
  if (!graph || ![targets count] || !UsableClient(client,entities,error)) return nil;
  /* Validate before starting: a partial/invalid graph must never be mistaken
     for the full inventory when the engine forces slow sync. */
  it = [graph keyEnumerator];
  while ((key = [it nextObject])) {
    NSDictionary *record = [graph objectForKey:key];
    if (![record isKindOfClass:[NSDictionary class]] ||
        ![entities containsObject:[record objectForKey:ISyncRecordEntityNameKey]]) {
      RCErrorSet(error,1,"Conflict graph contains an unsupported entity"); return nil;
    }
  }
  it = [targets objectEnumerator];
  while ((key = [it nextObject])) if (![graph objectForKey:key]) {
    RCErrorSet(error,1,"Conflict target is absent from the remote graph"); return nil;
  }
  @try {
    session = RCBeginSession(client,entities);
    if (!session) { RCErrorSet(error,1,"Conflict sync session is unavailable"); goto done; }
    if ([expectedLocal count]) {
      NSDictionary *snapshot=[[session snapshotOfRecordsInTruth]
          recordsWithIdentifiers:[expectedLocal allKeys]];
      NSEnumerator *ids=[expectedLocal keyEnumerator];
      NSString *identifier;
      while ((identifier=[ids nextObject])) {
        NSDictionary *record=[snapshot objectForKey:identifier];
        NSDictionary *expected=[expectedLocal objectForKey:identifier];
        NSEnumerator *properties=[expected keyEnumerator];
        NSString *property;
        if (!record) { RCErrorSet(error,1,"Pending local conflict intent is unavailable"); goto done; }
        while ((property=[properties nextObject])) {
          id value=[record objectForKey:property], wanted=[expected objectForKey:property];
          /* NSNull here is a field-deletion intent, not a deleted record. */
          if (wanted==[NSNull null]) wanted=nil;
          if (!RCNativePropertyValuesEqual([record objectForKey:ISyncRecordEntityNameKey],property,value,wanted)) {
            RCErrorSet(error,1,"Pending local conflict intent has changed"); goto done;
          }
        }
      }
    }
    it = [entities objectEnumerator];
    while ((key = [it nextObject])) if ([session shouldReplaceAllRecordsOnClientForEntityName:key] ||
        ![session shouldPushChangesForEntityName:key]) {
      RCErrorSet(error,1,"Conflict recovery requires a complete resynchronization"); goto done;
    }
    /* Complete records also work in fast mode: the engine compares them to its
       snapshot. We never refresh/reset that snapshot to suppress a conflict. */
    it = [graph keyEnumerator];
    while ((key = [it nextObject]))
      RCSessionPush(session,[graph objectForKey:key],key);
    if (!RCPrepareToPull(session,entities)) {
      RCErrorSet(error,1,"Conflict resolution is pending in Sync Services"); goto done;
    }
    /* A remote-winning resolution need not appear in the change enumerator.
       Read the post-mingling snapshot, never infer a decision from no changes. */
    result = [[session snapshotOfRecordsInTruth] recordsWithIdentifiers:targets];
    if ([result count] != [targets count]) {
      result = nil;
      RCErrorSet(error,1,"Conflict target was deleted, filtered, or is unresolved");
    }
    result = [[result copy] autorelease];
  } @catch (NSException *exception) {
    (void)exception;
    result = nil;
    RCErrorSet(error,1,"Sync Services could not reconcile the conflict");
  }
done:
  /* Unlike refusing changes, cancelling keeps them eligible for the next fast
     pull. The push/mingling phase may already have committed; replay is safe. */
  @try { if (session && ![session isCancelled]) [session cancelSyncing]; }
  @catch (NSException *exception) { (void)exception; result=nil;
    RCErrorSet(error,1,"Could not close the conflict sync session"); }
  return result;
}

BOOL RCSyncAcceptConflictResolution(ISyncClient *client,
    NSDictionary *receipt, RCError *error)
{
  return RCSyncAcceptUpload(client,receipt,NULL,error);
}
BOOL RCSyncAcceptUpload(ISyncClient *client, NSDictionary *receipt,
    NSDictionary **newerTruth, RCError *error)
{
  return RCSyncAcceptMappedUpload(client,receipt,nil,newerTruth,error);
}
BOOL RCSyncAcceptMappedUpload(ISyncClient *client, NSDictionary *receipt, NSDictionary *scopes,
    NSDictionary **newerTruth, RCError *error)
{
  ISyncSession *session = nil;
  NSArray *entities = RCSyncPullableEntities(client);
  NSEnumerator *it;
  NSString *entity;
  ISyncChange *change;
  BOOL success = NO;
  RCErrorClear(error);
  if (newerTruth) *newerTruth=nil;
  if (![receipt count] || !UsableClient(client,entities,error)) return NO;
  @try {
    session = RCBeginSession(client,entities);
    if (!session) { RCErrorSet(error,1,"Resolution acceptance session is unavailable"); goto done; }
    it = [entities objectEnumerator];
    while ((entity = [it nextObject])) {
      if ([session shouldPushAllRecordsForEntityName:entity] ||
          [session shouldReplaceAllRecordsOnClientForEntityName:entity]) {
        RCErrorSet(error,1,"Resolution acceptance requires resynchronization"); goto done;
      }
    }
    if (!RCPrepareToPull(session,entities)) {
      RCErrorSet(error,1,"Resolution acceptance is pending"); goto done;
    }
    NSDictionary *current = [[session snapshotOfRecordsInTruth]
        recordsWithIdentifiers:[receipt allKeys]];
    if (!RCNativeScopeMatches(current,receipt,scopes)) {
      if (newerTruth) {
        NSMutableDictionary *truth=[NSMutableDictionary dictionary];
        NSEnumerator *names=[entities objectEnumerator]; NSString *name;
        while ((name=[names nextObject])) [truth addEntriesFromDictionary:
            [[session snapshotOfRecordsInTruth] recordsWithMatchingAttributes:
            [NSDictionary dictionaryWithObject:name forKey:ISyncRecordEntityNameKey]]];
        *newerTruth=[[truth copy] autorelease];
      }
      RCErrorSet(error,1,"A newer local change is pending; resolution was not acknowledged");
      goto done;
    }
    it = [session changeEnumeratorForEntityNames:entities];
    while ((change = [it nextObject])) {
      id expected = [receipt objectForKey:[change recordIdentifier]];
      if (expected) {
        /* Sync Services accepts whole records. Never accept an unsupported
           field just to acknowledge a supported one on that same record. */
        NSArray *fields=[scopes objectForKey:[change recordIdentifier]];
        if (fields && (![fields count] || (expected!=[NSNull null] &&
            !RCNativeRecordsEqual([current objectForKey:[change recordIdentifier]],expected)))) continue;
        if (fields && expected!=[NSNull null]) {
          BOOL outsideScope=NO;
          NSEnumerator *properties=[[change changes] objectEnumerator]; NSDictionary *property;
          while ((property=[properties nextObject])) if (![fields containsObject:[property objectForKey:ISyncChangePropertyNameKey]]) outsideScope=YES;
          if (outsideScope) continue; /* Includes unsupported property clears. */
        }
        if ((expected==[NSNull null] && [change type]!=ISyncChangeTypeDelete) ||
            (expected!=[NSNull null] && ([change type]==ISyncChangeTypeDelete || !RCNativeRecordsEqual([change record],expected)))) {
          RCErrorSet(error,1,"Resolution changed during acceptance"); goto done;
        }
        [session clientAcceptedChangesForRecordWithIdentifier:[change recordIdentifier]
            formattedRecord:nil newRecordIdentifier:nil];
      }
    }
    [session clientCommittedAcceptedChanges];
    /* Cancel the remaining pull so unrelated changes stay pending. Accepted
       targets are already committed and will not be accepted a second time. */
    [session cancelSyncing]; session=nil;
    success=YES;
  } @catch (NSException *exception) { (void)exception;
    RCErrorSet(error,1,"Sync Services could not accept the verified resolution"); }
done:
  @try { if (session && ![session isCancelled]) [session cancelSyncing]; }
  @catch (NSException *exception) { (void)exception; success=NO;
    RCErrorSet(error,1,"Could not close resolution acceptance session"); }
  return success;
}

NSDictionary *RCSyncResolveResourceConflict(ISyncClient *client, NSDictionary *remote,
    NSArray *targets, RCError *error)
{
  ISyncSession *session=nil; NSDictionary *result=nil;
  NSArray *entities=RCSyncPullableEntities(client);
  if (!remote || ![targets count] || !UsableClient(client,entities,error)) return nil;
  @try {
    session=RCBeginSession(client,entities);
    if (!session) { RCErrorSet(error,1,"Conflict session unavailable"); goto done; }
    NSEnumerator *it=[entities objectEnumerator]; NSString *key;
    while ((key=[it nextObject])) if ([session shouldPushAllRecordsForEntityName:key] ||
        [session shouldReplaceAllRecordsOnClientForEntityName:key] || ![session shouldPushChangesForEntityName:key]) {
      RCErrorSet(error,1,"Resource conflict requires a fast session; reset needs recovery"); goto done;
    }
    /* Publish only this operation's verified remote revision. Other pending
       resources and calendar containers retain their server snapshots. */
    it=[targets objectEnumerator];
    while ((key=[it nextObject])) {
      NSDictionary *record=[remote objectForKey:key];
      if (record) RCSessionPush(session,record,key);
      else RCSessionDelete(session,key);
    }
    if (!RCPrepareToPull(session,entities)) {
      RCErrorSet(error,1,"System conflict resolution is pending"); goto done;
    }
    NSMutableDictionary *truth=[NSMutableDictionary dictionary];
    it=[entities objectEnumerator];
    while ((key=[it nextObject])) [truth addEntriesFromDictionary:[[session snapshotOfRecordsInTruth]
        recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:key forKey:ISyncRecordEntityNameKey]]];
    result=[[truth copy] autorelease];
  } @catch(NSException *exception) { (void)exception;
    RCErrorSet(error,1,"System resource conflict resolution failed"); result=nil; }
done:
  @try { if (session && ![session isCancelled]) [session cancelSyncing]; }
  @catch(NSException *exception) { (void)exception; result=nil;
    RCErrorSet(error,1,"Could not close resource conflict session"); }
  return result;
}

/* Apple supports asynchronous session negotiation and mingling.
   Keep the callback target alive until delivery, including late cancellation
   callbacks. A cancelled request that never calls back retains only this small
   target until process exit, never a live store or worker pointer. */
@interface RCSessionStartWaiter : NSObject {
 @public
  BOOL done;
  BOOL abandoned;
  BOOL cancelLateSession;
  ISyncSession *session;
}
- (void)client:(ISyncClient *)client session:(ISyncSession *)value;
@end
@implementation RCSessionStartWaiter
- (void)client:(ISyncClient *)client session:(ISyncSession *)value
{
  (void)client;
  @synchronized(self) {
    if(done) return;
    done=YES;
    if (abandoned) {
      @try { if(value && cancelLateSession) [value cancelSyncing]; }
      @catch(NSException *exception) { /* No caller owns this late session. */ }
    } else session=[value retain];
  }
  [self autorelease]; /* outstanding callback ownership */
}
- (void)dealloc { [session release]; [super dealloc]; }
@end
void RCSessionCheck(void)
{
  if(RCStopRequested) [NSException raise:@"RCShutdownRequested" format:@"Shutdown requested"];
}
ISyncSession *RCBeginSession(ISyncClient *client, NSArray *entities)
{
  RCSessionCheck();
  RCSessionStartWaiter *waiter=[[RCSessionStartWaiter alloc] init];
  waiter->cancelLateSession=YES;
  ISyncSession *result=nil;
  BOOL submitted=NO;
  @try {
    [waiter retain];
    @try {
      [ISyncSession beginSessionInBackgroundWithClient:client entityNames:entities
          target:waiter selector:@selector(client:session:)];
      submitted=YES;
    } @catch(NSException *exception) { [waiter release]; @throw; }
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:60];
    for(;;) {
      @synchronized(waiter) {
        if(waiter->done) { result=[[waiter->session retain] autorelease]; break; }
        if(RCStopRequested || [deadline timeIntervalSinceNow]<=0) { waiter->abandoned=YES; break; }
      }
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if(RCStopRequested && result) { [result cancelSyncing]; result=nil; }
  } @finally {
    @synchronized(waiter) { waiter->abandoned=YES; }
    if(submitted && !result) [ISyncSession cancelPreviousBeginSessionWithClient:client];
    [waiter release];
  }
  /* If cancellation races a successful return, hand ownership to the caller
     so its normal session cleanup can close it at the next checkpoint. */
  if(!result) RCSessionCheck();
  return result;
}
BOOL RCPrepareToPull(ISyncSession *session, NSArray *entities)
{
  RCSessionCheck();
  RCSessionStartWaiter *waiter=[[RCSessionStartWaiter alloc] init];
  BOOL submitted=NO, ready=NO;
  @try {
    [waiter retain];
    @try {
      [session prepareToPullChangesInBackgroundForEntityNames:entities
          target:waiter selector:@selector(client:session:)];
      submitted=YES;
    } @catch(NSException *exception) { [waiter release]; @throw; }
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:60];
    for(;;) {
      @synchronized(waiter) {
        if(waiter->done) { ready=waiter->session!=nil; break; }
        if(RCStopRequested || [deadline timeIntervalSinceNow]<=0) break;
      }
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
  } @finally {
    @synchronized(waiter) { waiter->abandoned=YES; }
    /* Only the owning thread closes the live session. Late callbacks merely
       discard their result; they must not touch a session being cancelled. */
    @try { if(submitted && (!ready || RCStopRequested) && ![session isCancelled]) [session cancelSyncing]; }
    @finally { [waiter release]; }
  }
  RCSessionCheck();
  return ready;
}
