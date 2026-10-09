#import "RCAutorelease.h"
#import "RCLogger.h"
#import "RCTwoWaySync.h"
#import "RCTwoWayInternal.h"
#import "RCSyncRecordEquality.h"
#import "RCSyncFieldScope.h"
#include "RCDAVWriter.h"
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
    NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
    @try {
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
    } @catch(id exception) {
      RCDrainPoolPreservingException(&resourcePool,exception); @throw;
    } @finally { [resourcePool release]; }
  }
  return result;
}
id RCTwoWayUnarchive(sqlite3_stmt *q, int col)
{
  return [NSKeyedUnarchiver unarchiveObjectWithData:
      [NSData dataWithBytes:sqlite3_column_blob(q,col) length:sqlite3_column_bytes(q,col)]];
}
BOOL RCTwoWaySaveIntent(RCWriteJournal *j, long long operation, NSDictionary *receipt,
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
BOOL RCTwoWaySaveResource(RCWriteJournal *j, long long operation, NSDictionary *resource, RCError *error)
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
NSMutableDictionary *RCTwoWayDeletion(NSDictionary *resource, NSDictionary *truth)
{
  /* A recurrence exception or orphaned child is not a whole-resource delete. */
  NSEnumerator *it=[[resource objectForKey:@"graph"] keyEnumerator]; NSString *key;
  while ((key=[it nextObject])) if ([truth objectForKey:key]) return nil;
  NSMutableDictionary *desired=[NSMutableDictionary dictionaryWithDictionary:resource];
  [desired removeObjectForKey:@"body"];
  [desired setObject:[NSDictionary dictionary] forKey:@"graph"];
  return desired;
}
NSDictionary *RCTwoWayPublishedGraph(RCWriteJournal *j, RCError *error)
{
  sqlite3_stmt *q=NULL; NSDictionary *graph=nil;
  if (sqlite3_prepare_v2(j->db,"SELECT graph FROM two_way_publications WHERE account_id=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); int step=sqlite3_step(q);
    if (step==SQLITE_ROW) graph=RCTwoWayUnarchive(q,0);
    else if (step==SQLITE_DONE) graph=[NSDictionary dictionary];
  }
  sqlite3_finalize(q);
  if (!graph) RCErrorSet(error,1,"Could not read two-way publication checkpoint");
  return graph;
}
BOOL RCTwoWaySavePublished(RCWriteJournal *j, NSDictionary *graph, RCError *error)
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
NSMutableDictionary *RCTwoWayAliases(RCWriteJournal *j, RCError *error)
{
  NSMutableDictionary *result=[NSMutableDictionary dictionary];
  sqlite3_stmt *q=NULL; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT imported_id,native_id FROM two_way_aliases WHERE account_id=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        [result setObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,1)]
            forKey:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)]];
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read native identities"); return nil; }
  return result;
}
NSDictionary *RCTwoWayApplyAliases(RCWriteJournal *j, NSDictionary *graph, RCError *error)
{
  if (!RCTwoWayInitialize(j,error)) return nil;
  NSDictionary *aliases=RCTwoWayAliases(j,error);
  return aliases ? RCTwoWayRemap(graph,aliases) : nil;
}
NSDictionary *RCTwoWayMapResource(NSDictionary *resource, NSDictionary *aliases)
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
BOOL RCTwoWayAttention(RCWriteJournal *j, NSString *root, const char *reason, RCError *error)
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
BOOL RCTwoWaySavePendingFields(RCWriteJournal *j, NSString *root, NSDictionary *desired, RCError *error)
{
  NSMutableDictionary *fields=[NSMutableDictionary dictionaryWithDictionary:[desired objectForKey:@"pendingFields"] ?: [NSDictionary dictionary]];
  sqlite3_stmt *q=NULL; NSDictionary *previous=nil; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT fields FROM two_way_pending_fields WHERE account_id=? AND root_id=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
    step=sqlite3_step(q); if (step==SQLITE_ROW) previous=RCTwoWayUnarchive(q,0);
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
  NSDictionary *base=RCTwoWayMapResource(verified,aliases);
  NSString *root=[base objectForKey:@"root"];
  BOOL deleting=![truth objectForKey:root];
  NSMutableDictionary *desired=deleting ? RCTwoWayDeletion(base,truth) : RCTwoWayEncodeFields(c->encode,c->context,base,truth,root,error);
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
      RCTwoWaySaveIntent(j,operation,receipt,[desired objectForKey:@"paths"],[desired objectForKey:@"fieldScopes"],error) &&
      RCTwoWaySaveResource(j,operation,base,error))) && RCTwoWaySavePendingFields(j,root,desired,error) && RCTwoWaySQL(j,error,"COMMIT");
  if (!ok) RCTwoWaySQL(j,NULL,"ROLLBACK");
  return ok;
}
/* Validate the immutable upload against its receipt before accepting it.
   RCTwoWayAliases commit first, making a crash before/after acceptance replayable
   without allocating a second identity for a native creation. */
BOOL RCTwoWayComplete(RCTwoWayContext *c, NSDictionary *byHref,
    NSMutableDictionary *aliases, RCSyncAcceptReceipt accept, void *receiver, RCError *error)
{
  RCWriteJournal *j=&c->journal;
  sqlite3_stmt *q=NULL; NSMutableArray *pending=[NSMutableArray array]; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j->db,"SELECT o.id,i.receipt,i.paths,f.fields FROM write_operations o JOIN two_way_intents i "
      "ON i.operation_id=o.id LEFT JOIN two_way_field_scopes f ON f.operation_id=o.id WHERE o.account_id=? AND (o.state='applied' OR "
      "(o.state='acknowledged' AND EXISTS(SELECT 1 FROM two_way_detached d WHERE d.operation_id=o.id))) ORDER BY o.id",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) {
      NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
      @try {
        [pending addObject:[NSArray arrayWithObjects:[NSNumber numberWithLongLong:sqlite3_column_int64(q,0)],
            RCTwoWayUnarchive(q,1),RCTwoWayUnarchive(q,2),sqlite3_column_type(q,3)==SQLITE_NULL ? (id)[NSNull null] : RCTwoWayUnarchive(q,3),nil]];
      } @catch(id exception) {
        RCDrainPoolPreservingException(&resourcePool,exception); @throw;
      } @finally { [resourcePool release]; }
    }
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not read verified writes"); return NO; }
  NSEnumerator *it=[pending objectEnumerator]; NSArray *item;
  while ((item=[it nextObject])) {
    NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
    @try {
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
            accept(receiver,receipt,nil,YES,NULL,error)) {
          if (!RCWriteJournalAcknowledge(j,o.id,error)) { RCWriteOperationClear(&o); return NO; }
        RCLogger(RCLogInfo, NULL, "Upload", @"Verified server change acknowledged locally (operation=%lld)", o.id);
          NSEnumerator *ids=[receipt keyEnumerator]; NSString *key;
          while ((key=[ids nextObject])) if (!RCTwoWaySQL(j,error,
              "DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q",j->account,[key UTF8String])) {
            RCWriteOperationClear(&o); return NO;
          }
        } else {
          RCTwoWayAttention(j,[[receipt allKeys] objectAtIndex:0],"verified-delete-awaits-completion",NULL);
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
              [NSString stringWithUTF8String:o.resultETag ?: ""],@"verifiedETag",
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
        NSMutableDictionary *projection=[NSMutableDictionary dictionaryWithDictionary:resource];
        [projection setObject:[NSString stringWithUTF8String:o.resultETag] forKey:@"verifiedETag"];
        verified=c->projectVerified(c->context,projection,verifiedBody,&projectionError);
        matched=verified!=nil;
      }
      if (missing) matched=verified!=nil;
      NSEnumerator *paths=[wantedPaths keyEnumerator]; NSString *path;
      while (matched && (path=[paths nextObject])) {
        NSString *imported=[[verified objectForKey:@"paths"] objectForKey:path];
        if (!imported) matched=NO;
        else [newAliases setObject:[wantedPaths objectForKey:path] forKey:imported];
      }
      NSDictionary *scopes=[item objectAtIndex:3]==[NSNull null] ? nil : [item objectAtIndex:3];
      if (matched) matched=RCNativeUploadedGraphMatches(RCTwoWayRemap([verified objectForKey:@"graph"],newAliases),LiveReceipt(receipt),scopes);
      if (!matched) {
        if (acknowledged) { RCWriteOperationClear(&o); continue; }
        RCTwoWayAttention(j,[[receipt allKeys] count] ? [[receipt allKeys] objectAtIndex:0] : @"unknown",
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
      if (accept(receiver,receipt,scopes,NO,&newerTruth,error)) {
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
        RCTwoWayAttention(j,[[receipt allKeys] objectAtIndex:0],"verified-write-awaits-local-acceptance",NULL);
        RCErrorClear(error);
      }
      RCWriteOperationClear(&o);
    } @catch(id exception) {
      RCDrainPoolPreservingException(&resourcePool,exception); @throw;
    } @finally { [resourcePool release]; }
  }
  return YES;
}
int RCTwoWayRunWrites(RCWriteJournal *j, RCHTTPClient *http, const char *type, RCError *error)
{
  long long operation; int count=0;
  if (!http || !RCTwoWayInitialize(j,error)) return -1;
  while (count<100) {
    if (RCCheckCancellation(error)) return -1;
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
