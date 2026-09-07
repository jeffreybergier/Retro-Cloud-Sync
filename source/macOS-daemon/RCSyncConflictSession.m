#import "RCSyncConflictSession.h"
#import "RCSyncRecordEquality.h"

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
    session = [ISyncSession beginSessionWithClient:client entityNames:entities
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
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
          id value=[record objectForKey:property] ?: [NSNull null];
          if (![value isEqual:[expected objectForKey:property]]) {
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
      [session pushChangesFromRecord:[graph objectForKey:key] withIdentifier:key];
    if (![session prepareToPullChangesForEntityNames:entities
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]) {
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
  ISyncSession *session = nil;
  NSArray *entities = RCSyncPullableEntities(client);
  NSEnumerator *it;
  NSString *entity;
  ISyncChange *change;
  BOOL success = NO;
  RCErrorClear(error);
  if (![receipt count] || !UsableClient(client,entities,error)) return NO;
  @try {
    session = [ISyncSession beginSessionWithClient:client entityNames:entities
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
    if (!session) { RCErrorSet(error,1,"Resolution acceptance session is unavailable"); goto done; }
    it = [entities objectEnumerator];
    while ((entity = [it nextObject])) {
      if ([session shouldPushAllRecordsForEntityName:entity] ||
          [session shouldReplaceAllRecordsOnClientForEntityName:entity]) {
        RCErrorSet(error,1,"Resolution acceptance requires resynchronization"); goto done;
      }
    }
    if (![session prepareToPullChangesForEntityNames:entities
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]) {
      RCErrorSet(error,1,"Resolution acceptance is pending"); goto done;
    }
    NSDictionary *current = [[session snapshotOfRecordsInTruth]
        recordsWithIdentifiers:[receipt allKeys]];
    NSMutableDictionary *live=[NSMutableDictionary dictionaryWithDictionary:receipt];
    NSEnumerator *receiptIDs=[receipt keyEnumerator]; NSString *receiptID;
    while ((receiptID=[receiptIDs nextObject])) if ([receipt objectForKey:receiptID]==[NSNull null]) {
      if ([current objectForKey:receiptID]) {
        RCErrorSet(error,1,"A deleted child has reappeared; its change was not acknowledged"); goto done;
      }
      [live removeObjectForKey:receiptID];
    }
    if (!RCNativeGraphsEqual(current,live)) {
      RCErrorSet(error,1,"A newer local change is pending; resolution was not acknowledged");
      goto done;
    }
    it = [session changeEnumeratorForEntityNames:entities];
    while ((change = [it nextObject])) {
      id expected = [receipt objectForKey:[change recordIdentifier]];
      if (expected) {
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
