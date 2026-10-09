#import "RCNativeStore.h"
#import "RCTwoWayInternal.h"
#import "RCAutorelease.h"
#import "RCLogger.h"
static BOOL Accept(void *receiver,NSDictionary *receipt,NSDictionary *scopes,
    BOOL deletion,NSDictionary **newer,RCError *error)
{
  (void)deletion;
  return [(id<RCNativeStore>)receiver acceptReceipt:receipt scopes:scopes newerTruth:newer error:error];
}
/* The native stores supply a durable local baseline instead of Sync Services'
   truth database. Reuse the same lossless encoder, ETag journal and receipts. */
static BOOL RCNativeParticipantsUnchanged(NSDictionary *base,
    NSDictionary *truth,NSString *root,RCError *error)
{
  NSDictionary *graph=[base objectForKey:@"graph"];
  NSString *links[]={@"attendees",@"organizer"};
  for(int k=0;k<2;k++) {
    NSArray *before=[[graph objectForKey:root] objectForKey:links[k]] ?: [NSArray array];
    NSArray *after=[[truth objectForKey:root] objectForKey:links[k]] ?: [NSArray array];
    if(![before isEqual:after]) goto unsafe;
    NSEnumerator *it=[before objectEnumerator]; NSString *identifier;
    while((identifier=[it nextObject]))
      if(!RCTwoWayRecordsEqual([graph objectForKey:identifier],
          [truth objectForKey:identifier])) goto unsafe;
  }
  return YES;
unsafe:
  /* Also defer whole-event deletion: the local invitation is only a projection,
     so its removal must not delete an unseen invitation from iCloud. */
  RCErrorSet(error,1,"EventKit cannot upload invitation deletion or participant changes");
  return NO;
}
static BOOL RCNativeQueue(RCTwoWayContext *c,NSDictionary *base,NSDictionary *truth,
    NSString *root,id<RCNativeStore> native,NSDictionary *observed,RCError *error)
{
  RCWriteJournal *j=&c->journal; BOOL creating=base==nil, deleting=[truth objectForKey:root]==nil;
  if(creating && deleting) { RCErrorSet(error,1,"Unowned native deletion has no publication base"); return NO; }
  if([c->rootEntity isEqual:@"com.apple.calendars.Event"] &&
      !RCNativeParticipantsUnchanged(base,truth,root,error)) return NO;
  NSMutableDictionary *desired=deleting ? RCTwoWayDeletion(base,truth) :
      RCTwoWayEncodeFields(c->encode,c->context,base,truth,root,error);
  if(!desired) { if(!error->code) RCErrorSet(error,1,"Native edit cannot be represented safely"); return NO; }
  if(!RCTwoWaySavePendingFields(j,root,desired,error)) return NO;
  NSData *body=[desired objectForKey:@"body"];
  if(!creating && !deleting && [body isEqual:[base objectForKey:@"body"]]) return YES;
  NSString *href=[desired objectForKey:@"href"], *key=[desired objectForKey:@"key"];
  long long revision=creating ? 0 : [[base objectForKey:@"revision"] longLongValue],operation=0;
  if(!RCTwoWaySQL(j,error,"BEGIN IMMEDIATE")) return NO;
  if(!creating && !RCWriteJournalSetBase(j,[key UTF8String],[href UTF8String],[[base objectForKey:@"etag"] UTF8String],
      [[base objectForKey:@"body"] bytes],[[base objectForKey:@"body"] length],revision,error)) goto failed;
  NSMutableDictionary *receipt=[NSMutableDictionary dictionaryWithDictionary:[desired objectForKey:@"graph"]];
  NSEnumerator *it=[[base objectForKey:@"graph"] keyEnumerator]; NSString *identifier;
  while((identifier=[it nextObject])) if(![truth objectForKey:identifier] && ![receipt objectForKey:identifier]) [receipt setObject:[NSNull null] forKey:identifier];
  NSString *change=[[NSProcessInfo processInfo] globallyUniqueString];
  if(!RCWriteJournalEnqueue(j,[change UTF8String],[key UTF8String],[href UTF8String],deleting ? "delete" : creating ? "create" : "update",
      revision,[body bytes],[body length],&operation,error) ||
      !RCTwoWaySaveIntent(j,operation,receipt,[desired objectForKey:@"paths"],[desired objectForKey:@"fieldScopes"],error) ||
      !RCTwoWaySaveResource(j,operation,base ?: desired,error) ||
      (creating && ![native rememberResource:desired native:observed error:error]) ||
      !RCTwoWaySQL(j,error,"COMMIT")) goto failed;
  return YES;
failed:
  RCTwoWaySQL(j,NULL,"ROLLBACK"); return NO;
}
static BOOL RCNativeBusy(RCWriteJournal *j,NSString *href,BOOL *busy,RCError *error)
{
  sqlite3_stmt *q=NULL; int step=SQLITE_ERROR;
  if(sqlite3_prepare_v2(j->db,"SELECT 1 FROM write_operations WHERE account_id=? AND href=? AND state NOT IN ('acknowledged','cancelled') LIMIT 1",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,[href UTF8String],-1,SQLITE_TRANSIENT); step=sqlite3_step(q);
  }
  sqlite3_finalize(q); *busy=step==SQLITE_ROW;
  if(step!=SQLITE_ROW && step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not check native pending writes"); return NO; }
  return YES;
}
BOOL RCNativeExchange(RCTwoWayContext *c,BOOL twoWay,RCCreateNativeStore create,RCError *error)
{
  RCWriteJournal *j=&c->journal; id<RCNativeStore> native=nil; BOOL ok=NO,all=YES;
  c->didPublish=NO; c->didPublishAll=NO; RCErrorClear(error);
  if(!RCTwoWayInitialize(j,error)) return NO;
  @try {
    native=create(c,error); if(!native || ![native syncContainers:error]) goto done;
    NSMutableDictionary *aliases=RCTwoWayAliases(j,error),*byHref=[NSMutableDictionary dictionary];
    if(!aliases) goto done;
    NSEnumerator *it=[c->resources objectEnumerator]; NSDictionary *resource;
    while((resource=[it nextObject])) [byHref setObject:resource forKey:[resource objectForKey:@"href"]];
    if(twoWay && !RCTwoWayComplete(c,byHref,aliases,Accept,native,error)) goto done;
    NSDictionary *saved=[native savedResources:error]; if(!saved) goto done;
    NSMutableSet *present=[NSMutableSet set];
    it=[c->resources objectEnumerator];
    while((resource=[it nextObject])) {
      NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
      @try {
        if(RCCheckCancellation(error)) goto done;
        NSDictionary *r=RCTwoWayMapResource(resource,aliases); NSString *root=[r objectForKey:@"root"];
        [present addObject:root]; NSDictionary *old=[saved objectForKey:root];
        // EventKit does not expose a complete exception set for a series.
        // Never infer two-way series edits/deletions from its master alone.
        if(twoWay && ([[[[old objectForKey:@"graph"] objectForKey:root] objectForKey:@"recurrences"] count] ||
            [[[[r objectForKey:@"graph"] objectForKey:root] objectForKey:@"recurrences"] count])) {
          if(!RCTwoWayAttention(j,root,"native-series-needs-review",error)) goto done;
          all=NO; continue;
        }
        BOOL busy=NO; if(!RCNativeBusy(j,[r objectForKey:@"href"],&busy,error)) goto done;
        if(busy) { all=NO; continue; }
        NSDictionary *truth=old ? [native readResource:old error:error] : nil; if(old && !truth) goto done;
        if(twoWay && old && !RCTwoWayGraphsEqual([old objectForKey:@"graph"],truth)) {
          /* Pin outgoing work to the last native publication, never the newly
             fetched ETag. A simultaneous remote edit becomes a real conflict. */
          if(!RCNativeQueue(c,old,truth,root,nil,nil,error)) {
            if(!RCTwoWayAttention(j,root,"unsupported-native-edit",error)) goto done;
          }
          all=NO; RCErrorClear(error); continue;
        }
        if(old && [[old objectForKey:@"body"] isEqual:[r objectForKey:@"body"]] &&
            [[old objectForKey:@"etag"] isEqual:[r objectForKey:@"etag"]] &&
            RCTwoWayGraphsEqual([old objectForKey:@"graph"],truth)) continue;
        if(![native canPublishResource:r error:error]) {
          if(!RCTwoWayAttention(j,root,"native-publication-pending",error)) goto done;
          all=NO; RCErrorClear(error); continue;
        }
        if(![native publishResource:r error:error]) {
          RCLogger(RCLogWarning,NULL,"Apply",@"Native resource remains pending: %s",error->message);
          RCTwoWayAttention(j,root,"native-publication-pending",error);
          goto done; /* Never commit a later resource after a failed native edit. */
        }
        if(!RCTwoWaySQL(j,error,"DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason IN ('native-publication-pending','unsupported-native-edit','native-series-needs-review')",j->account,[root UTF8String])) goto done;
      } @catch(id exception) { RCDrainPoolPreservingException(&pool,exception); @throw; }
      @finally { [pool release]; }
    }
    it=[saved objectEnumerator];
    while((resource=[it nextObject])) if(![present containsObject:[resource objectForKey:@"root"]]) {
      if(RCCheckCancellation(error)) goto done;
      /* A mapper omission or history exclusion is not remote deletion. */
      sqlite3_stmt *retained=NULL;
      const char *retainSQL=[c->rootEntity isEqual:@"com.apple.contacts.Contact"] ?
          "SELECT 1 FROM contacts r JOIN collections b ON b.id=r.collection_id WHERE b.account_id=? AND r.href=? AND b.remote_missing=0 AND r.remote_missing=0" :
          "SELECT 1 FROM calendar_resources r JOIN calendars b ON b.id=r.calendar_id WHERE b.account_id=? AND r.href=? AND b.remote_missing=0 AND r.remote_missing=0";
      if(sqlite3_prepare_v2(j->db,retainSQL,-1,&retained,NULL)!=SQLITE_OK) { RCErrorSet(error,1,"Could not verify native removal"); goto done; }
      sqlite3_bind_int64(retained,1,j->account); sqlite3_bind_text(retained,2,[[resource objectForKey:@"href"] UTF8String],-1,SQLITE_TRANSIENT);
      int retainedStep=sqlite3_step(retained); sqlite3_finalize(retained);
      if(retainedStep==SQLITE_ROW) { all=NO; continue; }
      if(retainedStep!=SQLITE_DONE) { RCErrorSet(error,1,"Could not verify native removal"); goto done; }
      BOOL busy=NO; if(!RCNativeBusy(j,[resource objectForKey:@"href"],&busy,error)) goto done;
      if(busy) { all=NO; continue; }
      if(twoWay && [[[[resource objectForKey:@"graph"] objectForKey:[resource objectForKey:@"root"]] objectForKey:@"recurrences"] count]) {
        if(!RCTwoWayAttention(j,[resource objectForKey:@"root"],"native-series-needs-review",error)) goto done;
        all=NO; continue;
      }
      NSDictionary *truth=[native readResource:resource error:error]; if(!truth) goto done;
      if(twoWay && [truth count] && !RCTwoWayGraphsEqual([resource objectForKey:@"graph"],truth)) {
        if(!RCNativeQueue(c,resource,truth,[resource objectForKey:@"root"],nil,nil,error)) {
          if(!RCTwoWayAttention(j,[resource objectForKey:@"root"],"remote-delete-local-edit",error)) goto done;
        }
        all=NO; RCErrorClear(error); continue;
      }
      if(![native removeResource:resource error:error]) goto done;
    }
    if(twoWay) {
      NSArray *newRecords=[native untrackedResources:error]; if(!newRecords) goto done;
      it=[newRecords objectEnumerator];
      while((resource=[it nextObject])) {
        NSString *root=[resource objectForKey:@"root"];
        if([[[[resource objectForKey:@"graph"] objectForKey:root] objectForKey:@"recurrences"] count]) {
          if(!RCTwoWayAttention(j,root,"native-series-needs-review",error)) goto done;
          all=NO; continue;
        }
        if(!RCNativeQueue(c,nil,[resource objectForKey:@"graph"],root,native,resource,error)) {
          if(!RCTwoWayAttention(j,root,"unsupported-native-creation",error)) goto done;
          all=NO; RCErrorClear(error); continue;
        }
        all=NO;
      }
    }
    /* Calendar mapping can retain an older export, but must not report a full
       success while unsupported resources are absent from the native store. */
    if(![c->rootEntity isEqual:@"com.apple.contacts.Contact"]) {
      sqlite3_stmt *q=NULL;
      if(sqlite3_prepare_v2(j->db,"SELECT count(*) FROM calendar_resources r JOIN calendars b ON b.id=r.calendar_id WHERE b.account_id=? AND b.remote_missing=0 AND r.remote_missing=0 AND r.scope_excluded=0",-1,&q,NULL)!=SQLITE_OK) goto done;
      sqlite3_bind_int64(q,1,j->account);
      if(sqlite3_step(q)!=SQLITE_ROW || sqlite3_column_int64(q,0)!=(long long)[c->resources count]) all=NO;
      sqlite3_finalize(q);
    }
    if([c->rootEntity isEqual:@"com.apple.contacts.Contact"]) {
      sqlite3_stmt *q=NULL;
      if(sqlite3_prepare_v2(j->db,"SELECT count(*),sum(r.parse_error IS NOT NULL) FROM contacts r JOIN collections b ON b.id=r.collection_id WHERE b.account_id=? AND b.remote_missing=0 AND r.remote_missing=0",-1,&q,NULL)!=SQLITE_OK) { RCErrorSet(error,1,"Could not verify contact publication"); goto done; }
      sqlite3_bind_int64(q,1,j->account);
      if(sqlite3_step(q)!=SQLITE_ROW || sqlite3_column_int64(q,0)!=(long long)[c->resources count] || sqlite3_column_int64(q,1)) all=NO;
      sqlite3_finalize(q);
    }
    c->didPublish=YES; c->didPublishAll=all; ok=YES;
  } @catch(NSException *exception) {
    RCErrorSet(error,1,"Native store operation failed (%s)",[[exception name] UTF8String]);
  }
done:
  if(!sqlite3_get_autocommit(j->db)) RCTwoWaySQL(j,NULL,"ROLLBACK");
  [native release]; return ok;
}
