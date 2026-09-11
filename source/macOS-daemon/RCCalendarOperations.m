#import "RCSyncRecordEquality.h"
#import "RCCalendarOperations.h"
#import "RCTwoWayNative.h"
#include <string.h>

static NSString *String(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }
static BOOL Initialize(RCWriteJournal *j,RCError *error)
{
  return RCTwoWaySQL(j,error,"CREATE TABLE IF NOT EXISTS calendar_actions(account_id INTEGER NOT NULL,native_id TEXT NOT NULL,kind TEXT NOT NULL,source TEXT,target TEXT NOT NULL,etag TEXT,body BLOB,title TEXT,notes TEXT,marker TEXT,state TEXT NOT NULL DEFAULT 'queued',PRIMARY KEY(account_id,native_id));"
      "CREATE TABLE IF NOT EXISTS calendar_native_baseline(account_id INTEGER NOT NULL,native_id TEXT NOT NULL,PRIMARY KEY(account_id,native_id));"
      "CREATE TABLE IF NOT EXISTS calendar_action_accounts(account_id INTEGER PRIMARY KEY);");
}
static NSString *NativeCollectionURL(RCWriteJournal *j,NSString *nativeID)
{
  sqlite3_stmt *q=NULL; NSString *url=nil;
  if(sqlite3_prepare_v2(j->db,"SELECT c.url FROM calendars c LEFT JOIN two_way_aliases a ON a.account_id=c.account_id AND a.imported_id='calendar-'||c.sync_id WHERE c.account_id=? AND c.remote_missing=0 AND (a.native_id=? OR 'calendar-'||c.sync_id=?)",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,[nativeID UTF8String],-1,SQLITE_TRANSIENT); sqlite3_bind_text(q,3,[nativeID UTF8String],-1,SQLITE_TRANSIENT);
    if(sqlite3_step(q)==SQLITE_ROW) url=String((const char *)sqlite3_column_text(q,0));
  }
  sqlite3_finalize(q); return url;
}
BOOL RCCalendarCollectOperations(RCWriteJournal *j,NSDictionary *truth,NSDictionary *graph,NSArray *resources,NSMutableSet *busy,RCError *error)
{
  if(!Initialize(j,error)) return NO;
  sqlite3_stmt *q=NULL; BOOL first=YES;
  if(sqlite3_prepare_v2(j->db,"SELECT 1 FROM calendar_action_accounts WHERE account_id=?",-1,&q,NULL)!=SQLITE_OK) return NO;
  sqlite3_bind_int64(q,1,j->account); first=sqlite3_step(q)==SQLITE_DONE; sqlite3_finalize(q);
  NSMutableSet *baseline=[NSMutableSet set];
  if(sqlite3_prepare_v2(j->db,"SELECT native_id FROM calendar_native_baseline WHERE account_id=?",-1,&q,NULL)!=SQLITE_OK) return NO;
  sqlite3_bind_int64(q,1,j->account); while(sqlite3_step(q)==SQLITE_ROW) [baseline addObject:String((const char *)sqlite3_column_text(q,0))]; sqlite3_finalize(q);
  /* Never migrate unrelated calendars that existed before this feature was
     enabled. Only newly created writable local calendars enter this account. */
  NSEnumerator *it=[truth keyEnumerator]; NSString *identifier;
  while((identifier=[it nextObject])) {
    NSDictionary *record=[truth objectForKey:identifier];
    if(![[record objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Calendar"] || [graph objectForKey:identifier]) continue;
    if(first) {
      if(!RCTwoWaySQL(j,error,"INSERT OR IGNORE INTO calendar_native_baseline VALUES(%lld,%Q)",j->account,[identifier UTF8String])) return NO;
      continue;
    }
    if([baseline containsObject:identifier] || !RCNativeEmptyValue([record objectForKey:@"url"]) || [[record objectForKey:@"read only"] boolValue] || NativeCollectionURL(j,identifier)) continue;
    NSMutableSet *homes=[NSMutableSet set];
    if(sqlite3_prepare_v2(j->db,"SELECT url FROM calendars WHERE account_id=? AND remote_missing=0",-1,&q,NULL)!=SQLITE_OK) return NO;
    sqlite3_bind_int64(q,1,j->account);
    while(sqlite3_step(q)==SQLITE_ROW) {
      NSString *url=String((const char *)sqlite3_column_text(q,0));
      if([url hasSuffix:@"/"]) url=[url substringToIndex:[url length]-1];
      NSRange slash=[url rangeOfString:@"/" options:NSBackwardsSearch]; if(slash.location!=NSNotFound) [homes addObject:[url substringToIndex:slash.location+1]];
    }
    sqlite3_finalize(q);
    if([homes count]!=1) continue;
    NSString *marker=RCTwoWayNewIdentifier(), *target=[NSString stringWithFormat:@"%@%@/",[homes anyObject],marker];
    if(!RCTwoWaySQL(j,error,"INSERT OR IGNORE INTO calendar_actions(account_id,native_id,kind,target,title,notes,marker) VALUES(%lld,%Q,'create',%Q,%Q,%Q,%Q)",j->account,[identifier UTF8String],[target UTF8String],[[record objectForKey:@"title"] UTF8String] ?: "Calendar",[[record objectForKey:@"notes"] UTF8String],[marker UTF8String])) return NO;
  }
  if(first && !RCTwoWaySQL(j,error,"INSERT INTO calendar_action_accounts VALUES(%lld)",j->account)) return NO;
  /* A rejected MOVE made no remote change. Reverting or choosing a different
     calendar is an explicit new local decision, so retire that conflict. An
     uncertain operation is never cancelled this way. */
  if(sqlite3_prepare_v2(j->db,"SELECT native_id,target FROM calendar_actions WHERE account_id=? AND kind='move' AND state='conflict'",-1,&q,NULL)!=SQLITE_OK) return NO;
  sqlite3_bind_int64(q,1,j->account); NSMutableArray *cancelled=[NSMutableArray array];
  while(sqlite3_step(q)==SQLITE_ROW) {
    NSString *native=String((const char *)sqlite3_column_text(q,0)), *target=String((const char *)sqlite3_column_text(q,1));
    NSArray *to=[[truth objectForKey:native] objectForKey:@"calendar"];
    NSString *collection=[to count]==1 ? NativeCollectionURL(j,[to objectAtIndex:0]) : nil;
    if(collection && ![target hasPrefix:collection]) [cancelled addObject:native];
  }
  sqlite3_finalize(q);
  it=[cancelled objectEnumerator];
  while((identifier=[it nextObject])) {
    if(!RCTwoWaySQL(j,error,"DELETE FROM calendar_actions WHERE account_id=%lld AND native_id=%Q AND state='conflict';DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason='calendar-move-conflict'",j->account,[identifier UTF8String],j->account,[identifier UTF8String])) return NO;
    [busy removeObject:identifier];
  }
  it=[resources objectEnumerator]; NSDictionary *resource;
  while((resource=[it nextObject])) {
    NSString *root=[resource objectForKey:@"root"]; NSDictionary *old=[[resource objectForKey:@"graph"] objectForKey:root], *record=[truth objectForKey:root];
    if(!old || !record || [busy containsObject:root]) continue;
    NSArray *from=[old objectForKey:@"calendar"], *to=[record objectForKey:@"calendar"];
    if([to count]!=1 || [from isEqual:to]) continue;
    NSString *collection=NativeCollectionURL(j,[to objectAtIndex:0]);
    if(!collection || !RCWriteETagIsStrong([[resource objectForKey:@"etag"] UTF8String])) continue;
    NSURL *source=[NSURL URLWithString:[resource objectForKey:@"href"]], *destination=[NSURL URLWithString:collection];
    if(![[source host] isEqual:[destination host]]) continue;
    NSString *sourceURL=[source absoluteString]; NSRange slash=[sourceURL rangeOfString:@"/" options:NSBackwardsSearch];
    if(slash.location==NSNotFound) continue;
    NSString *target=[NSString stringWithFormat:@"%@%@%@",collection,[collection hasSuffix:@"/"] ? @"" : @"/",[sourceURL substringFromIndex:slash.location+1]];
    NSData *body=[resource objectForKey:@"body"];
    if(sqlite3_prepare_v2(j->db,"INSERT OR IGNORE INTO calendar_actions(account_id,native_id,kind,source,target,etag,body) VALUES(?,?,'move',?,?,?,?)",-1,&q,NULL)!=SQLITE_OK) return NO;
    sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT); sqlite3_bind_text(q,3,[[resource objectForKey:@"href"] UTF8String],-1,SQLITE_TRANSIENT);
    sqlite3_bind_text(q,4,[target UTF8String],-1,SQLITE_TRANSIENT); sqlite3_bind_text(q,5,[[resource objectForKey:@"etag"] UTF8String],-1,SQLITE_TRANSIENT); sqlite3_bind_blob(q,6,[body bytes],[body length],SQLITE_TRANSIENT);
    BOOL ok=sqlite3_step(q)==SQLITE_DONE; sqlite3_finalize(q); if(!ok) return NO;
    [busy addObject:root];
  }
  return YES;
}
BOOL RCCalendarProtectOperations(RCWriteJournal *j,NSArray *resources,NSDictionary *graph,NSMutableSet *busy,RCError *error)
{
  if(!Initialize(j,error)) return NO;
  sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(j->db,"SELECT native_id,source,target FROM calendar_actions WHERE account_id=? AND state<>'done'",-1,&q,NULL)!=SQLITE_OK) return NO;
  sqlite3_bind_int64(q,1,j->account); int step;
  while((step=sqlite3_step(q))==SQLITE_ROW) {
    NSString *native=String((const char *)sqlite3_column_text(q,0)), *source=String((const char *)sqlite3_column_text(q,1)), *target=String((const char *)sqlite3_column_text(q,2));
    [busy addObject:native]; NSEnumerator *it=[resources objectEnumerator]; NSDictionary *r;
    while((r=[it nextObject])) if([[r objectForKey:@"href"] isEqual:source]) {
      [busy addObjectsFromArray:[[r objectForKey:@"graph"] allKeys]];
      [busy addObjectsFromArray:[[[r objectForKey:@"graph"] objectForKey:[r objectForKey:@"root"]] objectForKey:@"calendar"] ?: [NSArray array]];
    }
    it=[graph keyEnumerator]; NSString *identifier;
    while((identifier=[it nextObject])) if([[[graph objectForKey:identifier] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Calendar"]) {
      NSString *collection=NativeCollectionURL(j,identifier); if(collection && [target hasPrefix:collection]) [busy addObject:identifier];
    }
  }
  sqlite3_finalize(q); return step==SQLITE_DONE;
}
static NSString *EscapeXML(NSString *text)
{
  NSMutableString *s=[NSMutableString stringWithString:text ?: @""];
  [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0,[s length])]; return s;
}
static BOOL Get(RCHTTPClient *http,NSString *url,RCHTTPResponse *response,RCError *error)
{
  return RCHTTPClientRequest(http,"GET",[url UTF8String],NULL,NULL,NULL,0,response,error) && response->effectiveURL && [String(response->effectiveURL) isEqual:url];
}
static NSXMLNode *XMLChild(NSXMLNode *node,NSString *name,NSString *uri)
{
  NSEnumerator *it=[[node children] objectEnumerator]; NSXMLNode *child;
  while((child=[it nextObject])) if([[child localName] isEqual:name] && [[child URI] isEqual:uri]) return child;
  return nil;
}
static BOOL Created(RCHTTPClient *http,NSString *url,NSString *marker,RCError *error)
{
  const char *query="<d:propfind xmlns:d='DAV:' xmlns:r='urn:retrocloudsync'><d:prop><d:resourcetype/><r:creation-id/></d:prop></d:propfind>";
  RCHTTPResponse response; RCHTTPResponseInit(&response);
  BOOL ok=RCHTTPClientRequest(http,"PROPFIND",[url UTF8String],"0","application/xml",query,strlen(query),&response,error);
  if(!ok || response.statusCode!=207 || !response.effectiveURL || ![String(response.effectiveURL) isEqual:url]) { RCHTTPResponseClear(&response); return NO; }
  NSXMLDocument *doc=[[[NSXMLDocument alloc] initWithData:[NSData dataWithBytes:response.body length:response.bodyLength] options:0 error:NULL] autorelease];
  BOOL calendar=NO,owned=NO;
  NSEnumerator *responses=[[[doc rootElement] children] objectEnumerator]; NSXMLNode *entry;
  while((entry=[responses nextObject])) {
    if(![[entry localName] isEqual:@"response"] || ![[entry URI] isEqual:@"DAV:"]) continue;
    NSString *href=[XMLChild(entry,@"href",@"DAV:") stringValue];
    if(!href || ![[[NSURL URLWithString:href relativeToURL:[NSURL URLWithString:url]] absoluteString] isEqual:url]) continue;
    NSEnumerator *stats=[[entry children] objectEnumerator]; NSXMLNode *stat;
    while((stat=[stats nextObject])) {
      if(![[stat localName] isEqual:@"propstat"] || ![[stat URI] isEqual:@"DAV:"]) continue;
      NSString *status=[XMLChild(stat,@"status",@"DAV:") stringValue];
      if(!status || [status rangeOfString:@" 200 "].location==NSNotFound) continue;
      NSXMLNode *prop=XMLChild(stat,@"prop",@"DAV:");
      if(XMLChild(XMLChild(prop,@"resourcetype",@"DAV:"),@"calendar",@"urn:ietf:params:xml:ns:caldav")) calendar=YES;
      if([[XMLChild(prop,@"creation-id",@"urn:retrocloudsync") stringValue] isEqual:marker]) owned=YES;
    }
  }
  if(!calendar || !owned) RCErrorSet(error,1,"Calendar verification lacks resource type or ownership marker");
  RCHTTPResponseClear(&response); return calendar && owned;
}
BOOL RCCalendarRunOperations(RCWriteJournal *j,RCHTTPClient *http,RCError *error)
{
  if(!Initialize(j,error) || !sqlite3_get_autocommit(j->db)) return NO;
  sqlite3_stmt *q=NULL; NSMutableArray *actions=[NSMutableArray array];
  if(sqlite3_prepare_v2(j->db,"SELECT native_id,kind,source,target,etag,body,title,marker,notes FROM calendar_actions WHERE account_id=? AND state='queued'",-1,&q,NULL)!=SQLITE_OK) return NO;
  sqlite3_bind_int64(q,1,j->account);
  while(sqlite3_step(q)==SQLITE_ROW) {
    NSMutableDictionary *a=[NSMutableDictionary dictionary]; NSString *keys[]={@"native",@"kind",@"source",@"target",@"etag",@"body",@"title",@"marker",@"notes"}; int k;
    for(k=0;k<9;k++) if(sqlite3_column_type(q,k)!=SQLITE_NULL) [a setObject:k==5 ? (id)[NSData dataWithBytes:sqlite3_column_blob(q,k) length:sqlite3_column_bytes(q,k)] : String((const char *)sqlite3_column_text(q,k)) forKey:keys[k]];
    [actions addObject:a];
  }
  sqlite3_finalize(q); NSEnumerator *it=[actions objectEnumerator]; NSDictionary *a; BOOL all=YES;
  while((a=[it nextObject])) {
    if (RCCheckCancellation(error)) return NO;
    NSString *target=[a objectForKey:@"target"], *native=[a objectForKey:@"native"];
    BOOL done=NO,conflict=NO; RCHTTPResponse response; RCHTTPResponseInit(&response);
    if([[a objectForKey:@"kind"] isEqual:@"create"]) {
      NSString *marker=[a objectForKey:@"marker"];
      done=Created(http,target,marker,error);
      if(!done) {
        NSString *xml=[NSString stringWithFormat:@"<c:mkcalendar xmlns:c='urn:ietf:params:xml:ns:caldav' xmlns:d='DAV:' xmlns:r='urn:retrocloudsync'><d:set><d:prop><d:displayname>%@</d:displayname><c:calendar-description>%@</c:calendar-description><r:creation-id>%@</r:creation-id></d:prop></d:set></c:mkcalendar>",EscapeXML([a objectForKey:@"title"]),EscapeXML([a objectForKey:@"notes"]),marker];
        NSData *body=[xml dataUsingEncoding:NSUTF8StringEncoding];
        RCHTTPClientConditionalRequest(http,"MKCALENDAR",[target UTF8String],"application/xml",[body bytes],[body length],NULL,1,&response,error);
        done=Created(http,target,marker,error);
      }
      if(done) {
        NSString *syncID=marker;
        done=RCTwoWaySQL(j,error,"BEGIN IMMEDIATE;INSERT OR IGNORE INTO calendars(account_id,url,sync_id,display_name,description) VALUES(%lld,%Q,%Q,%Q,%Q);INSERT OR REPLACE INTO two_way_aliases SELECT %lld,'calendar-'||sync_id,%Q FROM calendars WHERE account_id=%lld AND url=%Q;UPDATE calendar_actions SET state='done' WHERE account_id=%lld AND native_id=%Q;COMMIT",j->account,[target UTF8String],[syncID UTF8String],[[a objectForKey:@"title"] UTF8String],[[a objectForKey:@"notes"] UTF8String],j->account,[native UTF8String],j->account,[target UTF8String],j->account,[native UTF8String]);
      }
    } else {
      NSString *source=[a objectForKey:@"source"]; NSData *body=[a objectForKey:@"body"];
      RCHTTPResponse before; RCHTTPResponseInit(&before);
      BOOL read=Get(http,source,&before,error) && Get(http,target,&response,error);
      if(read && before.statusCode==200 && response.statusCode==404) {
        if(![String(before.etag) isEqual:[a objectForKey:@"etag"]] || before.bodyLength!=[body length] || memcmp(before.body,[body bytes],[body length])) conflict=YES;
        else {
          RCHTTPClientMove(http,[source UTF8String],[target UTF8String],[[a objectForKey:@"etag"] UTF8String],&response,error);
          read=Get(http,source,&before,error) && Get(http,target,&response,error);
        }
      }
      if(read && before.statusCode==404 && response.statusCode==200 && RCWriteETagIsStrong(response.etag) && response.bodyLength==[body length] && !memcmp(response.body,[body bytes],[body length])) {
        NSRange slash=[target rangeOfString:@"/" options:NSBackwardsSearch];
        NSString *collection=[[target substringToIndex:slash.location+1] copy];
        done=RCTwoWaySQL(j,error,"BEGIN IMMEDIATE;UPDATE calendar_resources SET href=%Q,calendar_id=(SELECT id FROM calendars WHERE account_id=%lld AND url=%Q),etag=%Q,export_etag=%Q WHERE href=%Q AND calendar_id IN(SELECT id FROM calendars WHERE account_id=%lld)",[target UTF8String],j->account,[collection UTF8String],response.etag,response.etag,[source UTF8String],j->account);
        if(done && sqlite3_changes(j->db)==1)
          done=RCTwoWaySQL(j,error,"DELETE FROM calendar_actions WHERE account_id=%lld AND native_id=%Q;COMMIT",j->account,[native UTF8String]);
        else { done=NO; RCTwoWaySQL(j,NULL,"ROLLBACK"); RCErrorSet(error,1,"Moved calendar resource requires mirror recovery"); }
        [collection release];
      } else if(read && response.statusCode==200 && before.statusCode==200) conflict=YES;
      RCHTTPResponseClear(&before);
    }
    RCHTTPResponseClear(&response);
    if(!sqlite3_get_autocommit(j->db)) RCTwoWaySQL(j,NULL,"ROLLBACK");
    if(conflict) RCTwoWaySQL(j,error,"UPDATE calendar_actions SET state='conflict' WHERE account_id=%lld AND native_id=%Q;INSERT OR REPLACE INTO two_way_attention VALUES(%lld,%Q,'calendar-move-conflict')",j->account,[native UTF8String],j->account,[native UTF8String]);
    if(!done) all=NO;
  }
  if(!all && (!error || !error->code)) RCErrorSet(error,1,"Calendar creation or move awaits server verification");
  if(all) RCErrorClear(error);
  return all;
}
