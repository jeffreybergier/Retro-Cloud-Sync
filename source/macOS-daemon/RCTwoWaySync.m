#import "RCLogger.h"
#import "RCTwoWaySync.h"
#import "RCSyncConflictSession.h"
#import "RCSyncRecordEquality.h"
#include "RCDAVWriter.h"
#include <sys/stat.h>
#include <stdarg.h>
#include <time.h>
#include <string.h>

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
      "CREATE TABLE IF NOT EXISTS two_way_resources(operation_id INTEGER PRIMARY KEY,resource BLOB NOT NULL);"
      "CREATE TABLE IF NOT EXISTS two_way_field_scopes(operation_id INTEGER PRIMARY KEY,fields BLOB NOT NULL);"
      "CREATE TABLE IF NOT EXISTS two_way_pending_fields(account_id INTEGER NOT NULL,root_id TEXT NOT NULL,fields BLOB NOT NULL,PRIMARY KEY(account_id,root_id));"
      "CREATE TABLE IF NOT EXISTS two_way_detached(operation_id INTEGER PRIMARY KEY);"
      "CREATE TABLE IF NOT EXISTS two_way_publications(account_id INTEGER PRIMARY KEY,graph BLOB NOT NULL);"
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
                       NSDictionary *paths, NSDictionary *scopes, RCError *error)
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
  if (ok && scopes) {
    NSData *data=[NSKeyedArchiver archivedDataWithRootObject:scopes];
    q=NULL; ok=NO;
    if (sqlite3_prepare_v2(j->db,"INSERT INTO two_way_field_scopes VALUES(?,?)",-1,&q,NULL)==SQLITE_OK) {
      sqlite3_bind_int64(q,1,operation); sqlite3_bind_blob(q,2,[data bytes],(int)[data length],SQLITE_TRANSIENT);
      ok=sqlite3_step(q)==SQLITE_DONE;
    }
    sqlite3_finalize(q);
  }
  if (!ok) RCErrorSet(error,1,"Could not commit native write receipt");
  return ok;
}
/* Stored alongside the intent, including for deletes whose receipt has no live
   records. It anchors recovery to the original UID and native child identities. */
static BOOL SaveResource(RCWriteJournal *j, long long operation, NSDictionary *resource, RCError *error)
{
  NSData *data=[NSKeyedArchiver archivedDataWithRootObject:resource];
  sqlite3_stmt *q=NULL; BOOL ok=NO;
  if (sqlite3_prepare_v2(j->db,"INSERT INTO two_way_resources VALUES(?,?)",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,operation);
    sqlite3_bind_blob(q,2,[data bytes],(int)[data length],SQLITE_TRANSIENT);
    ok=sqlite3_step(q)==SQLITE_DONE;
  }
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(error,1,"Could not save outgoing resource identity");
  return ok;
}
static NSMutableDictionary *Deletion(NSDictionary *resource, NSDictionary *truth)
{
  /* A recurrence exception or orphaned child is not a whole-resource delete. */
  NSEnumerator *it=[[resource objectForKey:@"graph"] keyEnumerator]; NSString *key;
  while ((key=[it nextObject])) if ([truth objectForKey:key]) return nil;
  NSMutableDictionary *desired=[NSMutableDictionary dictionaryWithDictionary:resource];
  [desired removeObjectForKey:@"body"];
  [desired setObject:[NSDictionary dictionary] forKey:@"graph"];
  return desired;
}
static NSDictionary *PublishedGraph(RCWriteJournal *j, RCError *error)
{
  sqlite3_stmt *q=NULL; NSDictionary *graph=nil;
  if (sqlite3_prepare_v2(j->db,"SELECT graph FROM two_way_publications WHERE account_id=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); int step=sqlite3_step(q);
    if (step==SQLITE_ROW) graph=Unarchive(q,0);
    else if (step==SQLITE_DONE) graph=[NSDictionary dictionary];
  }
  sqlite3_finalize(q);
  if (!graph) RCErrorSet(error,1,"Could not read two-way publication checkpoint");
  return graph;
}
static BOOL SavePublished(RCWriteJournal *j, NSDictionary *graph, RCError *error)
{
  NSData *data=[NSKeyedArchiver archivedDataWithRootObject:graph]; sqlite3_stmt *q=NULL; BOOL ok=NO;
  if (sqlite3_prepare_v2(j->db,"INSERT OR REPLACE INTO two_way_publications VALUES(?,?)",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); sqlite3_bind_blob(q,2,[data bytes],(int)[data length],SQLITE_TRANSIENT);
    ok=sqlite3_step(q)==SQLITE_DONE;
  }
  sqlite3_finalize(q);
  if (!ok) RCErrorSet(error,1,"Could not checkpoint two-way publication");
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
  const char *description = "Local change cannot be applied safely; edit preserved";
  if (!strcmp(reason,"verified-write-awaits-matching-mirror"))
    description = "Server change verified; waiting for a matching download";
  else if (!strcmp(reason,"verified-write-awaits-local-acceptance"))
    description = "Server change verified; waiting for local acknowledgement";
  else if (!strcmp(reason,"verified-delete-awaits-completion"))
    description = "Server deletion verified; local completion pending";
  else if (!strcmp(reason,"unsupported-local-mapping"))
    description = "Local edit uses an unsupported feature; edit preserved";
  else if (!strcmp(reason,"missing-native-delete-receipt"))
    description = "Local deletion is not confirmed; server record preserved";
  else if (!strcmp(reason,"unsupported-detached-parent"))
    description = "Recurring event edit has no supported parent; edit preserved";
  RCLogger(RCLogWarning, NULL, "Recovery", @"%s (record=%@, reason=%s)",description,root,reason);
  return RCTwoWaySQL(j,error,"INSERT OR REPLACE INTO two_way_attention VALUES(%lld,%Q,%Q)",
      j->account,[root UTF8String],reason);
}
static BOOL SavePendingFields(RCWriteJournal *j, NSString *root, NSDictionary *desired, RCError *error)
{
  NSMutableDictionary *fields=[NSMutableDictionary dictionaryWithDictionary:[desired objectForKey:@"pendingFields"] ?: [NSDictionary dictionary]];
  sqlite3_stmt *q=NULL; NSDictionary *previous=nil; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT fields FROM two_way_pending_fields WHERE account_id=? AND root_id=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
    step=sqlite3_step(q); if (step==SQLITE_ROW) previous=Unarchive(q,0);
  }
  sqlite3_finalize(q); q=NULL;
  if (step!=SQLITE_ROW && step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read pending fields"); return NO; }
  /* A previously observed opaque field becoming absent is not evidence that
     its remote representation was deleted. Retain that pending tombstone until
     a mapper can represent the field (or the whole resource is deleted). */
  NSEnumerator *priorIDs=[previous keyEnumerator]; NSString *priorID;
  while ((priorID=[priorIDs nextObject])) {
    NSDictionary *represented=[[desired objectForKey:@"graph"] objectForKey:priorID];
    if (!represented) continue;
    NSArray *known=[[desired objectForKey:@"knownFields"] objectForKey:priorID];
    NSMutableSet *names=[NSMutableSet setWithArray:[fields objectForKey:priorID] ?: [NSArray array]];
    NSEnumerator *priorFields=[[previous objectForKey:priorID] objectEnumerator]; NSString *name;
    while ((name=[priorFields nextObject])) if (![name isEqual:@"record deletion"] && ![known containsObject:name] && ![represented objectForKey:name]) [names addObject:name];
    if ([names count]) [fields setObject:[[names allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:priorID];
  }
  if (![fields count]) return RCTwoWaySQL(j,error,
      "DELETE FROM two_way_pending_fields WHERE account_id=%lld AND root_id=%Q;"
      "DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason IN ('unsupported-fields','unsupported-local-mapping')",
      j->account,[root UTF8String],j->account,[root UTF8String]);
  if ([previous isEqual:fields]) return YES;
  NSData *data=[NSKeyedArchiver archivedDataWithRootObject:fields]; BOOL ok=NO;
  if (sqlite3_prepare_v2(j->db,"INSERT OR REPLACE INTO two_way_pending_fields VALUES(?,?,?)",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,3,[data bytes],(int)[data length],SQLITE_TRANSIENT); ok=sqlite3_step(q)==SQLITE_DONE;
  }
  sqlite3_finalize(q);
  if (!ok || !RCTwoWaySQL(j,error,"INSERT OR REPLACE INTO two_way_attention VALUES(%lld,%Q,'unsupported-fields')",j->account,[root UTF8String])) {
    if (!ok) RCErrorSet(error,1,"Could not save pending fields"); return NO;
  }
  NSEnumerator *ids=[[[fields allKeys] sortedArrayUsingSelector:@selector(compare:)] objectEnumerator]; NSString *identifier;
  while ((identifier=[ids nextObject])) RCLogger(RCLogWarning,NULL,"Apply",
      @"Local fields remain unsynced; supported edits can continue (record=%@, fields=%@)",identifier,[[fields objectForKey:identifier] componentsJoinedByString:@", "]);
  return YES;
}
/* Retire the verified upload and replan the newer native revision atomically.
   Any successor uses the verified upload, never a later remote ETag. */
static BOOL QueueSuccessor(RCTwoWayContext *c, RCWriteOperation *o, NSDictionary *verified,
    NSDictionary *aliases, NSDictionary *truth, RCError *error)
{
  RCWriteJournal *j=&c->journal;
  NSDictionary *base=MapResource(verified,aliases);
  NSString *root=[base objectForKey:@"root"];
  BOOL deleting=![truth objectForKey:root];
  NSMutableDictionary *desired=deleting ? Deletion(base,truth) : RCTwoWayEncodeFields(c->encode,c->context,base,truth,root,error);
  if (!desired) return NO;
  NSMutableDictionary *receipt=[NSMutableDictionary dictionaryWithDictionary:[desired objectForKey:@"graph"]];
  NSEnumerator *ids=[[base objectForKey:@"graph"] keyEnumerator]; NSString *identifier;
  while ((identifier=[ids nextObject])) if (![truth objectForKey:identifier] && ![[desired objectForKey:@"graph"] objectForKey:identifier]) [receipt setObject:[NSNull null] forKey:identifier];
  NSData *body=[desired objectForKey:@"body"];
  long long operation=0, revision=o->localRevision ?: 1;
  NSString *change=[NSString stringWithFormat:@"two-way-successor:%lld",o->id];
  if (!RCTwoWaySQL(j,error,"BEGIN IMMEDIATE")) return NO;
  /* A newer value can reveal a representation-specific limitation. If its
     projection adds no server changes, retain its pending fields without
     writing the already verified body again. */
  BOOL unchanged=!deleting && [body isEqual:[base objectForKey:@"body"]];
  BOOL ok=RCWriteJournalSetBase(j,o->resourceKey,o->href,o->resultETag,o->resultBody,o->resultLength,revision,error) &&
      RCWriteJournalAcknowledge(j,o->id,error) &&
      (unchanged || (RCWriteJournalEnqueue(j,[change UTF8String],o->resourceKey,o->href,
          deleting ? "delete" : "update",revision,[body bytes],[body length],&operation,error) &&
      SaveIntent(j,operation,receipt,[desired objectForKey:@"paths"],[desired objectForKey:@"fieldScopes"],error) &&
      SaveResource(j,operation,base,error))) && SavePendingFields(j,root,desired,error) && RCTwoWaySQL(j,error,"COMMIT");
  if (!ok) RCTwoWaySQL(j,NULL,"ROLLBACK");
  return ok;
}
/* Validate the immutable upload against its receipt before accepting it.
   Aliases commit first, making a crash before/after acceptance replayable
   without allocating a second identity for a native creation. */
static BOOL Complete(RCTwoWayContext *c, ISyncClient *client, NSDictionary *byHref,
                     NSMutableDictionary *aliases, RCError *error)
{
  RCWriteJournal *j=&c->journal;
  sqlite3_stmt *q=NULL; NSMutableArray *pending=[NSMutableArray array]; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT o.id,i.receipt,i.paths,f.fields FROM write_operations o JOIN two_way_intents i "
      "ON i.operation_id=o.id LEFT JOIN two_way_field_scopes f ON f.operation_id=o.id WHERE o.account_id=? AND (o.state='applied' OR "
      "(o.state='acknowledged' AND EXISTS(SELECT 1 FROM two_way_detached d WHERE d.operation_id=o.id))) ORDER BY o.id",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW)
      [pending addObject:[NSArray arrayWithObjects:[NSNumber numberWithLongLong:sqlite3_column_int64(q,0)],
          Unarchive(q,1),Unarchive(q,2),sqlite3_column_type(q,3)==SQLITE_NULL ? (id)[NSNull null] : Unarchive(q,3),nil]];
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read verified writes"); return NO; }
  NSEnumerator *it=[pending objectEnumerator]; NSArray *item;
  while ((item=[it nextObject])) {
    RCWriteOperation o;
    if (!RCWriteJournalGet(j,[[item objectAtIndex:0] longLongValue],&o,error)) return NO;
    NSDictionary *resource=[byHref objectForKey:[NSString stringWithUTF8String:o.href]];
    BOOL acknowledged=!strcmp(o.state,"acknowledged");
    /* A history-filtered creation may return before we have ever learned its
       imported identity. Keep only that alias work pending, not the upload. */
    if (acknowledged && !resource) { RCWriteOperationClear(&o); continue; }
    NSDictionary *receipt=[item objectAtIndex:1], *wantedPaths=[item objectAtIndex:2];
    if (!strcmp(o.kind,"delete")) {
      /* The writer verified 404. Wait for a successful mirror to omit the
         resource, so stale downloaded bytes cannot resurrect it on publication. */
      if (!resource && o.httpStatus==404 && ![LiveReceipt(receipt) count] &&
          ![RCTwoWaySubgraph(RCTwoWayRemap(c->graph,aliases),[receipt allKeys]) count] &&
          RCTwoWaySQL(j,error,"UPDATE write_resolutions SET mirror_committed=1 WHERE successor_id=%lld",o.id) &&
          RCSyncAcceptUpload(client,receipt,NULL,error)) {
        if (!RCWriteJournalAcknowledge(j,o.id,error)) { RCWriteOperationClear(&o); return NO; }
      RCLogger(RCLogInfo, NULL, "Upload", @"Verified server change acknowledged locally (operation=%lld)", o.id);
        NSEnumerator *ids=[receipt keyEnumerator]; NSString *key;
        while ((key=[ids nextObject])) if (!RCTwoWaySQL(j,error,
            "DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q",j->account,[key UTF8String])) {
          RCWriteOperationClear(&o); return NO;
        }
      } else {
        Attention(j,[[receipt allKeys] objectAtIndex:0],"verified-delete-awaits-completion",NULL);
        RCErrorClear(error);
      }
      RCWriteOperationClear(&o); continue;
    }
    NSMutableDictionary *newAliases=[NSMutableDictionary dictionary];
    NSData *verifiedBody=[NSData dataWithBytes:o.resultBody length:o.resultLength];
    NSDictionary *verified=resource;
    BOOL missing=resource==nil;
    if (missing && c->projectVerified) {
      NSString *root=[wantedPaths objectForKey:@"root"] ?: [wantedPaths objectForKey:@"event:"];
      if (root) {
        /* The successful inventory may omit a deleted or out-of-window upload.
           Validate its saved bytes against its original native identities. */
        NSDictionary *detached=[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",
            [NSString stringWithUTF8String:o.resourceKey],@"key",[NSString stringWithUTF8String:o.href],@"href",
            verifiedBody,@"body",LiveReceipt(receipt),@"graph",wantedPaths,@"paths",
            [NSNumber numberWithBool:YES],@"detachedReceipt",nil];
        verified=c->projectVerified(c->context,detached,verifiedBody,error);
      }
    }
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
    if (missing) matched=verified!=nil;
    NSEnumerator *paths=[wantedPaths keyEnumerator]; NSString *path;
    while (matched && (path=[paths nextObject])) {
      NSString *imported=[[verified objectForKey:@"paths"] objectForKey:path];
      if (!imported) matched=NO;
      else [newAliases setObject:[wantedPaths objectForKey:path] forKey:imported];
    }
    if (matched) matched=RCTwoWayGraphsEqual(RCTwoWayRemap([verified objectForKey:@"graph"],newAliases),LiveReceipt(receipt));
    if (!matched) {
      if (acknowledged) { RCWriteOperationClear(&o); continue; }
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
    if (identifier || !RCTwoWaySQL(j,error,"UPDATE write_resolutions SET mirror_committed=1 WHERE successor_id=%lld",o.id) || !RCTwoWaySQL(j,error,missing ?
        "INSERT OR IGNORE INTO two_way_detached VALUES(%lld)" :
        "DELETE FROM two_way_detached WHERE operation_id=%lld",o.id) || !RCTwoWaySQL(j,error,"COMMIT")) {
      RCTwoWaySQL(j,NULL,"ROLLBACK"); RCWriteOperationClear(&o); return NO;
    }
    [aliases addEntriesFromDictionary:newAliases];
    if (acknowledged) { RCWriteOperationClear(&o); continue; }
    NSDictionary *newerTruth=nil;
    NSDictionary *scopes=[item objectAtIndex:3]==[NSNull null] ? nil : [item objectAtIndex:3];
    if (RCSyncAcceptMappedUpload(client,receipt,scopes,&newerTruth,error)) {
      if (!RCWriteJournalAcknowledge(j,o.id,error)) { RCWriteOperationClear(&o); return NO; }
      RCLogger(RCLogInfo, NULL, "Upload", @"Verified server fields completed (operation=%lld)", o.id);
      NSEnumerator *completedIDs=[receipt keyEnumerator]; NSString *completedID;
      while ((completedID=[completedIDs nextObject])) if (!RCTwoWaySQL(j,error,
          "DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason IN ('verified-write-awaits-matching-mirror','verified-write-awaits-local-acceptance')",
          j->account,[completedID UTF8String])) { RCWriteOperationClear(&o); return NO; }
    } else if (!missing && newerTruth && QueueSuccessor(c,&o,verified,newAliases,newerTruth,error)) {
      RCLogger(RCLogInfo, NULL, "Upload", @"Verified server change completed; newer local edit replanned (operation=%lld)", o.id);
      RCErrorClear(error);
    } else {
      RCLogger(RCLogWarning, NULL, "Apply", @"Local acknowledgement pending: %s",error->message);
      Attention(j,[[receipt allKeys] objectAtIndex:0],"verified-write-awaits-local-acceptance",NULL);
      RCErrorClear(error);
    }
    RCWriteOperationClear(&o);
  }
  return YES;
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
    while ((step=sqlite3_step(q))==SQLITE_ROW) [pending addObject:[NSArray arrayWithObjects:
        [NSNumber numberWithLongLong:sqlite3_column_int64(q,0)],Unarchive(q,1),Unarchive(q,2),
        sqlite3_column_type(q,3)==SQLITE_NULL ? (id)[NSNull null] : Unarchive(q,3),nil]];
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read production conflicts"); return NO; }
  NSEnumerator *it=[pending objectEnumerator]; NSArray *item;
  while ((item=[it nextObject])) {
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
      if (anchor) anchor=MapResource(anchor,aliases);
    }
    if (!anchor || !c->projectVerified) goto attention;
    NSMutableDictionary *remote=nil;
    if (o.httpStatus==200 && RCWriteETagIsStrong(o.resultETag)) {
      NSMutableDictionary *importedIDs=[NSMutableDictionary dictionary];
      NSEnumerator *aliasIDs=[aliases keyEnumerator]; NSString *importedID;
      while ((importedID=[aliasIDs nextObject])) [importedIDs setObject:importedID forKey:[aliases objectForKey:importedID]];
      NSDictionary *projected=c->projectVerified(c->context,MapResource(anchor,importedIDs),
          [NSData dataWithBytes:o.resultBody length:o.resultLength],error);
      if (projected) projected=MapResource(projected,aliases);
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
      NSMutableDictionary *desired=deleting ? Deletion(base,truth) :
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
          SaveIntent(j,successor,receipt,[desired objectForKey:@"paths"],[desired objectForKey:@"fieldScopes"],error) &&
          SaveResource(j,successor,base,error) && SavePendingFields(j,root,desired,error) && RCTwoWaySQL(j,error,"COMMIT");
      if (!ok) { RCTwoWaySQL(j,NULL,"ROLLBACK"); RCWriteOperationClear(&o); return NO; }
      RCLogger(RCLogInfo, NULL, "Recovery", @"Conflict decision saved; replacement queued for server verification (operation=%lld, successor=%lld)", o.id, successor);
      RCWriteOperationClear(&o); continue;
    }
attention:
    RCErrorClear(error);
    if (!RCWriteJournalConflictAttention(j,o.id,reason,error)) { RCWriteOperationClear(&o); return NO; }
    RCLogger(RCLogWarning, NULL, "Recovery", @"Conflict needs attention; local edit preserved (operation=%lld, reason=%s)", o.id, reason);
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
    NSMutableDictionary *aliases=Aliases(j,error), *byHref=[NSMutableDictionary dictionary];
    NSEnumerator *it=[c->resources objectEnumerator]; NSDictionary *resource;
    while ((resource=[it nextObject])) [byHref setObject:resource forKey:[resource objectForKey:@"href"]];
    phase="verified-write completion";
    if (!aliases || !Complete(c,client,byHref,aliases,error)) goto done;
    phase="conflict recovery";
    if (!RecoverConflicts(c,client,byHref,aliases,error)) goto done;
    NSMutableDictionary *graph=[NSMutableDictionary dictionaryWithDictionary:RCTwoWayRemap(c->graph,aliases)];
    NSMutableArray *resources=[NSMutableArray array];
    NSMutableSet *known=[NSMutableSet set], *busy=[NSMutableSet set], *excluded=[NSMutableSet set];
    it=[c->resources objectEnumerator];
    while ((resource=[it nextObject])) {
      NSDictionary *r=MapResource(resource,aliases);
      [resources addObject:r]; [known addObject:[r objectForKey:@"root"]];
    }
    /* Find unresolved native intent before publishing any newer remote graph. */
    if (sqlite3_prepare_v2(j->db,"SELECT o.href,i.receipt,r.resource FROM write_operations o JOIN two_way_intents i ON i.operation_id=o.id "
        "LEFT JOIN two_way_resources r ON r.operation_id=o.id "
        "WHERE o.account_id=? AND o.state NOT IN ('acknowledged','cancelled')",-1,&q,NULL)!=SQLITE_OK) goto sqlError;
    sqlite3_bind_int64(q,1,j->account); int step;
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      NSString *href=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
      NSDictionary *receipt=Unarchive(q,1);
      [busy addObjectsFromArray:[receipt allKeys]];
      resource=[byHref objectForKey:href];
      if (resource) [busy addObjectsFromArray:[[MapResource(resource,aliases) objectForKey:@"graph"] allKeys]];
      NSMutableDictionary *pendingGraph=[NSMutableDictionary dictionaryWithDictionary:receipt];
      if (sqlite3_column_type(q,2)!=SQLITE_NULL) {
        NSDictionary *saved=Unarchive(q,2);
        [pendingGraph addEntriesFromDictionary:[saved objectForKey:@"graph"]];
        [busy addObjectsFromArray:[[saved objectForKey:@"graph"] allKeys]];
      }
      if (resource) [pendingGraph addEntriesFromDictionary:[MapResource(resource,aliases) objectForKey:@"graph"]];
      NSEnumerator *pendingRecords=[pendingGraph objectEnumerator]; id pendingRecord;
      while ((pendingRecord=[pendingRecords nextObject])) if ([pendingRecord isKindOfClass:[NSDictionary class]])
        [busy addObjectsFromArray:[pendingRecord objectForKey:@"calendar"] ?: [NSArray array]];
    }
    if (step!=SQLITE_DONE) goto sqlError;
    sqlite3_finalize(q); q=NULL;
    NSDictionary *published=PublishedGraph(j,error);
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
      NSString *imported=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
      [known addObject:[aliases objectForKey:imported] ?: imported];
    }
    if (step!=SQLITE_DONE) goto sqlError;
    sqlite3_finalize(q); q=NULL;
    /* Fast publication leaves unresolved resource snapshots untouched. Keep
       their calendar containers untouched too, including inverse relationships. */
    if ([busy count]) RCLogger(RCLogWarning, NULL, "Apply", @"Preserving %lu unresolved Sync Services records; eligible records can continue", (unsigned long)[busy count]);
    phase="session start";
    session=[ISyncSession beginSessionWithClient:client entityNames:entities
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
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
      [session pushChangesFromRecord:[graph objectForKey:key] withIdentifier:key];
    if ([busy count]) {
      it=[published keyEnumerator];
      while ((key=[it nextObject])) if (![graph objectForKey:key] && ![busy containsObject:key])
        [session deleteRecordWithIdentifier:key];
    }
    phase="local change collection";
    if (![session prepareToPullChangesForEntityNames:pullEntities beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]) {
      RCErrorSet(error,1,"Two-way merge is pending"); goto done;
    }
    NSMutableDictionary *checkpoint=[NSMutableDictionary dictionaryWithDictionary:graph];
    it=[busy objectEnumerator];
    while ((key=[it nextObject])) {
      if ([published objectForKey:key]) [checkpoint setObject:[published objectForKey:key] forKey:key];
      else [checkpoint removeObjectForKey:key];
    }
    if (!SavePublished(j,checkpoint,error)) goto done;
    c->didPublish=YES; c->didPublishAll=[busy count]==0;
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
        if (!owned && !Attention(j,key,"unsupported-detached-parent",error)) goto done;
        continue;
      }
      [resources addObject:[NSDictionary dictionaryWithObject:key forKey:@"root"]];
    }
    phase="local mapping and journaling";
    it=[resources objectEnumerator];
    while ((resource=[it nextObject])) {
      NSString *root=[resource objectForKey:@"root"];
      if ([busy containsObject:root]) continue;
      BOOL creating=![resource objectForKey:@"body"];
      BOOL deleting=![truth objectForKey:root];
      if (deleting && ![localDeletes containsObject:root]) {
        if (!Attention(j,root,"missing-native-delete-receipt",error)) goto done;
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
      NSMutableDictionary *desired=deleting ? Deletion(resource,truth) :
          RCTwoWayEncodeFields(c->encode,c->context,creating ? nil : resource,truth,root,&mappingError);
      if (!desired) {
        RCLogger(RCLogWarning, NULL, "Apply", @"Local edit cannot be uploaded (resource=%@, record=%@, action=%s): %s",
            [resource objectForKey:@"key"] ?: @"new",root,creating ? "create" : deleting ? "delete" : "update",
            mappingError.code ? mappingError.message : deleting ? "Deletion would discard related native records" : "Mapper returned no representable resource");
        if (!Attention(j,root,"unsupported-local-mapping",error)) goto done;
        continue;
      }
      if (!SavePendingFields(j,root,desired,error)) goto done;
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
          !SaveIntent(j,operation,receipt,[desired objectForKey:@"paths"],[desired objectForKey:@"fieldScopes"],error) ||
          !SaveResource(j,operation,creating ? desired : resource,error) ||
          !RCTwoWaySQL(j,error,"DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason<>'unsupported-fields';COMMIT",j->account,[root UTF8String])) goto done;
    }
    /* No refusal and no acceptance before verified remote success. Cancellation
       commits neither pending nor unrelated native changes. */
    [session cancelSyncing]; session=nil;
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
int RCTwoWayRunWrites(RCWriteJournal *j, RCHTTPClient *http, const char *type, RCError *error)
{
  long long operation; int count=0;
  if (!http || !RCTwoWayInitialize(j,error)) return -1;
  while (count<100) {
    if (!RCWriteJournalNext(j,time(NULL),&operation,error)) return -1;
    if (!operation) break;
    /* Only operations with this coordinator's durable native receipts are owned. */
    sqlite3_stmt *q=NULL;
    int step=SQLITE_ERROR;
    if (sqlite3_prepare_v2(j->db,"SELECT 1 FROM two_way_intents i JOIN write_operations o ON o.id=i.operation_id "
        "WHERE o.id=? AND o.account_id=? AND o.kind IN ('create','update','delete')",-1,&q,NULL)==SQLITE_OK) {
      sqlite3_bind_int64(q,1,operation); sqlite3_bind_int64(q,2,j->account); step=sqlite3_step(q);
    }
    sqlite3_finalize(q);
    if (step!=SQLITE_ROW) { RCErrorSet(error,1,"Unowned outgoing operation requires inspection"); return -1; }
    count++;
    if (!RCDAVWriterAttempt(j,operation,http,type,time(NULL),error)) {
      if (error) {
        RCError cause = *error;
        RCErrorSet(error, cause.code, "Attempt failed (operation=%lld): %s", operation, cause.message);
      }
      return -1;
    }
    RCWriteOperation outcome; RCError logError; RCErrorClear(&logError);
    if (RCWriteJournalGet(j,operation,&outcome,&logError)) {
      const char *description = !strcmp(outcome.state,"applied") ?
          "Server change verified; local acknowledgement pending" :
          !strcmp(outcome.state,"conflict") ? "Server version changed; reconciliation pending" :
          "Server outcome uncertain; verification pending";
      RCLogger(!strcmp(outcome.state,"applied") ? RCLogInfo : RCLogWarning, NULL, "Upload",
          @"%s (operation=%lld, action=%s, state=%s, HTTP=%d)", description,
          operation, outcome.kind, outcome.state, outcome.httpStatus);
      RCWriteOperationClear(&outcome);
    } else RCLogger(RCLogWarning, NULL, "Upload", @"Could not read attempt outcome (operation=%lld): %s", operation, logError.message);
  }
  return count;
}
