#import "../../../macOS-daemon/RCCalendarOperations.h"
#import "../../../macOS-daemon/RCContactPhoto.h"
#import "../../../macOS-daemon/RCSyncFieldScope.h"
#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#import "../../../macOS-daemon/RCTwoWayNative.h"
#import "../../../macOS-daemon/RCSyncConflictSession.h"
#include "../../../shared/RCResourcePatch.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#import "../../../macOS-daemon/RCContactIM.h"
#import "../../../macOS-daemon/RCCalendarRecurrence.h"

static RCError error;
static NSMutableDictionary *remoteBodies, *remoteETags;
static NSMutableDictionary *remotePhotos;
static RCContactStore *photoStore=NULL;
static BOOL normalizePhotos=NO;
static int photoGETs=0;
static const char *photoResponseType="image/jpeg";
static int mutations=0;
static BOOL loseResponse=NO;
static NSMutableDictionary *remoteCollections;
static NSString *marker;
#define CHECK(x) do { RCErrorClear(&error); if (!(x)) [NSException raise:@"TestFailure" format:@"line %d: %s: %s",__LINE__,#x,error.message]; } while(0)

/* Deliberately replaces the HTTP transport at link time. This executable has
   no live server path and never obtains credentials. */
void RCHTTPResponseInit(RCHTTPResponse *r) { memset(r,0,sizeof(*r)); }
void RCHTTPResponseClear(RCHTTPResponse *r)
{
  free(r->effectiveURL); free(r->location); free(r->etag); free(r->contentType); free(r->body); memset(r,0,sizeof(*r));
}
static int Response(const char *url,RCHTTPResponse *r)
{
  if (strncmp(url,"https://fixture.invalid/",24)) return 0;
  RCHTTPResponseClear(r); r->effectiveURL=strdup(url);
  NSString *href=[NSString stringWithUTF8String:url]; NSData *body=[remoteBodies objectForKey:href];
  if (!body && [remotePhotos objectForKey:href]) { body=[remotePhotos objectForKey:href]; r->contentType=strdup(photoResponseType); photoGETs++; }
  r->statusCode=body ? 200 : 404;
  if (body) {
    r->etag=strdup([[remoteETags objectForKey:href] UTF8String] ?: "\"photo\""); r->bodyLength=[body length];
    r->body=malloc(r->bodyLength+1); memcpy(r->body,[body bytes],r->bodyLength); r->body[r->bodyLength]=0;
  }
  return 1;
}
int RCHTTPClientMove(RCHTTPClient *c,const char *source,const char *target,const char *etag,RCHTTPResponse *r,RCError *e)
{
  (void)c;
  if(strncmp(target,"https://fixture.invalid/",24) || !Response(source,r)) { RCErrorSet(e,1,"Non-fixture MOVE rejected"); return 0; }
  NSString *from=[NSString stringWithUTF8String:source], *to=[NSString stringWithUTF8String:target];
  if([remoteBodies objectForKey:to] || ![[remoteETags objectForKey:from] isEqual:[NSString stringWithUTF8String:etag]]) { r->statusCode=412; return 1; }
  [remoteBodies setObject:[remoteBodies objectForKey:from] forKey:to]; [remoteBodies removeObjectForKey:from];
  [remoteETags setObject:@"\"moved\"" forKey:to]; [remoteETags removeObjectForKey:from]; mutations++;
  if(loseResponse) { loseResponse=NO; RCErrorSet(e,1,"Lost MOVE response"); return 0; }
  r->statusCode=201; return 1;
}
int RCHTTPClientRequest(RCHTTPClient *c,const char *method,const char *url,const char *depth,
    const char *type,const void *body,size_t length,RCHTTPResponse *r,RCError *e)
{
  (void)c;(void)depth;(void)type;(void)body;(void)length;
  if(!strcmp(method,"PROPFIND")) {
    if(strncmp(url,"https://fixture.invalid/",24)) return 0;
    RCHTTPResponseClear(r); r->effectiveURL=strdup(url);
    NSString *marker=[remoteCollections objectForKey:[NSString stringWithUTF8String:url]];
    r->statusCode=marker ? 207 : 404;
    if(marker) {
      NSData *xml=[[NSString stringWithFormat:@"<d:multistatus xmlns:d='DAV:' xmlns:c='urn:ietf:params:xml:ns:caldav' xmlns:r='urn:retrocloudsync'><d:response><d:href>%s</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><r:creation-id>%@</r:creation-id></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>",url,marker] dataUsingEncoding:NSUTF8StringEncoding];
      r->bodyLength=[xml length];r->body=malloc(r->bodyLength);memcpy(r->body,[xml bytes],r->bodyLength);
    }
    return 1;
  }
  if (strcmp(method,"GET") || !Response(url,r)) { RCErrorSet(e,1,"Non-fixture request rejected"); return 0; }
  return 1;
}
int RCHTTPClientConditionalRequest(RCHTTPClient *c,const char *method,const char *url,const char *type,
    const void *body,size_t length,const char *etag,int create,RCHTTPResponse *r,RCError *e)
{
  (void)c;(void)type;
  if(!strcmp(method,"MKCALENDAR")) {
    if(strncmp(url,"https://fixture.invalid/",24)) return 0;
    NSString *href=[NSString stringWithUTF8String:url];
    if(!remoteCollections) remoteCollections=[[NSMutableDictionary alloc] init];
    if([remoteCollections objectForKey:href]) { r->statusCode=412; return 1; }
    NSXMLDocument *doc=[[[NSXMLDocument alloc] initWithData:[NSData dataWithBytes:body length:length] options:0 error:NULL] autorelease];
    NSArray *nodes=[doc nodesForXPath:@"//*[local-name()='creation-id']" error:NULL];
    if([nodes count]!=1) return 0;
    [remoteCollections setObject:[[nodes objectAtIndex:0] stringValue] forKey:href]; mutations++;
    if(loseResponse) { loseResponse=NO; RCErrorSet(e,1,"Lost MKCALENDAR response"); return 0; }
    r->statusCode=201; return 1;
  }
  if ((strcmp(method,"PUT") && strcmp(method,"DELETE")) || !Response(url,r)) { RCErrorSet(e,1,"Non-fixture mutation rejected"); return 0; }
  NSString *href=[NSString stringWithUTF8String:url];
  BOOL exists=[remoteBodies objectForKey:href]!=nil;
  if ((create && exists) || (!create && (!etag || !exists || ![[remoteETags objectForKey:href] isEqual:[NSString stringWithUTF8String:etag]]))) {
    r->statusCode=412; return 1;
  }
  mutations++;
  if (!strcmp(method,"DELETE")) {
    [remoteBodies removeObjectForKey:href]; [remoteETags removeObjectForKey:href];
  } else {
    NSData *canonical=[NSData dataWithBytes:body length:length];
    if (normalizePhotos && strstr(type,"text/vcard")) {
      RCVCardDocument doc; CHECK(RCVCardParse(body,length,&doc,&error));
      NSData *image=RCContactPhoto(&doc);
      if (image) {
        NSString *uri=[href stringByAppendingString:@"/photo"];
        [remotePhotos setObject:image forKey:uri];
        const char *group=NULL; size_t i;
        for(i=0;i<doc.propertyCount;i++) if (!strcasecmp(doc.properties[i].name,"PHOTO")) group=doc.properties[i].group;
        RCResourceEdit edits[2]={{0,"PHOTO",group,0,NULL,NULL,NULL,NULL},{0,"PHOTO",group,-1,[uri UTF8String],"TYPE=JPEG;VALUE=uri",NULL,NULL}};
        unsigned char *bytes=NULL; size_t count=0;
        CHECK(RCResourcePatch(RCResourceVCard,body,length,edits,2,&bytes,&count,&error));
        canonical=[NSData dataWithBytes:bytes length:count]; free(bytes);
      }
      RCVCardDocumentClear(&doc);
    }
    [remoteBodies setObject:canonical forKey:href];
    [remoteETags setObject:[NSString stringWithFormat:@"\"write-%d\"",mutations] forKey:href];
  }
  Response(url,r); r->statusCode=create ? 201 : 204;
  if (loseResponse) { loseResponse=NO; RCErrorSet(e,1,"Synthetic response lost after PUT"); return 0; }
  return 1;
}
static NSString *Replace(NSString *text, NSString *old, NSString *replacement)
{
  NSMutableString *result=[NSMutableString stringWithString:text];
  [result replaceOccurrencesOfString:old withString:replacement options:0 range:NSMakeRange(0,[result length])];
  return result;
}
static NSDictionary *ContactPaths(NSData *body,NSString *root)
{
  RCVCardDocument doc; CHECK(RCVCardParse([body bytes],[body length],&doc,&error));
  NSMutableDictionary *paths=[NSMutableDictionary dictionaryWithObject:root forKey:@"root"], *counts=[NSMutableDictionary dictionary];
  size_t p;
  for(p=0;p<doc.propertyCount;p++) {
    NSString *name=RCContactPathName(doc.properties[p].name);
    if ([name isEqual:@"TEL"] || [name isEqual:@"EMAIL"] || [name isEqual:@"ADR"] || [name isEqual:@"URL"] || [name isEqual:@"X-ABDATE"] || [name isEqual:@"X-ABRELATEDNAMES"] || [name isEqual:@"IMPP"]) {
      int n=[[counts objectForKey:name] intValue]; [counts setObject:[NSNumber numberWithInt:n+1] forKey:name];
      if(!RCContactPropertyVisible(&doc.properties[p])) continue;
      [paths setObject:[NSString stringWithFormat:@"%@-%@-%d",root,name,n] forKey:[NSString stringWithFormat:@"%@:%d",name,n]];
    }
  }
  RCVCardDocumentClear(&doc); return paths;
}
static NSDictionary *ContactGraph(NSData *body,NSString *root)
{
  NSDictionary *mapped=RCContactNativeGraphForPaths(body,ContactPaths(body,root),&error); CHECK(mapped);
  return RCTwoWayRemap(mapped,[NSDictionary dictionaryWithObject:root forKey:@"contact-validation"]);
}
static NSDictionary *ContactResource(NSData *body,NSString *root,NSString *href,NSString *etag)
{
  NSDictionary *graph=ContactGraph(body,root);
  if (photoStore) {
    CHECK(RCContactPhotoFetch(photoStore,(RCHTTPClient *)1,href,etag,body,&error));
    NSDictionary *mapped=RCContactNativeGraphWithPhotoCache(photoStore,body,ContactPaths(body,root),href,etag,&error); CHECK(mapped);
    graph=RCTwoWayRemap(mapped,[NSDictionary dictionaryWithObject:root forKey:@"contact-validation"]);
  }
  return [NSDictionary dictionaryWithObjectsAndKeys:root,@"key",root,@"root",href,@"href",etag,@"etag",body,@"body",
      graph,@"graph",RCContactNativePaths(body,graph,root,&error),@"paths",[NSNumber numberWithInt:1],@"revision",nil];
}
static void LocalSessionAs(ISyncClient *client,NSDictionary *push,BOOL remove,NSString *eventName)
{
  ISyncSession *s=[ISyncSession beginSessionWithClient:client entityNames:[client enabledEntityNames]
      beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
  CHECK(s);
  @try {
  NSEnumerator *it=[push keyEnumerator]; NSString *id;
  while ((id=[it nextObject])) {
    if (remove) [s deleteRecordWithIdentifier:id];
    else if ([[push objectForKey:id] isKindOfClass:[ISyncChange class]]) [s pushChange:[push objectForKey:id]];
    else [s pushChangesFromRecord:[push objectForKey:id] withIdentifier:id];
  }
  CHECK([s prepareToPullChangesForEntityNames:RCSyncPullableEntities(client) beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]);
  it=[s changeEnumeratorForEntityNames:RCSyncPullableEntities(client)]; ISyncChange *change;
  while ((change=[it nextObject])) {
    NSString *first=[[change record] objectForKey:@"first name"];
    NSString *summary=[[change record] objectForKey:@"summary"], *title=[[change record] objectForKey:@"title"];
    if ([first hasPrefix:marker] || [summary hasPrefix:marker] || [title hasPrefix:marker]) {
      NSString *native=[first hasPrefix:marker] ? ([first isEqual:marker] ? @"fixture" : @"new-fixture") :
          [title hasPrefix:marker] ? @"calendar" : [summary hasPrefix:[marker stringByAppendingString:@"-new"]] ? @"new-event" : eventName;
      [s clientAcceptedChangesForRecordWithIdentifier:[change recordIdentifier] formattedRecord:nil newRecordIdentifier:native];
    }
  }
  [s clientCommittedAcceptedChanges]; [s cancelSyncing];
  } @finally { if (![s isCancelled]) [s cancelSyncing]; }
}
static void LocalSession(ISyncClient *client,NSDictionary *push,BOOL remove)
{
  LocalSessionAs(client,push,remove,@"event");
}
static ISyncClient *LegacyClient(NSString *identifier, NSString *description, NSDictionary *graph)
{
  NSMutableDictionary *desc=[NSMutableDictionary dictionaryWithContentsOfFile:description];
  [desc setObject:[[desc objectForKey:@"Entities"] allKeys] forKey:@"PushOnlyEntities"];
  NSString *path=[description stringByAppendingString:@".legacy.plist"];
  CHECK([desc writeToFile:path atomically:YES]);
  ISyncClient *client=[[ISyncManager sharedManager] registerClientWithIdentifier:identifier descriptionFilePath:path]; CHECK(client);
  [client setEnabled:YES forEntityNames:[[desc objectForKey:@"Entities"] allKeys]];
  ISyncSession *session=[ISyncSession beginSessionWithClient:client entityNames:[client enabledEntityNames] beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]; CHECK(session);
  NSEnumerator *it=[graph keyEnumerator]; NSString *key;
  while ((key=[it nextObject])) [session pushChangesFromRecord:[graph objectForKey:key] withIdentifier:key];
  CHECK([session prepareToPullChangesForEntityNames:[NSArray array] beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]);
  [session finishSyncing];
  return client;
}
static long long Scalar(RCWriteJournal *j,const char *sql)
{
  sqlite3_stmt *q=NULL; long long result=-1;
  CHECK(sqlite3_prepare_v2(j->db,sql,-1,&q,NULL)==SQLITE_OK);
  if (sqlite3_step(q)==SQLITE_ROW) result=sqlite3_column_int64(q,0);
  sqlite3_finalize(q); return result;
}
/* Two-way contacts now includes pre-existing native contacts. Limit this
   synthetic account's encoder to fixtures so unrelated desktop contacts do
   not enter its fake server or affect its operation counts. */
static NSMutableDictionary *EncodeFixtureContact(void *store,NSDictionary *resource,
    NSDictionary *truth,NSString *root,RCError *e)
{
  if (![[[truth objectForKey:root] objectForKey:@"first name"] hasPrefix:marker]) return nil;
  return RCContactEncodeLocal(store,resource,truth,root,e);
}
static void Cleanup(ISyncClient *client)
{
  if (!client) return;
  ISyncSession *s=[ISyncSession beginSessionWithClient:client entityNames:[client enabledEntityNames]
      beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
  CHECK(s);
  NSEnumerator *entities=[[client enabledEntityNames] objectEnumerator]; NSString *entity;
  while ((entity=[entities nextObject])) {
    NSDictionary *snapshot=[[s snapshotOfRecordsInTruth] recordsWithMatchingAttributes:
        [NSDictionary dictionaryWithObject:entity forKey:ISyncRecordEntityNameKey]];
    NSEnumerator *it=[snapshot keyEnumerator]; NSString *id;
    while ((id=[it nextObject])) {
      NSDictionary *record=[snapshot objectForKey:id];
      if ([[record objectForKey:@"first name"] hasPrefix:marker] || [[record objectForKey:@"summary"] hasPrefix:marker] ||
          [[record objectForKey:@"title"] hasPrefix:marker]) [s deleteRecordWithIdentifier:id];
    }
  }
  CHECK([s prepareToPullChangesForEntityNames:RCSyncPullableEntities(client) beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]);
  [s cancelSyncing];
}
static void ContactCreationPolicyTests(int scenario)
{
  BOOL upgrading=scenario==1;
  ISyncManager *manager=[ISyncManager sharedManager];
  ISyncClient *local=nil,*server=nil; RCContactStore *store=NULL;
  @try {
    NSString *description=[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"SyncClient.plist"];
    NSMutableDictionary *desc=[NSMutableDictionary dictionaryWithContentsOfFile:description]; CHECK(desc);
    [desc setObject:@"Retro Cloud Two Way Tests" forKey:@"DisplayName"];
    [desc removeObjectForKey:@"PushOnlyEntities"]; CHECK([desc writeToFile:description atomically:YES]);
    local=[manager registerClientWithIdentifier:@"com.altivecintelligence.tw.test.local" descriptionFilePath:description]; CHECK(local);
    [local setEnabled:YES forEntityNames:[[desc objectForKey:@"Entities"] allKeys]];
    store=RCContactStoreOpen([[NSString stringWithFormat:@"Creation-%d.sqlite",scenario] UTF8String],"synthetic",&error); CHECK(store);
    long long run,collection;
    CHECK(RCContactStoreBeginRun(store,&run,&error));
    CHECK(RCContactStoreGetCollection(store,"https://fixture.invalid/book/","Fixture",&collection,&error));
    CHECK(RCContactStoreFinishCollection(store,collection,run,&error));
    CHECK(RCContactStoreFinishRun(store,run,1,NULL,&error));
    RCWriteJournal j=RCContactStoreWriteJournal(store);
    NSDictionary *card=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.Contact",ISyncRecordEntityNameKey,
        [marker stringByAppendingString:@"-new"],@"first name",@"Tiger",@"last name",@"person",@"display as company",nil];
    LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"new-fixture"],NO);
    RCTwoWayContext c={j,@"com.altivecintelligence.tw.test.server",description,@"com.apple.contacts.Contact",
        [NSArray array],[NSDictionary dictionary],EncodeFixtureContact,store,NO,RCContactProjectVerified,NO};
    server=LegacyClient(c.clientIdentifier,description,c.graph);
    CHECK(RCTwoWayInitialize(&j,&error));
    if (upgrading) {
      ISyncRecordSnapshot *snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:server];
      NSDictionary *records=[snapshot recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:[card objectForKey:@"first name"] forKey:@"first name"]];
      CHECK([records count]==1);
      CHECK(RCTwoWaySQL(&j,&error,"INSERT INTO two_way_accounts VALUES(%lld); INSERT INTO two_way_excluded VALUES(%lld,%Q)",
          j.account,j.account,[[[records allKeys] objectAtIndex:0] UTF8String]));
    }
    /* Migration is scoped to the active account, not every saved account. */
    CHECK(RCTwoWaySQL(&j,&error,"INSERT INTO two_way_excluded VALUES(%lld,'other-account')",j.account+1));
    remoteBodies=[NSMutableDictionary dictionary]; remoteETags=[NSMutableDictionary dictionary]; mutations=0;
    if (upgrading) {
      /* Fail after mingling, while collecting the local creation. A failed
         exchange must not advertise a completed publication or consume edits. */
      CHECK(RCTwoWaySQL(&j,&error,"CREATE TEMP TRIGGER fail_native_journal BEFORE INSERT ON write_operations BEGIN SELECT RAISE(ABORT,'synthetic journal failure'); END"));
      CHECK(!RCTwoWayExchange(&c,&error));
      CHECK(!c.didPublish && !c.didPublishAll);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_publications")==0);
      CHECK(Scalar(&j,"SELECT count(*) FROM write_operations")==0);
      CHECK(RCTwoWaySQL(&j,&error,"DROP TRIGGER fail_native_journal"));
    }
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(c.didPublish && c.didPublishAll);
    CHECK(Scalar(&j,"SELECT count(*) FROM two_way_publications")==1);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    CHECK(Scalar(&j,"SELECT count(*) FROM two_way_excluded")==1);
    CHECK(Scalar(&j,"SELECT count(*) FROM two_way_excluded WHERE record_id='other-account'")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==1);
    CHECK([remoteBodies count]==1);
    NSString *href=[[remoteBodies allKeys] objectAtIndex:0];
    NSData *verifiedBody=[remoteBodies objectForKey:href];
    if (scenario==2) {
      ISyncRecordSnapshot *beforeMissing=[manager snapshotOfRecordsInTruthWithEntityNames:[server enabledEntityNames] usingIdentifiersForClient:server];
      NSDictionary *originalRecords=[beforeMissing recordsWithMatchingAttributes:
          [NSDictionary dictionaryWithObject:[card objectForKey:@"first name"] forKey:@"first name"]];
      CHECK([originalRecords count]==1);
      NSString *originalID=[[originalRecords allKeys] objectAtIndex:0];
      [remoteBodies removeObjectForKey:href]; [remoteETags removeObjectForKey:href];
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(c.didPublish);
      CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
      CHECK(RCTwoWayExchange(&c,&error));
      CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
      CHECK(mutations==1); CHECK([remoteBodies count]==0);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_detached")==1);
      /* Restoring the remote resource must recover its original native ID,
         even though its first imported identity was unavailable at completion. */
      [remoteBodies setObject:verifiedBody forKey:href]; [remoteETags setObject:@"\"restored\"" forKey:href];
      NSDictionary *restored=ContactResource(verifiedBody,@"contact-restored",href,@"\"restored\"");
      c.resources=[NSArray arrayWithObject:restored]; c.graph=[restored objectForKey:@"graph"];
      CHECK(RCTwoWayExchange(&c,&error));
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_detached")==0);
      char *aliasQuery=sqlite3_mprintf("SELECT count(*) FROM two_way_aliases WHERE imported_id='contact-restored' AND native_id=%Q",[originalID UTF8String]);
      CHECK(Scalar(&j,aliasQuery)==1); sqlite3_free(aliasQuery);
      CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0); CHECK(mutations==1);
      puts("PASS: Creation deleted before its first download completes without resurrection; a later restoration recovers its original native identity");
      goto creationDone;
    }
    if (scenario==3) {
      NSMutableDictionary *second=[NSMutableDictionary dictionaryWithDictionary:card];
      [second setObject:@"second edit before acknowledgement" forKey:@"notes"];
      LocalSession(local,[NSDictionary dictionaryWithObject:second forKey:@"new-fixture"],NO);
    }
    if (upgrading) {
      NSMutableString *latest=[NSMutableString stringWithString:[[[NSString alloc] initWithData:verifiedBody encoding:NSUTF8StringEncoding] autorelease]];
      [latest replaceOccurrencesOfString:@"END:VCARD" withString:@"NOTE:Note added on Pinkinium\r\nEND:VCARD" options:0 range:NSMakeRange(0,[latest length])];
      [remoteBodies setObject:[latest dataUsingEncoding:NSUTF8StringEncoding] forKey:href];
      [remoteETags setObject:@"\"newer-note\"" forKey:href];
    }
    NSDictionary *created=ContactResource([remoteBodies objectForKey:href],@"contact-created",href,[remoteETags objectForKey:href]);
    if (upgrading) {
      NSMutableString *different=[NSMutableString stringWithString:[[[NSString alloc] initWithData:[remoteBodies objectForKey:href] encoding:NSUTF8StringEncoding] autorelease]];
      [different replaceOccurrencesOfString:@"UID:" withString:@"UID:recreated-" options:0 range:NSMakeRange(0,[different length])];
      NSDictionary *recreated=ContactResource([different dataUsingEncoding:NSUTF8StringEncoding],@"contact-created",href,@"\"recreated\"");
      c.resources=[NSArray arrayWithObject:recreated]; c.graph=[recreated objectForKey:@"graph"];
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(c.didPublish);
      CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='applied'")==1);
    }

    c.resources=[NSArray arrayWithObject:created]; c.graph=[created objectForKey:@"graph"];
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    if (scenario==3) {
      CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
      CHECK(!c.didPublishAll);
      CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued' AND kind='update' AND base_etag='\"write-1\"'")==1);
      RCContactStoreClose(store); store=RCContactStoreOpen("Creation-3.sqlite","synthetic",&error); CHECK(store);
      j=RCContactStoreWriteJournal(store); c.journal=j; c.context=store;
      CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==2);
      created=ContactResource([remoteBodies objectForKey:href],@"contact-created",href,[remoteETags objectForKey:href]);
      c.resources=[NSArray arrayWithObject:created]; c.graph=[created objectForKey:@"graph"];
      CHECK(RCTwoWayExchange(&c,&error));
      CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==2);
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
      CHECK([remoteBodies count]==1);
      CHECK([[[[created objectForKey:@"graph"] objectForKey:@"contact-created"] objectForKey:@"notes"] isEqual:@"second edit before acknowledgement"]);
      puts("PASS: A newer local edit becomes a durable conditional successor, survives reopening and completes without duplicate creation");
      goto creationDone;
    }
    if (upgrading) {
      ISyncRecordSnapshot *snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
      NSDictionary *native=[[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"new-fixture"]] objectForKey:@"new-fixture"];
      CHECK([[native objectForKey:@"notes"] isEqual:@"Note added on Pinkinium"]);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_attention WHERE reason='verified-write-awaits-matching-mirror'")==0);
      puts("PASS: Newer remote contact note publishes on the original identity after verified creation; changed UID defers");
    }

    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations")==1); CHECK(mutations==1);
    puts(upgrading ? "PASS: Previously excluded contact uploads after upgrade without duplicate PUTs; other account exclusions retained" :
        "PASS: Contact created before first two-way sync uploads and acknowledges without duplicate PUTs");
  creationDone: ;
  } @finally {
    Cleanup(local); Cleanup(server); if(local) [manager unregisterClient:local]; if(server) [manager unregisterClient:server];
    RCContactStoreClose(store);
  }
}
static void CalendarMapperRegressionTests(RCCalendarStore *);
static void ExpandedCalendarTests(RCCalendarStore *);
static void CalendarOperationTests(RCCalendarStore *);
static void ContactEmptyMapperTests(RCContactStore *store)
{
  NSData *body=[@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:empty-contact\r\nN:Fixture;Empty;;;\r\nFN:Empty Fixture\r\nNOTE:old\r\nTEL:123\r\nX-PRIVATE:keep\r\nEND:VCARD\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *resource=ContactResource(body,@"empty-contact",@"https://fixture.invalid/book/empty.vcf",@"\"base\"");
  NSMutableDictionary *truth=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
  NSMutableDictionary *contact=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"empty-contact"]];
  [truth setObject:contact forKey:@"empty-contact"];
  [contact removeObjectForKey:@"display as company"];
  [contact setObject:@"" forKey:@"nickname"];
  [contact setObject:@"" forKey:@"birthday"];
  NSString *phoneID=[[contact objectForKey:@"phone numbers"] objectAtIndex:0];
  NSMutableDictionary *phone=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:phoneID]];
  [phone setObject:@"" forKey:@"type"]; [phone setObject:@"" forKey:@"label"];
  [truth setObject:phone forKey:phoneID];
  NSDictionary *desired=RCContactEncodeLocal(store,resource,truth,@"empty-contact",&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  [contact setObject:@"" forKey:@"notes"];
  desired=RCContactEncodeLocal(store,resource,truth,@"empty-contact",&error); CHECK(desired);
  NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"NOTE:old"].location==NSNotFound);
  CHECK([wire rangeOfString:@"X-PRIVATE:keep\r\n"].location!=NSNotFound);
  CHECK(RCContactEncodeLocal(store,nil,truth,@"empty-contact",&error));
  [phone setObject:@"work" forKey:@"type"];
  CHECK(RCContactEncodeLocal(store,resource,truth,@"empty-contact",&error));
  puts("PASS: Empty contact text, birthday, labels and omitted person/other defaults round-trip without hiding label edits");
}
static void FieldMapperTests(RCContactStore *contacts)
{
  NSString *wire=@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:fields\r\nN:Fixture;Fields;;;\r\nFN:Fields Fixture\r\nNOTE:old\r\nPHOTO;ENCODING=b:YWJj\r\nTEL;TYPE=HOME:123\r\nX-FUTURE;X-PARAM=keep:opaque\r\nEND:VCARD\r\n";
  NSDictionary *base=ContactResource([wire dataUsingEncoding:NSUTF8StringEncoding],@"fields",@"https://fixture.invalid/book/fields.vcf",@"\"base\"");
  NSMutableDictionary *truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[base objectForKey:@"graph"]]];
  NSMutableDictionary *card=[truth objectForKey:@"fields"], *phone=[truth objectForKey:@"fields-TEL-0"];
  [card setObject:[@"local-photo" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"future contact field"];
  [card setObject:@"new note" forKey:@"notes"];
  [phone setObject:@"work" forKey:@"type"]; [phone setObject:@"456" forKey:@"value"];
  [phone setObject:@"future value" forKey:@"future field"];
  NSDictionary *desired=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,base,truth,@"fields",&error); CHECK(desired);
  NSString *encoded=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([encoded rangeOfString:@"NOTE:new note\r\n"].location!=NSNotFound);
  CHECK([encoded rangeOfString:@"TEL;TYPE=WORK:456\r\n"].location!=NSNotFound);
  CHECK([encoded rangeOfString:@"PHOTO;ENCODING=b:YWJj\r\n"].location!=NSNotFound);
  CHECK([encoded rangeOfString:@"X-FUTURE;X-PARAM=keep:opaque\r\n"].location!=NSNotFound);
  CHECK([[[desired objectForKey:@"pendingFields"] objectForKey:@"fields"] containsObject:@"future contact field"]);
  CHECK(![[[desired objectForKey:@"pendingFields"] objectForKey:@"fields-TEL-0"] containsObject:@"type"]);
  CHECK([[[desired objectForKey:@"pendingFields"] objectForKey:@"fields-TEL-0"] containsObject:@"future field"]);
  CHECK(RCNativeScopeMatches(truth,[desired objectForKey:@"graph"],[desired objectForKey:@"fieldScopes"]));
  CHECK(!RCNativeScopeMatches(truth,[desired objectForKey:@"graph"],nil));
  CHECK(![[desired objectForKey:@"graph"] isEqual:truth]);
  NSDictionary *replay=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,desired,truth,@"fields",&error); CHECK(replay);
  CHECK([[replay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  CHECK([[replay objectForKey:@"pendingFields"] isEqual:[desired objectForKey:@"pendingFields"]]);
  [card setObject:@"newer local note" forKey:@"notes"];
  CHECK(!RCNativeScopeMatches(truth,[desired objectForKey:@"graph"],[desired objectForKey:@"fieldScopes"]));
  [card setObject:@"new note" forKey:@"notes"];
  NSDictionary *saved=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:desired]];
  CHECK(RCNativeScopeMatches(truth,[saved objectForKey:@"graph"],[saved objectForKey:@"fieldScopes"]));
  NSMutableDictionary *deleted=[NSMutableDictionary dictionaryWithDictionary:truth]; [deleted removeObjectForKey:@"fields"];
  CHECK(!RCNativeScopeMatches(deleted,[saved objectForKey:@"graph"],[saved objectForKey:@"fieldScopes"]));
  CHECK(!RCNativeScopeMatches(truth,[NSDictionary dictionaryWithObject:[NSNull null] forKey:@"fields"],[saved objectForKey:@"fieldScopes"]));
  [card setObject:[NSArray arrayWithObject:@"website"] forKey:@"URLs"];
  [truth setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.URL",ISyncRecordEntityNameKey,@"home page",@"type",[NSURL URLWithString:@"https://fixture.invalid/"],@"value",[NSArray arrayWithObject:@"fields"],@"contact",nil] forKey:@"website"];
  desired=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,nil,truth,@"fields",&error); CHECK(desired);
  CHECK([[[desired objectForKey:@"graph"] objectForKey:@"website"] objectForKey:@"type"]);
  CHECK([[[[desired objectForKey:@"graph"] objectForKey:@"website"] objectForKey:@"type"] isEqual:@"home page"]);
  CHECK([[[desired objectForKey:@"pendingFields"] objectForKey:@"fields"] containsObject:@"future contact field"]);
  replay=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,desired,truth,@"fields",&error); CHECK(replay);
  CHECK([[replay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  NSMutableDictionary *website=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"website"]];
  [website setObject:@"future URL type" forKey:@"type"]; [truth setObject:website forKey:@"website"];
  desired=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,nil,truth,@"fields",&error); CHECK(desired);
  CHECK([[[desired objectForKey:@"pendingFields"] objectForKey:@"website"] containsObject:@"type"]);
  CHECK([[[[desired objectForKey:@"graph"] objectForKey:@"website"] objectForKey:@"type"] isEqual:@"other"]);
  replay=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,desired,truth,@"fields",&error); CHECK(replay);
  CHECK([[replay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  NSDictionary *opaqueOnly=[NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.Contact",ISyncRecordEntityNameKey,[@"photo" dataUsingEncoding:NSUTF8StringEncoding],@"future contact field",nil] forKey:@"opaque"];
  CHECK(!RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,nil,opaqueOnly,@"opaque",&error));
  NSString *legacyWire=@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:legacy-fields\r\nN:Fixture;Legacy;;;\r\nFN:Legacy Fixture\r\nNOTE;CHARSET=ISO-8859-1:old\r\nTEL;TYPE=HOME:123\r\nX-FUTURE:keep\r\nEND:VCARD\r\n";
  NSDictionary *legacy=ContactResource([legacyWire dataUsingEncoding:NSUTF8StringEncoding],@"legacy",@"https://fixture.invalid/book/legacy.vcf",@"\"base\"");
  NSMutableDictionary *legacyTruth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[legacy objectForKey:@"graph"]]];
  [[legacyTruth objectForKey:@"legacy"] setObject:@"unrepresentable note edit" forKey:@"notes"];
  [[legacyTruth objectForKey:@"legacy-TEL-0"] setObject:@"456" forKey:@"value"];
  NSDictionary *legacyResult=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,legacy,legacyTruth,@"legacy",&error); CHECK(legacyResult);
  NSString *legacyEncoded=[[[NSString alloc] initWithData:[legacyResult objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([legacyEncoded rangeOfString:@"NOTE;CHARSET=ISO-8859-1:old\r\n"].location!=NSNotFound);
  CHECK([legacyEncoded rangeOfString:@"TEL;TYPE=HOME:456\r\n"].location!=NSNotFound);
  CHECK([legacyEncoded rangeOfString:@"X-FUTURE:keep\r\n"].location!=NSNotFound);
  CHECK([[[legacyResult objectForKey:@"pendingFields"] objectForKey:@"legacy"] containsObject:@"notes"]);
  CHECK(RCNativeScopeMatches(legacyTruth,[legacyResult objectForKey:@"graph"],[legacyResult objectForKey:@"fieldScopes"]));
  CHECK(![[[legacyResult objectForKey:@"fieldScopes"] objectForKey:@"legacy"] containsObject:@"notes"]);
  NSDictionary *legacyReplay=RCTwoWayEncodeFields(RCContactEncodeLocal,contacts,legacyResult,legacyTruth,@"legacy",&error); CHECK(legacyReplay);
  CHECK([[legacyReplay objectForKey:@"body"] isEqual:[legacyResult objectForKey:@"body"]]);
  puts("PASS: An uneditable legacy NOTE remains pending while an independent phone edit validates and replays without rewriting legacy/private bytes");
  puts("PASS: Field-scoped contact edits and partial creation preserve raw data, retain unsupported contact/label fields, detect newer edits and replay without duplicate writes");
}
static void PhotoMapperTests(RCContactStore *store)
{
  /* Includes every byte, embedded NULs, all padding lengths, and folded lines. */
  unsigned char bytes[257]; NSUInteger n;
  for(n=0;n<sizeof(bytes);n++) bytes[n]=(unsigned char)n;
  for(n=1;n<=sizeof(bytes);n++) {
    NSData *data=[NSData dataWithBytes:bytes length:n];
    CHECK([RCPhotoDecode([RCPhotoEncode(data) UTF8String]) isEqual:data]);
  }
  CHECK(!RCPhotoDecode("a")); CHECK(!RCPhotoDecode("YWJj!"));
  CHECK(!RCPhotoDecode("=AAA")); CHECK(!RCPhotoDecode("YQ=A"));
  CHECK(!RCPhotoDecode("YR==")); CHECK(!RCPhotoDecode("YQ==YQ=="));
  CHECK(!RCPhotoDecode("YWJ=")); CHECK(!RCPhotoEncode(@"not binary"));
  NSString *wire=@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:photo\r\nN:Fixture;Photo;;;\r\nFN:Photo Fixture\r\nNOTE:old\r\nitem1.PHOTO;ENCODING=b;TYPE=JPEG;X-KEEP=yes:YWJj\r\nX-PRIVATE:keep\r\nEND:VCARD\r\n";
  NSDictionary *base=ContactResource([wire dataUsingEncoding:NSUTF8StringEncoding],@"photo",@"https://fixture.invalid/book/photo.vcf",@"\"base\"");
  CHECK([[[[base objectForKey:@"graph"] objectForKey:@"photo"] objectForKey:@"image"] isEqual:[@"abc" dataUsingEncoding:NSUTF8StringEncoding]]);
  NSMutableDictionary *oldReceipt=[NSMutableDictionary dictionaryWithDictionary:[[base objectForKey:@"graph"] objectForKey:@"photo"]];
  [oldReceipt removeObjectForKey:@"image"];
  NSDictionary *legacyGraph=[NSDictionary dictionaryWithObject:oldReceipt forKey:@"photo"];
  NSDictionary *legacyScope=[NSDictionary dictionaryWithObject:[oldReceipt allKeys] forKey:@"photo"];
  CHECK(RCNativeUploadedGraphMatches([base objectForKey:@"graph"],legacyGraph,legacyScope));
  CHECK(RCNativeUploadedGraphMatches([base objectForKey:@"graph"],legacyGraph,nil));
  NSDictionary *imageScope=[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:@"image"] forKey:@"photo"];
  CHECK(!RCNativeUploadedGraphMatches([base objectForKey:@"graph"],legacyGraph,imageScope));
  [oldReceipt setObject:@"wrong note" forKey:@"notes"];
  CHECK(!RCNativeUploadedGraphMatches([base objectForKey:@"graph"],legacyGraph,legacyScope));
  [oldReceipt setObject:@"old" forKey:@"notes"];
  [oldReceipt setObject:[@"different" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"image"];
  CHECK(!RCNativeUploadedGraphMatches([base objectForKey:@"graph"],legacyGraph,legacyScope));
  NSMutableDictionary *truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[base objectForKey:@"graph"]]];
  NSMutableDictionary *card=[truth objectForKey:@"photo"];
  NSData *image=[NSData dataWithBytes:bytes length:sizeof(bytes)];
  [card setObject:image forKey:@"image"];
  NSDictionary *desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,base,truth,@"photo",&error); CHECK(desired);
  CHECK(![[desired objectForKey:@"pendingFields"] count]);
  CHECK(RCNativeScopeMatches(truth,[desired objectForKey:@"graph"],[desired objectForKey:@"fieldScopes"]));
  NSString *encoded=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([encoded rangeOfString:@"item1.PHOTO;ENCODING=b;X-KEEP=yes:"].location!=NSNotFound);
  CHECK([encoded rangeOfString:@"X-PRIVATE:keep\r\n"].location!=NSNotFound);
  CHECK([encoded rangeOfString:@"\r\n "].location!=NSNotFound);
  NSDictionary *imported=ContactResource([desired objectForKey:@"body"],@"photo",[base objectForKey:@"href"],@"\"next\"");
  CHECK([[[[imported objectForKey:@"graph"] objectForKey:@"photo"] objectForKey:@"image"] isEqual:image]);
  NSDictionary *replay=RCTwoWayEncodeFields(RCContactEncodeLocal,store,imported,truth,@"photo",&error); CHECK(replay);
  CHECK([[replay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  [card removeObjectForKey:@"image"];
  NSDictionary *removed=RCTwoWayEncodeFields(RCContactEncodeLocal,store,imported,truth,@"photo",&error); CHECK(removed);
  CHECK(![[removed objectForKey:@"pendingFields"] count]);
  encoded=[[[NSString alloc] initWithData:[removed objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([encoded rangeOfString:@"PHOTO"].location==NSNotFound);
  [card setObject:image forKey:@"image"];
  desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,nil,truth,@"photo",&error); CHECK(desired);
  CHECK(![[desired objectForKey:@"pendingFields"] count]);
  CHECK([[[RCContactNativeGraphForPaths([desired objectForKey:@"body"],[desired objectForKey:@"paths"],&error) objectForKey:@"contact-validation"] objectForKey:@"image"] isEqual:image]);
  NSArray *opaque=[NSArray arrayWithObjects:@"PHOTO;VALUE=uri:https://fixture.invalid/photo.jpg",@"PHOTO;ENCODING=b:bad!",@"PHOTO;ENCODING=b:YQ==\r\nPHOTO;ENCODING=b:Yg==",nil];
  NSEnumerator *it=[opaque objectEnumerator]; NSString *photo;
  while ((photo=[it nextObject])) {
    NSString *raw=Replace(wire,@"item1.PHOTO;ENCODING=b;TYPE=JPEG;X-KEEP=yes:YWJj",photo);
    NSDictionary *resource=ContactResource([raw dataUsingEncoding:NSUTF8StringEncoding],@"photo",[base objectForKey:@"href"],@"\"opaque\"");
    CHECK(![[[resource objectForKey:@"graph"] objectForKey:@"photo"] objectForKey:@"image"]);
    NSMutableDictionary *graph=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[resource objectForKey:@"graph"]]];
    [[graph objectForKey:@"photo"] setObject:@"independent note" forKey:@"notes"];
    desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,resource,graph,@"photo",&error);
    if ([photo rangeOfString:@"VALUE=uri"].location!=NSNotFound) CHECK(!desired);
    else {
      CHECK(desired);
      encoded=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
      CHECK([encoded rangeOfString:photo].location!=NSNotFound);
    }
    [[graph objectForKey:@"photo"] setObject:image forKey:@"image"];
    desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,resource,graph,@"photo",&error); CHECK(desired);
    if ([photo rangeOfString:@"\r\n"].location!=NSNotFound)
      CHECK([[[desired objectForKey:@"pendingFields"] objectForKey:@"photo"] containsObject:@"image"]);
    else CHECK(![[desired objectForKey:@"pendingFields"] count]);
  }
  NSDictionary *imageOnly=[NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
      @"com.apple.contacts.Contact",ISyncRecordEntityNameKey,image,@"image",nil] forKey:@"photo"];
  CHECK(RCTwoWayEncodeFields(RCContactEncodeLocal,store,nil,imageOnly,@"photo",&error));
  [card setObject:@"not binary" forKey:@"image"]; [card setObject:@"safe note" forKey:@"notes"];
  desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,base,truth,@"photo",&error); CHECK(desired);
  CHECK([[[desired objectForKey:@"pendingFields"] objectForKey:@"photo"] containsObject:@"image"]);
  CHECK([[[[desired objectForKey:@"graph"] objectForKey:@"photo"] objectForKey:@"notes"] isEqual:@"safe note"]);
  NSString *quoted=Replace(wire,@"X-KEEP=yes",@"X-KEEP=\"a;b\"");
  NSDictionary *quotedBase=ContactResource([quoted dataUsingEncoding:NSUTF8StringEncoding],@"photo",[base objectForKey:@"href"],@"\"quoted\"");
  [card setObject:image forKey:@"image"];
  desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,quotedBase,truth,@"photo",&error); CHECK(desired);
  CHECK([[[desired objectForKey:@"pendingFields"] objectForKey:@"photo"] containsObject:@"image"]);
  encoded=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([encoded rangeOfString:@"X-KEEP=\"a;b\""].location!=NSNotFound);
  puts("PASS: Binary photos import, create, replace, delete, fold and replay exactly; opaque photos survive independent edits");
}
static void URIPhotoTests(RCContactStore *store)
{
  NSMutableDictionary *savedBodies=remoteBodies, *savedETags=remoteETags, *savedPhotos=remotePhotos;
  remoteBodies=[NSMutableDictionary dictionary]; remoteETags=[NSMutableDictionary dictionary]; remotePhotos=[NSMutableDictionary dictionary];
  NSString *href=@"https://fixture.invalid/book/uri.vcf", *uri=@"https://fixture.invalid/book/uri.vcf/photo", *etag=@"\"uri-1\"";
  NSString *wire=[NSString stringWithFormat:@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:uri\r\nN:Fixture;URI;;;\r\nFN:URI Fixture\r\nNOTE:old\r\nPHOTO;TYPE=JPEG;VALUE=uri:%@\r\nEND:VCARD\r\n",uri];
  NSData *body=[wire dataUsingEncoding:NSUTF8StringEncoding], *image=[@"first photo" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *paths=ContactPaths(body,@"uri");
  [remoteBodies setObject:body forKey:href]; [remoteETags setObject:etag forKey:href];
  CHECK(!RCContactNativeGraphWithPhotoCache(store,body,paths,href,etag,&error));
  CHECK(!RCContactPhotoFetch(store,(RCHTTPClient *)1,href,etag,body,&error)); /* 404 must not clear image */
  [remotePhotos setObject:image forKey:uri];
  photoResponseType="text/html";
  CHECK(!RCContactPhotoFetch(store,(RCHTTPClient *)1,href,etag,body,&error));
  photoResponseType="image/jpeg";
  CHECK(!RCContactPhotoFetch(store,(RCHTTPClient *)1,href,@"\"wrong-version\"",body,&error));
  CHECK(RCContactPhotoFetch(store,(RCHTTPClient *)1,href,etag,body,&error));
  int before=photoGETs;
  CHECK(RCContactPhotoFetch(store,(RCHTTPClient *)1,href,etag,body,&error)); CHECK(photoGETs==before);
  NSDictionary *mapped=RCContactNativeGraphWithPhotoCache(store,body,paths,href,etag,&error); CHECK(mapped);
  CHECK([[[mapped objectForKey:@"contact-validation"] objectForKey:@"image"] isEqual:image]);
  NSDictionary *graph=RCTwoWayRemap(mapped,[NSDictionary dictionaryWithObject:@"uri" forKey:@"contact-validation"]);
  NSDictionary *resource=[NSDictionary dictionaryWithObjectsAndKeys:body,@"body",graph,@"graph",paths,@"paths",href,@"href",etag,@"etag",@"uri",@"root",nil];
  NSMutableDictionary *truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:graph]];
  [[truth objectForKey:@"uri"] setObject:@"new note" forKey:@"notes"];
  NSDictionary *desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,resource,truth,@"uri",&error); CHECK(desired);
  CHECK(![[desired objectForKey:@"pendingFields"] count]);
  NSString *encoded=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([encoded rangeOfString:uri].location!=NSNotFound); /* preserve URI on unrelated edits */
  NSData *newImage=[@"second photo" dataUsingEncoding:NSUTF8StringEncoding];
  [remoteETags setObject:@"\"uri-2\"" forKey:href]; [remotePhotos setObject:newImage forKey:uri];
  CHECK(RCContactPhotoFetch(store,(RCHTTPClient *)1,href,@"\"uri-2\"",body,&error));
  mapped=RCContactNativeGraphWithPhotoCache(store,body,paths,href,etag,&error); CHECK(mapped);
  CHECK([[[mapped objectForKey:@"contact-validation"] objectForKey:@"image"] isEqual:image]);
  mapped=RCContactNativeGraphWithPhotoCache(store,body,paths,href,@"\"uri-2\"",&error); CHECK(mapped);
  CHECK([[[mapped objectForKey:@"contact-validation"] objectForKey:@"image"] isEqual:newImage]);
  NSMutableDictionary *newer=[NSMutableDictionary dictionaryWithDictionary:resource];
  [newer setObject:@"\"uri-2\"" forKey:@"etag"]; [newer setObject:etag forKey:@"verifiedETag"];
  CHECK([[[[RCContactProjectVerified(store,newer,body,&error) objectForKey:@"graph"] objectForKey:@"uri"] objectForKey:@"image"] isEqual:image]);
  NSString *unsafe=Replace(wire,uri,@"http://fixture.invalid/photo");
  CHECK(!RCContactPhotoFetch(store,(RCHTTPClient *)1,href,etag,[unsafe dataUsingEncoding:NSUTF8StringEncoding],&error));
  /* Exercise the post-writer path without requiring the mirror to catch up. */
  RCWriteJournal j=RCContactStoreWriteJournal(store); long long operation=0;
  CHECK(RCWriteJournalSetBase(&j,"uri-cache-test",[href UTF8String],"\"uri-2\"",[body bytes],[body length],1,&error));
  CHECK(RCWriteJournalEnqueue(&j,"uri-cache-write","uri-cache-test",[href UTF8String],"update",1,[body bytes],[body length],&operation,&error));
  CHECK(RCWriteJournalBeginAttempt(&j,operation,1,&error));
  CHECK(RCWriteJournalRecordResult(&j,operation,"applied",200,"\"uri-3\"",[body bytes],[body length],&error));
  [remoteETags setObject:@"\"uri-3\"" forKey:href];
  CHECK(RCContactPhotoRefreshWrites(store,(RCHTTPClient *)1,&error));
  mapped=RCContactNativeGraphWithPhotoCache(store,body,paths,href,@"\"uri-3\"",&error); CHECK(mapped);
  CHECK([[[mapped objectForKey:@"contact-validation"] objectForKey:@"image"] isEqual:newImage]);
  CHECK(RCWriteJournalAcknowledge(&j,operation,&error));
  remoteBodies=savedBodies; remoteETags=savedETags; remotePhotos=savedPhotos;
  puts("PASS: URI photo cache verifies owning ETags, preserves historical bytes, retries missing photos and maps without network inside native sessions");
}
static void ExpandedContactTests(RCContactStore *store)
{
  NSData *body=[@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:expanded\r\nN:Fixture;Expanded;;;\r\nFN:Expanded Fixture\r\nitem1.TEL;TYPE=HOME,PREF;X-KEEP=yes:123\r\nitem2.EMAIL;TYPE=WORK:one@example.invalid\r\nitem3.EMAIL;TYPE=HOME,PREF:two@example.invalid\r\nitem4.X-ABDATE:2000-01-02\r\nitem4.X-ABLabel:_$!<Anniversary>!$_\r\nitem5.X-ABRELATEDNAMES:Someone\r\nitem5.X-ABLabel:_$!<Spouse>!$_\r\nitem6.IMPP;TYPE=HOME:xmpp:someone@example.invalid\r\nX-AIM:oldaim\r\nTEL:789\r\nX-PHONETIC-FIRST-NAME:Old\r\nX-PRIVATE:keep\r\nEND:VCARD\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *r=ContactResource(body,@"expanded",@"https://fixture.invalid/book/expanded.vcf",@"\"base\"");
  NSMutableDictionary *truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[r objectForKey:@"graph"]]];
  NSMutableDictionary *card=[truth objectForKey:@"expanded"];
  CHECK([[card objectForKey:@"dates"] count]==1 && [[card objectForKey:@"related names"] count]==1 && [[card objectForKey:@"IMs"] count]==2);
  CHECK([[[truth objectForKey:@"expanded-X-ABDATE-0"] objectForKey:@"type"] isEqual:@"anniversary"]);
  [[truth objectForKey:@"expanded-TEL-0"] setObject:@"other" forKey:@"type"];
  [[truth objectForKey:@"expanded-TEL-0"] setObject:@"Desk" forKey:@"label"];
  [[truth objectForKey:@"expanded-TEL-1"] setObject:@"Personal line" forKey:@"label"];
  [[truth objectForKey:@"expanded-IMPP-1"] setObject:@"newaim" forKey:@"user"];
  [[truth objectForKey:@"expanded-IMPP-1"] setObject:@"yahoo" forKey:@"service"];
  [card setObject:[NSArray arrayWithObject:@"expanded-EMAIL-0"] forKey:@"primary email address"];
  [card setObject:@"New phonetic" forKey:@"first name yomi"];
  [[truth objectForKey:@"expanded-X-ABRELATEDNAMES-0"] setObject:@"partner" forKey:@"type"];
  [[truth objectForKey:@"expanded-IMPP-0"] setObject:@"new@example.invalid" forKey:@"user"];
  NSDictionary *desired=RCTwoWayEncodeFields(RCContactEncodeLocal,store,r,truth,@"expanded",&error); CHECK(desired);
  CHECK(![[desired objectForKey:@"pendingFields"] count]);
  NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"X-KEEP=yes"].location!=NSNotFound && [wire rangeOfString:@"X-PRIVATE:keep"].location!=NSNotFound);
  CHECK([wire rangeOfString:@"_$!<Partner>!$_"].location!=NSNotFound && [wire rangeOfString:@"X-ABLabel:Desk"].location!=NSNotFound);
  CHECK(RCContactEncodeLocal(store,nil,truth,@"expanded",&error));
  NSDictionary *replay=RCContactEncodeLocal(store,desired,truth,@"expanded",&error); CHECK(replay);
  CHECK([[replay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  [card removeObjectForKey:@"dates"]; [truth removeObjectForKey:@"expanded-X-ABDATE-0"];
  [card removeObjectForKey:@"IMs"]; [truth removeObjectForKey:@"expanded-IMPP-0"]; [truth removeObjectForKey:@"expanded-IMPP-1"];
  CHECK(RCContactEncodeLocal(store,desired,truth,@"expanded",&error));
  puts("PASS: Labels, preferred email, phonetic names, anniversaries, related names and IM accounts import, edit, create, remove and replay");
}

static void MapperTests(void)
{
  CHECK(RCTwoWayRecordsEqual([NSDictionary dictionary], [NSDictionary dictionaryWithObject:[NSArray array] forKey:@"phone numbers"]));
  CHECK(!RCTwoWayRecordsEqual([NSDictionary dictionaryWithObject:[NSArray arrayWithObjects:@"monday",@"friday",nil] forKey:@"bydaydays"],
      [NSDictionary dictionaryWithObject:[NSArray arrayWithObjects:@"friday",@"monday",nil] forKey:@"bydaydays"]));
  RCContactStore *contacts=RCContactStoreOpen("MapperContacts.sqlite","synthetic",&error); CHECK(contacts);
  long long run,collection;
  CHECK(RCContactStoreBeginRun(contacts,&run,&error));
  CHECK(RCContactStoreGetCollection(contacts,"https://fixture.invalid/book/","Fixture",&collection,&error));
  CHECK(RCContactStoreFinishCollection(contacts,collection,run,&error));
  CHECK(RCContactStoreFinishRun(contacts,run,1,NULL,&error));
  NSString *raw=@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:fixture\r\nN:Fixture;Original;;;\r\nFN:Original Fixture\r\nNOTE:old\r\nPHOTO;ENCODING=b:YWJj\r\nX-APPLE-PRIVATE;X-PARAM=keep:preserve\r\nEND:VCARD\r\n";
  NSDictionary *r=ContactResource([raw dataUsingEncoding:NSUTF8StringEncoding],@"fixture",@"https://fixture.invalid/book/fixture.vcf",@"\"base\"");
  NSMutableDictionary *truth=[NSMutableDictionary dictionaryWithDictionary:[r objectForKey:@"graph"]];
  NSMutableDictionary *card=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"fixture"]];
  [card setObject:@"new; note\nUnicode café" forKey:@"notes"]; [truth setObject:card forKey:@"fixture"];
  NSDictionary *desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  NSString *result=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([result rangeOfString:@"PHOTO;ENCODING=b:YWJj\r\n"].location!=NSNotFound);
  CHECK([result rangeOfString:@"X-APPLE-PRIVATE;X-PARAM=keep:preserve\r\n"].location!=NSNotFound);
  CHECK(RCContactEncodeLocal(contacts,nil,truth,@"fixture",&error));
  NSDictionary *newer=ContactResource([desired objectForKey:@"body"],@"fixture",@"https://fixture.invalid/book/fixture.vcf",@"\"newer\"");
  CHECK(RCContactProjectVerified(contacts,newer,[raw dataUsingEncoding:NSUTF8StringEncoding],&error));
  NSMutableString *withPhone=[NSMutableString stringWithString:raw];
  [withPhone replaceOccurrencesOfString:@"END:VCARD" withString:@"TEL;TYPE=HOME:555-1234\r\nEND:VCARD" options:0 range:NSMakeRange(0,[withPhone length])];
  newer=ContactResource([withPhone dataUsingEncoding:NSUTF8StringEncoding],@"fixture",@"https://fixture.invalid/book/fixture.vcf",@"\"newer\"");
  CHECK(!RCContactProjectVerified(contacts,newer,[raw dataUsingEncoding:NSUTF8StringEncoding],&error));

  [card setObject:[NSArray arrayWithObject:@"unknown"] forKey:@"email addresses"];
  CHECK(!RCContactEncodeLocal(contacts,r,truth,@"fixture",&error));
  NSData *structured=[@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:structured\r\nN:Fixture,Alternate;Original;;;\r\nFN:Original Fixture\r\nORG:Company;Department;Hidden\r\nADR;TYPE=HOME:Box 1;Unit 2;Street;Old City;State;12345;Country\r\nEND:VCARD\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  r=ContactResource(structured,@"fixture",@"https://fixture.invalid/book/structured.vcf",@"\"base\"");
  truth=[NSMutableDictionary dictionaryWithDictionary:[r objectForKey:@"graph"]];
  card=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"fixture"]]; [card setObject:@"Renamed" forKey:@"first name"]; [card setObject:@"New Company" forKey:@"company name"]; [truth setObject:card forKey:@"fixture"];
  NSMutableDictionary *address=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"fixture-ADR-0"]]; [address setObject:@"New City" forKey:@"city"]; [truth setObject:address forKey:@"fixture-ADR-0"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  result=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([result rangeOfString:@"N:Fixture,Alternate;Renamed;;;"].location!=NSNotFound);
  CHECK([result rangeOfString:@"ORG:New Company;Department;Hidden"].location!=NSNotFound);
  CHECK([result rangeOfString:@"ADR;TYPE=HOME:Box 1;Unit 2;Street;New City;State;12345;Country"].location!=NSNotFound);
  NSData *emptyFields=[@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:empty-fields\r\nN:Fixture;Original;;;\r\nFN:Original Fixture\r\nTEL:\r\nTEL;TYPE=HOME:123\r\nEMAIL:\r\nEMAIL;TYPE=WORK:old@example.invalid\r\nURL:\r\nURL:https://fixture.invalid/old\r\nNOTE:old\r\nEND:VCARD\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  r=ContactResource(emptyFields,@"fixture",@"https://fixture.invalid/book/empty.vcf",@"\"base\"");
  CHECK([[[r objectForKey:@"paths"] objectForKey:@"TEL:1"] isEqual:@"fixture-TEL-1"]);
  CHECK(![[r objectForKey:@"paths"] objectForKey:@"TEL:0"]);
  truth=[NSMutableDictionary dictionaryWithDictionary:[r objectForKey:@"graph"]];
  card=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"fixture"]];
  [card setObject:@"note edit with empty fields" forKey:@"notes"]; [truth setObject:card forKey:@"fixture"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  NSMutableDictionary *editedPhone=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"fixture-TEL-1"]];
  [editedPhone setObject:@"456" forKey:@"value"]; [truth setObject:editedPhone forKey:@"fixture-TEL-1"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  result=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([result rangeOfString:@"TEL:\r\nTEL;TYPE=HOME:456\r\n"].location!=NSNotFound);
  [card removeObjectForKey:@"phone numbers"]; [truth removeObjectForKey:@"fixture-TEL-1"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  result=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([result rangeOfString:@"TEL:\r\n"].location!=NSNotFound);
  CHECK([result rangeOfString:@"TEL;TYPE=HOME:123"].location==NSNotFound);
  [card setObject:[NSArray arrayWithObject:@"added-phone"] forKey:@"phone numbers"];
  [truth setObject:editedPhone forKey:@"added-phone"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  CHECK([[[desired objectForKey:@"paths"] objectForKey:@"TEL:1"] isEqual:@"added-phone"]);
  puts("PASS: Empty raw contact fields preserve occurrence identities through note edits, value edits, removal and addition");
  ExpandedContactTests(contacts);
  FieldMapperTests(contacts);
  PhotoMapperTests(contacts);
  URIPhotoTests(contacts);
  ContactEmptyMapperTests(contacts);
  RCContactStoreClose(contacts);

  RCCalendarStore *cal=RCCalendarStoreOpen("MapperCalendar.sqlite","synthetic",&error); CHECK(cal);
  RCWriteJournal j=RCCalendarStoreWriteJournal(cal);
  CHECK(RCTwoWaySQL(&j,&error,"INSERT INTO calendars(account_id,url,sync_id,display_name) VALUES(%lld,'https://fixture.invalid/calendar/','fixture','Fixture')",j.account));
  NSData *ics=[@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:fixture\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:Original\r\nURL;VALUE=URI:\r\nX-APPLE-PRIVATE:preserve\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *mapped=RCCalendarNativeGraph(cal,1,@"calendar-fixture",ics,&error); CHECK(mapped);
  NSString *id=[[mapped allKeys] objectAtIndex:0];
  NSDictionary *paths=[NSDictionary dictionaryWithObject:id forKey:@"event:"];
  r=[NSDictionary dictionaryWithObjectsAndKeys:ics,@"body",mapped,@"graph",paths,@"paths",id,@"root",@"resource-1",@"key",@"https://fixture.invalid/calendar/fixture.ics",@"href",nil];
  NSMutableDictionary *detachedCalendar=[NSMutableDictionary dictionaryWithDictionary:r];
  [detachedCalendar setObject:[NSNumber numberWithBool:YES] forKey:@"detachedReceipt"];
  [detachedCalendar setObject:@"native-not-yet-imported" forKey:@"key"];
  CHECK(RCCalendarProjectVerified(cal,detachedCalendar,ics,&error));
  truth=[NSMutableDictionary dictionaryWithDictionary:mapped];
  NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:id]];
  [event setObject:@"Edited" forKey:@"summary"]; [truth setObject:event forKey:id];
  desired=RCCalendarEncodeLocal(cal,r,truth,id,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  result=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([result rangeOfString:@"URL;VALUE=URI:\r\n"].location!=NSNotFound);
  CHECK([result rangeOfString:@"SUMMARY:Edited\r\n"].location!=NSNotFound);
  CHECK(RCCalendarEncodeLocal(cal,nil,truth,id,&error));
  [event setObject:@"future data" forKey:@"future calendar field"];
  NSDictionary *partial=RCTwoWayEncodeFields(RCCalendarEncodeLocal,cal,r,truth,id,&error); CHECK(partial);
  CHECK([[[partial objectForKey:@"pendingFields"] objectForKey:id] containsObject:@"future calendar field"]);
  CHECK(RCNativeScopeMatches(truth,[partial objectForKey:@"graph"],[partial objectForKey:@"fieldScopes"]));
  NSDictionary *partialReplay=RCTwoWayEncodeFields(RCCalendarEncodeLocal,cal,partial,truth,id,&error); CHECK(partialReplay);
  CHECK([[partialReplay objectForKey:@"body"] isEqual:[partial objectForKey:@"body"]]);
  [event setObject:[NSNumber numberWithBool:YES] forKey:@"all day"];
  [event setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[[event objectForKey:@"start date"] timeIntervalSinceReferenceDate]+3600] forKey:@"start date"];
  partial=RCTwoWayEncodeFields(RCCalendarEncodeLocal,cal,r,truth,id,&error); CHECK(partial);
  CHECK([[[[partial objectForKey:@"graph"] objectForKey:id] objectForKey:@"start date"] isEqual:[[mapped objectForKey:id] objectForKey:@"start date"]]);
  CHECK([[[[partial objectForKey:@"graph"] objectForKey:id] objectForKey:@"summary"] isEqual:@"Edited"]);
  CHECK([[[partial objectForKey:@"pendingFields"] objectForKey:id] containsObject:@"start date"]);
  CHECK([[[partial objectForKey:@"pendingFields"] objectForKey:id] containsObject:@"all day"]);
  [event setObject:[[mapped objectForKey:id] objectForKey:@"start date"] forKey:@"start date"];
  [event removeObjectForKey:@"future calendar field"];
  puts("PASS: Unknown calendar fields stay pending while text edits sync; dependent date/all-day changes remain together");
  [event removeObjectForKey:@"all day"]; [event removeObjectForKey:@"status"]; [event removeObjectForKey:@"classification"];
  [event setObject:@"synthetic-ical-uid" forKey:@"com.apple.ical.uid"];
  [event setObject:[NSNumber numberWithInt:2] forKey:@"com.apple.ical.sequence"];
  [event setObject:[NSNumber numberWithInt:2] forKey:@"invitationSequence"];
  [event setObject:[NSDate dateWithTimeIntervalSince1970:1234567] forKey:@"invitationTimestamp"];
  CHECK(RCCalendarEncodeLocal(cal,nil,truth,id,&error));
  [event setObject:@"unsupported" forKey:@"unknown-editable-property"];
  CHECK(!RCCalendarEncodeLocal(cal,nil,truth,id,&error));
  [event removeObjectForKey:@"unknown-editable-property"];
  [event setObject:[NSNumber numberWithBool:YES] forKey:@"all day"];
  CHECK(!RCCalendarEncodeLocal(cal,r,truth,id,&error));
  [event removeObjectForKey:@"all day"];
  [event setObject:[NSArray arrayWithObject:@"private-organizer-id"] forKey:@"organizer"];
  CHECK(!RCCalendarEncodeLocal(cal,nil,truth,id,&error) && !strstr(error.message,"private-organizer-id"));
  ExpandedCalendarTests(cal);
  CalendarOperationTests(cal);
  CalendarMapperRegressionTests(cal);
  RCCalendarStoreClose(cal);
  puts("PASS: Production contact/calendar reverse mappers preserve private fields and reject unsupported changes");
}
static NSDictionary *CalendarResource(RCCalendarStore *store, long long identifier, NSData *body, NSString *href, NSString *etag)
{
  NSDictionary *mapped=RCCalendarNativeGraph(store,identifier,@"calendar-fixture",body,&error); if(!mapped) fprintf(stderr,"Calendar resource %lld mapping failed: %s\n",identifier,error.message); CHECK(mapped);
  NSString *root=nil;
  NSMutableDictionary *paths=[NSMutableDictionary dictionary];
  icalcomponent *calendar=RCICalendarParse([body bytes],[body length],&error), *event; CHECK(calendar);
  CHECK(RCPrepareCalendarProjection(calendar,&error));
  for(event=icalcomponent_get_first_component(calendar,ICAL_VEVENT_COMPONENT);event;
      event=icalcomponent_get_next_component(calendar,ICAL_VEVENT_COMPONENT)) {
    char *key=RCICalendarRecurrenceKey(event);
    char *stable=RCCalendarStoreIdentity(store,[[NSString stringWithFormat:@"resource-%lld",identifier] UTF8String],
        [[NSString stringWithFormat:@"%s:%s",RCICalendarValue(event,ICAL_UID_PROPERTY),key] UTF8String],&error); CHECK(stable);
    NSString *id=[@"cal-" stringByAppendingString:[NSString stringWithUTF8String:stable]], *path=[@"event:" stringByAppendingString:[NSString stringWithUTF8String:key]];
    if(!*key) root=id; free(key); free(stable);
    NSDictionary *record=[mapped objectForKey:id]; if(!record) continue;
    [paths setObject:id forKey:path];
    NSArray *links=[NSArray arrayWithObjects:@"recurrences",@"display alarms",@"audio alarms",@"attendees",@"organizer",nil];
    NSEnumerator *it=[links objectEnumerator]; NSString *link;
    while((link=[it nextObject])) { NSArray *ids=[record objectForKey:link]; NSUInteger n;
      for(n=0;n<[ids count];n++) [paths setObject:[ids objectAtIndex:n] forKey:[NSString stringWithFormat:@"%@/%@:%lu",path,link,(unsigned long)n]];
    }
  }
  icalcomponent_free(calendar); CHECK(root);
  return [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"resource-%lld",identifier],@"key",root,@"root",href,@"href",etag,@"etag",body,@"body",
      mapped,@"graph",paths,@"paths",[NSNumber numberWithInt:1],@"revision",nil];
}
static void CalendarOperationTests(RCCalendarStore *store)
{
  remoteBodies=[NSMutableDictionary dictionary]; remoteETags=[NSMutableDictionary dictionary];
  RCWriteJournal j=RCCalendarStoreWriteJournal(store); CHECK(RCTwoWayInitialize(&j,&error));
  NSMutableDictionary *truth=[NSMutableDictionary dictionary], *graph=[NSMutableDictionary dictionary];
  NSMutableSet *busy=[NSMutableSet set];
  [truth setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Calendar",ISyncRecordEntityNameKey,@"Existing local",@"title",nil] forKey:@"existing-calendar"];
  CHECK(RCCalendarCollectOperations(&j,truth,graph,[NSArray array],busy,&error));
  CHECK(Scalar(&j,"SELECT count(*) FROM calendar_actions")==0);
  [truth setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Calendar",ISyncRecordEntityNameKey,@"New & Local",@"title",nil] forKey:@"new-calendar"];
  CHECK(RCCalendarCollectOperations(&j,truth,graph,[NSArray array],busy,&error));
  CHECK(Scalar(&j,"SELECT count(*) FROM calendar_actions WHERE kind='create'")==1);
  int before=mutations; loseResponse=YES;
  CHECK(RCCalendarRunOperations(&j,(RCHTTPClient *)1,&error)); CHECK(mutations==before+1);
  CHECK(RCCalendarRunOperations(&j,(RCHTTPClient *)1,&error)); CHECK(mutations==before+1);
  CHECK(Scalar(&j,"SELECT count(*) FROM calendar_actions WHERE state='done'")==1);
  CHECK(Scalar(&j,"SELECT count(*) FROM two_way_aliases WHERE native_id='new-calendar'")==1);
  NSData *body=[@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:move-fixture\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:Move\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *r=CalendarResource(store,71,body,@"https://fixture.invalid/calendar/move%20fixture.ics",@"\"move-base\"");
  NSString *root=[r objectForKey:@"root"];
  [truth addEntriesFromDictionary:[r objectForKey:@"graph"]];
  NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]];
  [event setObject:[NSArray arrayWithObject:@"new-calendar"] forKey:@"calendar"]; [truth setObject:event forKey:root];
  CHECK(RCTwoWaySQL(&j,&error,"INSERT INTO calendar_resources(id,calendar_id,href,raw_ical,etag) VALUES(71,(SELECT id FROM calendars WHERE sync_id='fixture'),'https://fixture.invalid/calendar/move%%20fixture.ics',X'00','\"move-base\"')"));
  [remoteBodies setObject:body forKey:[r objectForKey:@"href"]]; [remoteETags setObject:@"\"move-base\"" forKey:[r objectForKey:@"href"]];
  CHECK(RCCalendarCollectOperations(&j,truth,graph,[NSArray arrayWithObject:r],busy,&error)); CHECK([busy containsObject:root]);
  loseResponse=YES; before=mutations;
  CHECK(RCCalendarRunOperations(&j,(RCHTTPClient *)1,&error)); CHECK(mutations==before+1);
  CHECK(RCCalendarRunOperations(&j,(RCHTTPClient *)1,&error)); CHECK(mutations==before+1);
  CHECK(![remoteBodies objectForKey:[r objectForKey:@"href"]]);
  CHECK(Scalar(&j,"SELECT count(*) FROM calendar_actions WHERE kind='move'")==0);
  CHECK(Scalar(&j,"SELECT count(*) FROM calendar_resources WHERE id=71 AND href='https://fixture.invalid/calendar/move%20fixture.ics'")==0);
  [remoteBodies setObject:body forKey:[r objectForKey:@"href"]]; [remoteETags setObject:@"\"move-base\"" forKey:[r objectForKey:@"href"]];
  [busy removeAllObjects];
  CHECK(RCCalendarCollectOperations(&j,truth,graph,[NSArray arrayWithObject:r],busy,&error));
  before=mutations; CHECK(!RCCalendarRunOperations(&j,(RCHTTPClient *)1,&error)); CHECK(mutations==before);
  CHECK([remoteBodies objectForKey:[r objectForKey:@"href"]]);
  CHECK(Scalar(&j,"SELECT count(*) FROM calendar_actions WHERE kind='move' AND state='conflict'")==1);
  [busy removeAllObjects]; CHECK(RCCalendarProtectOperations(&j,[NSArray arrayWithObject:r],graph,busy,&error)); CHECK([busy containsObject:root]);
  [event setObject:[NSArray arrayWithObject:@"calendar-fixture"] forKey:@"calendar"];
  CHECK(RCCalendarCollectOperations(&j,truth,graph,[NSArray arrayWithObject:r],busy,&error));
  CHECK(Scalar(&j,"SELECT count(*) FROM calendar_actions WHERE kind='move'")==0);
  CHECK(Scalar(&j,"SELECT count(*) FROM two_way_attention WHERE reason='calendar-move-conflict'")==0);
  puts("PASS: Calendar creation/MOVE recover lost responses without duplicates, refuse occupied destinations, and protect pending native edits; pre-existing calendars stay local");
}

static void ExpandedCalendarTests(RCCalendarStore *store)
{
  NSData *body=[@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:expanded-calendar\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:Expanded\r\nX-PRIVATE:keep\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT10M\r\nDESCRIPTION:Reminder\r\nX-ALARM:keep\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *r=CalendarResource(store,70,body,@"https://fixture.invalid/calendar/expanded.ics",@"\"base\"");
  NSString *root=[r objectForKey:@"root"];
  NSMutableDictionary *truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[r objectForKey:@"graph"]]];
  NSMutableDictionary *event=[truth objectForKey:root];
  NSString *alarm=[[event objectForKey:@"display alarms"] objectAtIndex:0];
  [[truth objectForKey:alarm] setObject:[NSNumber numberWithInt:-1800] forKey:@"triggerduration"];
  [event setObject:[NSArray arrayWithObject:@"rule"] forKey:@"recurrences"];
  [truth setObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Recurrence",ISyncRecordEntityNameKey,[NSArray arrayWithObject:root],@"owner",@"weekly",@"frequency",[NSNumber numberWithInt:2],@"interval",[NSNumber numberWithInt:5],@"count",@"monday",@"weekstartday",nil] forKey:@"rule"];
  [event setObject:[NSArray arrayWithObject:@"attendee"] forKey:@"attendees"];
  [truth setObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Attendee",ISyncRecordEntityNameKey,[NSArray arrayWithObject:root],@"owner",@"guest@example.invalid",@"email",@"Guest, Test",@"common name",@"requiredparticipant",@"role",@"accepted",@"status",@"individual",@"user type",[NSNumber numberWithBool:YES],@"rsvp",nil] forKey:@"attendee"];
  [event setObject:[NSArray arrayWithObject:@"organizer"] forKey:@"organizer"];
  [truth setObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Organizer",ISyncRecordEntityNameKey,[NSArray arrayWithObject:root],@"owner",@"host@example.invalid",@"email",nil] forKey:@"organizer"];
  NSDictionary *strict=RCCalendarEncodeLocal(store,r,truth,root,&error); if(!strict) fprintf(stderr,"Expanded strict: %s\n",error.message); CHECK(strict);
  NSDictionary *desired=RCTwoWayEncodeFields(RCCalendarEncodeLocal,store,r,truth,root,&error); CHECK(desired);
  if([[desired objectForKey:@"pendingFields"] count]) NSLog(@"Expanded calendar pending: %@",[desired objectForKey:@"pendingFields"]);
  CHECK(![[desired objectForKey:@"pendingFields"] count]);
  NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"X-PRIVATE:keep"].location!=NSNotFound && [wire rangeOfString:@"X-ALARM:keep"].location!=NSNotFound);
  CHECK(RCCalendarEncodeLocal(store,nil,truth,root,&error));
  NSMutableDictionary *defaults=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:truth]];
  [[defaults objectForKey:@"rule"] removeObjectForKey:@"interval"]; [[defaults objectForKey:@"rule"] removeObjectForKey:@"weekstartday"];
  [[defaults objectForKey:@"rule"] setObject:[NSNumber numberWithInt:0] forKey:@"count"];
  CHECK(RCCalendarEncodeLocal(store,nil,defaults,root,&error));
  NSDictionary *replay=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(replay);
  CHECK([[replay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  desired=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:desired]];
  [[truth objectForKey:@"rule"] setObject:[NSNumber numberWithInt:3] forKey:@"interval"];
  [[truth objectForKey:@"attendee"] setObject:@"declined" forKey:@"status"];
  [event setObject:[NSArray array] forKey:@"display alarms"]; [truth removeObjectForKey:alarm];
  NSDictionary *updated=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(updated);
  updated=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:updated]];
  [event setObject:[NSArray array] forKey:@"recurrences"]; [truth removeObjectForKey:@"rule"];
  [event setObject:[NSNumber numberWithBool:YES] forKey:@"all day"];
  [event setObject:[NSCalendarDate dateWithYear:2026 month:9 day:7 hour:12 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]] forKey:@"start date"];
  [event setObject:[NSCalendarDate dateWithYear:2026 month:9 day:8 hour:12 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]] forKey:@"end date"];
  desired=RCCalendarEncodeLocal(store,updated,truth,root,&error); CHECK(desired);
  desired=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:desired]];
  [event setObject:[NSNumber numberWithBool:NO] forKey:@"all day"];
  CHECK(RCCalendarEncodeLocal(store,desired,truth,root,&error));
  puts("PASS: Reminder timing/removal, recurring creation/rule edits, attendees/RSVP, organizer and all-day conversion round-trip with extensions intact");
}

static void CalendarEmptyMapperTests(RCCalendarStore *store)
{
  NSString *event=@"BEGIN:VEVENT\r\nUID:empty-calendar\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:Empty fixture\r\nURL;VALUE=URI:\r\nBEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT15M\r\nATTACH;VALUE=URI:Basso\r\nX-PRIVATE:keep\r\nEND:VALARM\r\nEND:VEVENT\r\n";
  NSData *body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@END:VCALENDAR\r\n",event] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *resource=CalendarResource(store,40,body,@"https://fixture.invalid/calendar/empty.ics",@"\"base\"");
  NSString *root=[resource objectForKey:@"root"];
  NSMutableDictionary *truth=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
  NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]];
  [truth setObject:record forKey:root];
  [record removeObjectForKey:@"all day"]; [record setObject:@"" forKey:@"status"]; [record setObject:@"" forKey:@"classification"];
  [record setObject:@"" forKey:@"url"]; [record setObject:@"" forKey:@"description"];
  NSDictionary *desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  [record setObject:@"private" forKey:@"classification"]; [record setObject:@"tentative" forKey:@"status"];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  desired=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:desired]];
  [record setObject:@"" forKey:@"classification"]; [record setObject:@"" forKey:@"status"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  [record removeObjectForKey:@"summary"];
  CHECK(RCCalendarEncodeLocal(store,resource,truth,root,&error));
  CHECK(RCCalendarEncodeLocal(store,nil,truth,root,&error));
  [record setObject:@"Empty fixture" forKey:@"summary"];
  [record setObject:@"A description" forKey:@"description"]; [record setObject:@"A location" forKey:@"location"];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  desired=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:desired]];
  [record setObject:@"" forKey:@"description"]; [record setObject:@"" forKey:@"location"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  NSString *alarmID=[[record objectForKey:@"audio alarms"] objectAtIndex:0];
  NSMutableDictionary *alarm=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:alarmID]];
  [truth setObject:alarm forKey:alarmID];
  [alarm setObject:@"" forKey:@"description"]; [alarm setObject:@"" forKey:@"triggerdate"];
  NSArray *emptySounds=[NSArray arrayWithObjects:@"",[NSURL URLWithString:@""],[NSNull null],nil];
  NSEnumerator *it=[emptySounds objectEnumerator]; id sound;
  while((sound=[it nextObject])) {
    if(sound==[NSNull null]) [alarm removeObjectForKey:@"com.apple.ical.sound"];
    else [alarm setObject:sound forKey:@"com.apple.ical.sound"];
    desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
    NSString *expected=Replace([[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease],@"ATTACH;VALUE=URI:Basso\r\n",@"");
    CHECK([[desired objectForKey:@"body"] isEqual:[expected dataUsingEncoding:NSUTF8StringEncoding]]);
    CHECK(RCCalendarEncodeLocal(store,nil,truth,root,&error));
    NSDictionary *replay=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(replay);
    CHECK([[replay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
    /* The imported graph also has to compare equal after ATTACH disappears. */
    NSDictionary *imported=CalendarResource(store,40,[desired objectForKey:@"body"],@"https://fixture.invalid/calendar/empty.ics",@"\"next\"");
    CHECK(RCTwoWayGraphsEqual([imported objectForKey:@"graph"],truth));
    CHECK(RCCalendarEncodeLocal(store,imported,truth,root,&error));
  }
  [alarm setObject:@"Glass" forKey:@"sound"];
  desired=RCCalendarEncodeLocal(store,nil,truth,root,&error); CHECK(desired);
  NSDictionary *namedReplay=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(namedReplay);
  CHECK([[namedReplay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  desired=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:desired]];
  [alarm setObject:@"" forKey:@"sound"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(desired);
  CHECK([[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease] rangeOfString:@"ATTACH"].location==NSNotFound);
  [alarm removeObjectForKey:@"sound"];
  [alarm setObject:@"Basso" forKey:@"com.apple.ical.sound"];
  CHECK(!RCCalendarEncodeLocal(store,resource,truth,root,&error)); /* Nonempty wrong types remain invalid. */
  [alarm setObject:[NSURL URLWithString:@"Basso"] forKey:@"com.apple.ical.sound"];
  CHECK(RCCalendarEncodeLocal(store,resource,truth,root,&error));
  [alarm removeObjectForKey:@"triggerduration"];
  CHECK(!RCCalendarEncodeLocal(store,nil,truth,root,&error));
  puts("PASS: Empty strings, URLs and absent alarm sounds omit ATTACH, retain AUDIO and survive import/replay; required triggers stay required");

  NSString *people=Replace(event,@"BEGIN:VALARM",@"ATTENDEE:mailto:fixture@example.invalid\r\nBEGIN:VALARM");
  body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@END:VCALENDAR\r\n",people] dataUsingEncoding:NSUTF8StringEncoding];
  resource=CalendarResource(store,41,body,@"https://fixture.invalid/calendar/rsvp.ics",@"\"base\""); root=[resource objectForKey:@"root"];
  truth=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
  record=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]]; [truth setObject:record forKey:root];
  NSString *personID=[[record objectForKey:@"attendees"] objectAtIndex:0];
  NSMutableDictionary *person=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:personID]]; [truth setObject:person forKey:personID];
  [person removeObjectForKey:@"rsvp"]; [person removeObjectForKey:@"role"];
  [person setObject:@"" forKey:@"status"]; [person setObject:@"" forKey:@"user type"]; [person setObject:@"" forKey:@"common name"];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  [record setObject:@"Edited with omitted RSVP" forKey:@"summary"];
  CHECK(RCCalendarEncodeLocal(store,resource,truth,root,&error));
  [person setObject:[NSNumber numberWithBool:YES] forKey:@"rsvp"];
  CHECK(RCCalendarEncodeLocal(store,resource,truth,root,&error));
  [person removeObjectForKey:@"rsvp"]; [person setObject:@"accepted" forKey:@"status"];
  CHECK(RCCalendarEncodeLocal(store,resource,truth,root,&error));
  [person setObject:@"" forKey:@"status"]; [truth removeObjectForKey:personID];
  CHECK(!RCCalendarEncodeLocal(store,resource,truth,root,&error));
  NSDictionary *partial=RCTwoWayEncodeFields(RCCalendarEncodeLocal,store,resource,truth,root,&error); CHECK(partial);
  CHECK([[[partial objectForKey:@"pendingFields"] objectForKey:personID] containsObject:@"record deletion"]);
  CHECK([[partial objectForKey:@"graph"] objectForKey:personID]);
  CHECK(RCNativeScopeMatches(truth,[partial objectForKey:@"graph"],[partial objectForKey:@"fieldScopes"]));
  puts("PASS: Omitted attendee defaults permit unrelated edits while RSVP and participation edits round-trip; incomplete child deletions remain protected");
}

#include "CalendarTimeTests.h"
static void CalendarMapperRegressionTests(RCCalendarStore *store)
{
  CalendarTimeMapperTests(store);
  CalendarEmptyMapperTests(store);
  NSString *event=@"BEGIN:VEVENT\r\nUID:ordering\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:Original café\r\nX-PRIVATE;P=keep:folded\r\n value\r\nEND:VEVENT\r\n";
  NSString *zone=@"BEGIN:VTIMEZONE\r\nTZID:Etc/UTC\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0000\r\nTZOFFSETTO:+0000\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n";
  NSString *zone2=Replace(zone,@"Etc/UTC",@"Fixture/UTC");
  NSArray *orders=[NSArray arrayWithObjects:[NSString stringWithFormat:@"%@%@%@",zone,zone2,event],
      [NSString stringWithFormat:@"%@%@%@",event,zone,zone2],[NSString stringWithFormat:@"%@%@%@",zone,event,zone2],nil];
  NSEnumerator *it=[orders objectEnumerator]; NSString *order;
  while((order=[it nextObject])) {
    NSData *body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@END:VCALENDAR\r\n",order] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *resource=CalendarResource(store,20,body,@"https://fixture.invalid/calendar/order.ics",@"\"base\"");
    NSString *root=[resource objectForKey:@"root"];
    NSMutableDictionary *truth=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
    NSMutableDictionary *edited=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]];
    [edited setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[[edited objectForKey:@"start date"] timeIntervalSinceReferenceDate]+3600] forKey:@"start date"];
    [edited setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[[edited objectForKey:@"end date"] timeIntervalSinceReferenceDate]+3600] forKey:@"end date"];
    [truth setObject:edited forKey:root];
    NSDictionary *desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
    NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
    NSString *expected=Replace(Replace([[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease],@"DTSTART:20260907T100000Z",@"DTSTART:20260907T110000Z"),@"DTEND:20260907T110000Z",@"DTEND:20260907T120000Z");
    CHECK([wire isEqual:expected]);
  }
  NSString *seriesWithAlarm=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:owned-alarm\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Master\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:owned-alarm\r\nRECURRENCE-ID:20260908T100000Z\r\nDTSTART:20260908T120000Z\r\nDTEND:20260908T130000Z\r\nSUMMARY:Exception\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nTRIGGER:-PT5M\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
  NSDictionary *owned=CalendarResource(store,81,[seriesWithAlarm dataUsingEncoding:NSUTF8StringEncoding],@"https://fixture.invalid/calendar/owned.ics",@"\"base\"");
  NSString *ownedRoot=[owned objectForKey:@"root"];
  NSMutableDictionary *ownedTruth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[owned objectForKey:@"graph"]]];
  NSMutableDictionary *ownedMaster=[ownedTruth objectForKey:ownedRoot];
  NSString *removed=[[[[ownedMaster objectForKey:@"detached events"] objectAtIndex:0] copy] autorelease];
  NSArray *ownedAlarms=[[ownedTruth objectForKey:removed] objectForKey:@"display alarms"];
  NSString *removedAlarm=[[[ownedAlarms objectAtIndex:0] copy] autorelease];
  [ownedTruth removeObjectsForKeys:ownedAlarms]; [ownedTruth removeObjectForKey:removed];
  [ownedMaster setObject:[NSArray array] forKey:@"detached events"];
  NSDictionary *removedResult=RCTwoWayEncodeFields(RCCalendarEncodeLocal,store,owned,ownedTruth,ownedRoot,&error); CHECK(removedResult);
  CHECK(![[removedResult objectForKey:@"graph"] objectForKey:removedAlarm]);
  CHECK(![[removedResult objectForKey:@"graph"] objectForKey:removed]);
  CHECK(![[removedResult objectForKey:@"pendingFields"] count]);
  NSString *durationWire=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:duration-fields\r\nDTSTART:20260907T100000Z\r\nDURATION:PT1H\r\nSUMMARY:Original\r\nX-FUTURE:keep\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
  NSDictionary *duration=CalendarResource(store,82,[durationWire dataUsingEncoding:NSUTF8StringEncoding],@"https://fixture.invalid/calendar/duration.ics",@"\"base\"");
  NSString *durationRoot=[duration objectForKey:@"root"];
  NSMutableDictionary *durationTruth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[duration objectForKey:@"graph"]]];
  NSMutableDictionary *durationEvent=[durationTruth objectForKey:durationRoot];
  [durationEvent setObject:@"Supported title" forKey:@"summary"];
  [durationEvent setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[[durationEvent objectForKey:@"start date"] timeIntervalSinceReferenceDate]+3600] forKey:@"start date"];
  NSDictionary *durationResult=RCTwoWayEncodeFields(RCCalendarEncodeLocal,store,duration,durationTruth,durationRoot,&error); CHECK(durationResult);
  NSString *durationEncoded=[[[NSString alloc] initWithData:[durationResult objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([durationEncoded rangeOfString:@"DTSTART:20260907T100000Z\r\nDURATION:PT1H\r\nSUMMARY:Supported title\r\nX-FUTURE:keep\r\n"].location!=NSNotFound);
  CHECK([[[durationResult objectForKey:@"pendingFields"] objectForKey:durationRoot] containsObject:@"start date"]);
  CHECK(RCNativeScopeMatches(durationTruth,[durationResult objectForKey:@"graph"],[durationResult objectForKey:@"fieldScopes"]));
  CHECK(![[[durationResult objectForKey:@"fieldScopes"] objectForKey:durationRoot] containsObject:@"start date"]);
  puts("PASS: DURATION-based date edits stay pending while independent event text is patched and verified");
  puts("PASS: Supported detached-event deletion removes owned alarms; unsupported standalone child deletions remain pending");
  puts("PASS: Timezones before, after and around events preserve source targeting, folded private bytes and Unicode");
  NSString *recurring=Replace(event,@"SUMMARY:Original café",@"RRULE:FREQ=DAILY;COUNT=10\r\nSUMMARY:Original café");
  NSData *body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@%@END:VCALENDAR\r\n",recurring,zone] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *resource=CalendarResource(store,21,body,@"https://fixture.invalid/calendar/series.ics",@"\"base\"");
  NSString *root=[resource objectForKey:@"root"];
  NSMutableDictionary *truth=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
  NSMutableDictionary *master=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]];
  NSMutableDictionary *detached=[NSMutableDictionary dictionaryWithDictionary:master];
  NSDate *original=[NSDate dateWithTimeIntervalSinceReferenceDate:[[master objectForKey:@"start date"] timeIntervalSinceReferenceDate]+86400];
  [detached setObject:[NSArray array] forKey:@"recurrences"];
  [detached setObject:[NSArray arrayWithObject:root] forKey:@"main event"];
  [detached setObject:original forKey:@"original date"];
  [detached setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[original timeIntervalSinceReferenceDate]+3600] forKey:@"start date"];
  [detached setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[original timeIntervalSinceReferenceDate]+7200] forKey:@"end date"];
  [detached setObject:@"Moved occurrence" forKey:@"summary"];
  [master setObject:[NSArray arrayWithObject:@"new-exception"] forKey:@"detached events"];
  [truth setObject:master forKey:root]; [truth setObject:detached forKey:@"new-exception"];
  NSDictionary *desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  CHECK([[[desired objectForKey:@"paths"] objectForKey:@"event:DATE-TIME::20260908T100000Z"] isEqual:@"new-exception"]);
  NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"RECURRENCE-ID:20260908T100000Z"].location!=NSNotFound);
  CHECK([wire rangeOfString:recurring].location!=NSNotFound); CHECK([wire rangeOfString:zone].location!=NSNotFound);
  CHECK(!RCCalendarEncodeLocal(store,nil,truth,@"new-exception",&error));
  NSMutableDictionary *bad=[NSMutableDictionary dictionaryWithDictionary:detached];
  [bad setObject:[NSArray arrayWithObject:@"wrong-parent"] forKey:@"main event"]; [truth setObject:bad forKey:@"new-exception"];
  CHECK(!RCCalendarEncodeLocal(store,resource,truth,root,&error));
  [truth setObject:detached forKey:@"new-exception"];
  truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:truth]];
  detached=[truth objectForKey:@"new-exception"]; master=[truth objectForKey:root];
  [detached setObject:@"Second edit" forKey:@"summary"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:truth]]; master=[truth objectForKey:root];
  [truth removeObjectForKey:@"new-exception"]; [master setObject:[NSArray array] forKey:@"detached events"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:truth]]; master=[truth objectForKey:root];
  [master setObject:[NSArray arrayWithObject:original] forKey:@"exception dates"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"EXDATE:20260908T100000Z"].location!=NSNotFound);
  puts("PASS: Detached additions, edits, removals and exception dates round-trip within the parent resource; wrong parents rejected");
  NSString *allDay=Replace(Replace(recurring,@"DTSTART:20260907T100000Z",@"DTSTART;VALUE=DATE:20260907"),@"DTEND:20260907T110000Z",@"DTEND;VALUE=DATE:20260908");
  NSData *allDayBody=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@END:VCALENDAR\r\n",allDay] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *allDayResource=CalendarResource(store,23,allDayBody,@"https://fixture.invalid/calendar/all-day.ics",@"\"base\"");
  NSString *allDayRoot=[allDayResource objectForKey:@"root"];
  NSMutableDictionary *allDayTruth=[NSMutableDictionary dictionaryWithDictionary:[allDayResource objectForKey:@"graph"]];
  NSMutableDictionary *allDayMaster=[NSMutableDictionary dictionaryWithDictionary:[allDayTruth objectForKey:allDayRoot]], *allDayException=[NSMutableDictionary dictionaryWithDictionary:allDayMaster];
  NSDate *allDayOriginal=[NSDate dateWithTimeIntervalSinceReferenceDate:[[allDayMaster objectForKey:@"start date"] timeIntervalSinceReferenceDate]+86400];
  [allDayException setObject:allDayOriginal forKey:@"original date"]; [allDayException setObject:allDayOriginal forKey:@"start date"];
  [allDayException setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[allDayOriginal timeIntervalSinceReferenceDate]+86400] forKey:@"end date"];
  [allDayException setObject:[NSArray array] forKey:@"recurrences"]; [allDayException setObject:[NSArray arrayWithObject:allDayRoot] forKey:@"main event"];
  [allDayMaster setObject:[NSArray arrayWithObject:@"all-day-exception"] forKey:@"detached events"];
  [allDayTruth setObject:allDayMaster forKey:allDayRoot]; [allDayTruth setObject:allDayException forKey:@"all-day-exception"];
  CHECK(RCCalendarEncodeLocal(store,allDayResource,allDayTruth,allDayRoot,&error));
  [allDayMaster setObject:[NSArray arrayWithObjects:@"all-day-exception",@"duplicate-exception",nil] forKey:@"detached events"];
  [allDayTruth setObject:allDayException forKey:@"duplicate-exception"];
  CHECK(!RCCalendarEncodeLocal(store,allDayResource,allDayTruth,allDayRoot,&error));
  puts("PASS: All-day exception dates retain VALUE=DATE; duplicate recurrence identities are rejected");
  NSString *audio=Replace(event,@"END:VEVENT",@"BEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT15M\r\nATTACH;VALUE=URI:file:///System/Library/Sounds/Basso.aiff\r\nEND:VALARM\r\nEND:VEVENT");
  body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@%@END:VCALENDAR\r\n",audio,zone] dataUsingEncoding:NSUTF8StringEncoding];
  resource=CalendarResource(store,22,body,@"https://fixture.invalid/calendar/audio.ics",@"\"base\""); root=[resource objectForKey:@"root"];
  truth=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
  master=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]];
  [master setObject:@"local-invitation-token" forKey:@"invitationId"]; [truth setObject:master forKey:root];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired); CHECK([[desired objectForKey:@"body"] isEqual:body]);
  NSString *alarmID=[[master objectForKey:@"audio alarms"] objectAtIndex:0];
  NSMutableDictionary *alarm=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:alarmID]];
  [truth setObject:alarm forKey:alarmID];
  [alarm setObject:@"Basso" forKey:@"sound"];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  [alarm removeObjectForKey:@"com.apple.ical.sound"];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  [alarm setObject:@"Glass" forKey:@"sound"];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"ATTACH;VALUE=URI:file:///System/Library/Sounds/Glass.aiff"].location!=NSNotFound);
  [alarm setObject:[NSURL URLWithString:@"file:///System/Library/Sounds/Basso.aiff"] forKey:@"com.apple.ical.sound"];
  CHECK(!RCCalendarEncodeLocal(store,resource,truth,root,&error));
  [alarm removeObjectForKey:@"com.apple.ical.sound"];
  [alarm setObject:@"../invalid" forKey:@"sound"];
  CHECK(!RCCalendarEncodeLocal(store,resource,truth,root,&error));
  [alarm removeObjectForKey:@"sound"];
  [alarm setObject:[NSURL URLWithString:@"file:///System/Library/Sounds/Glass.aiff"] forKey:@"com.apple.ical.sound"]; [truth setObject:alarm forKey:alarmID];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"ATTACH;VALUE=URI:file:///System/Library/Sounds/Glass.aiff"].location!=NSNotFound);
  CHECK([wire rangeOfString:@"ATTACH;VALUE=URI:file:///System/Library/Sounds/Basso.aiff"].location==NSNotFound);
  truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:truth]]; alarm=[truth objectForKey:alarmID];
  [alarm setObject:[NSURL URLWithString:@"file:///tmp/Custom%20chime.aiff"] forKey:@"com.apple.ical.sound"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:truth]]; alarm=[truth objectForKey:alarmID];
  [alarm setObject:@"must not disappear" forKey:@"unsupported-sound-field"];
  CHECK(!RCCalendarEncodeLocal(store,desired,truth,root,&error));
  [alarm removeObjectForKey:@"unsupported-sound-field"]; [alarm removeObjectForKey:@"com.apple.ical.sound"];
  desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); if(!desired) fprintf(stderr,"Mapper: %s\n",error.message); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:[Replace([[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease],@"ATTACH;VALUE=URI:file:///System/Library/Sounds/Basso.aiff\r\n",@"") dataUsingEncoding:NSUTF8StringEncoding]]);
  puts("PASS: Invitation metadata does not generate edits; Tiger sound URLs and Leopard sound names round-trip through URI attachments");

  /* Exact Leopard production representation, with synthetic event data. */
  NSString *relative=Replace(audio,@"file:///System/Library/Sounds/Basso.aiff",@"Basso");
  body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@%@END:VCALENDAR\r\n",relative,zone] dataUsingEncoding:NSUTF8StringEncoding];
  resource=CalendarResource(store,23,body,@"https://fixture.invalid/calendar/relative-audio.ics",@"\"base\""); root=[resource objectForKey:@"root"];
  truth=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:[resource objectForKey:@"graph"]]];
  master=[truth objectForKey:root]; alarmID=[[master objectForKey:@"audio alarms"] objectAtIndex:0]; alarm=[truth objectForKey:alarmID];
  CHECK([[alarm objectForKey:@"com.apple.ical.sound"] isEqual:[NSURL URLWithString:@"Basso"]]);
  [alarm setObject:@"Basso" forKey:@"sound"];
  CHECK(RCTwoWayGraphsEqual([resource objectForKey:@"graph"],truth));
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  CHECK([[desired objectForKey:@"body"] isEqual:body]);
  [master setObject:@"Synthetic edited title" forKey:@"summary"];
  desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"SUMMARY:Synthetic edited title"].location!=NSNotFound);
  CHECK([wire rangeOfString:@"ATTACH;VALUE=URI:Basso\r\n"].location!=NSNotFound);
  NSDictionary *relativeImported=CalendarResource(store,23,[desired objectForKey:@"body"],@"https://fixture.invalid/calendar/relative-audio.ics",@"\"next\"");
  CHECK(RCTwoWayGraphsEqual([relativeImported objectForKey:@"graph"],truth));
  NSDictionary *relativeReplay=RCCalendarEncodeLocal(store,relativeImported,truth,root,&error); CHECK(relativeReplay);
  CHECK([[relativeReplay objectForKey:@"body"] isEqual:[desired objectForKey:@"body"]]);
  [alarm setObject:@"Glass" forKey:@"sound"];
  CHECK(!RCCalendarEncodeLocal(store,relativeImported,truth,root,&error));
  [alarm setObject:[NSURL URLWithString:@"Glass"] forKey:@"com.apple.ical.sound"];
  desired=RCCalendarEncodeLocal(store,relativeImported,truth,root,&error); CHECK(desired);
  wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"ATTACH;VALUE=URI:Glass\r\n"].location!=NSNotFound);
  puts("PASS: Leopard matching relative sound URL/name pairs preserve ATTACH bytes, permit event edits and acknowledge/replay without duplicate edits; conflicting names remain rejected");
}

static NSDictionary *CalendarGraph(NSArray *resources)
{
  NSMutableDictionary *graph=[NSMutableDictionary dictionary]; NSMutableArray *events=[NSMutableArray array];
  NSEnumerator *it=[resources objectEnumerator]; NSDictionary *resource;
  while ((resource=[it nextObject])) {
    NSDictionary *mapped=[resource objectForKey:@"graph"]; [graph addEntriesFromDictionary:mapped];
    NSEnumerator *ids=[mapped keyEnumerator]; NSString *id;
    while((id=[ids nextObject])) if([[[mapped objectForKey:id] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Event"]) [events addObject:id];
  }
  [graph setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Calendar",ISyncRecordEntityNameKey,marker,@"title",
      [NSNumber numberWithBool:NO],@"read only",events,@"events",[NSArray array],@"tasks",nil] forKey:@"calendar-fixture"];
  return graph;
}
/* Accept only marked fixture records and their owned children, retaining the
   identifiers assigned by Sync Services rather than aliasing every event alike. */
static void CalendarFixtureSession(ISyncClient *client,NSDictionary *push,NSArray *deletes)
{
  ISyncSession *s=[ISyncSession beginSessionWithClient:client entityNames:[client enabledEntityNames] beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]; CHECK(s);
  @try {
    NSEnumerator *it=[push keyEnumerator]; NSString *key;
    while((key=[it nextObject])) [s pushChangesFromRecord:[push objectForKey:key] withIdentifier:key];
    it=[deletes objectEnumerator]; while((key=[it nextObject])) [s deleteRecordWithIdentifier:key];
    CHECK([s prepareToPullChangesForEntityNames:RCSyncPullableEntities(client) beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]]);
    NSMutableDictionary *graph=[NSMutableDictionary dictionary];
    it=[[client enabledEntityNames] objectEnumerator];
    while((key=[it nextObject])) [graph addEntriesFromDictionary:[[s snapshotOfRecordsInTruth] recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:key forKey:ISyncRecordEntityNameKey]]];
    NSMutableSet *owned=[NSMutableSet set]; it=[graph keyEnumerator];
    while((key=[it nextObject])) if([[[graph objectForKey:key] objectForKey:@"summary"] hasPrefix:marker] || [[[graph objectForKey:key] objectForKey:@"title"] hasPrefix:marker]) [owned addObject:key];
    it=[graph keyEnumerator];
    while((key=[it nextObject])) {
      NSEnumerator *parents=[[[graph objectForKey:key] objectForKey:@"owner"] objectEnumerator]; NSString *parent;
      while((parent=[parents nextObject])) if([owned containsObject:parent]) [owned addObject:key];
    }
    it=[s changeEnumeratorForEntityNames:RCSyncPullableEntities(client)]; ISyncChange *change;
    while((change=[it nextObject])) if([owned containsObject:[change recordIdentifier]] || [deletes containsObject:[change recordIdentifier]])
      [s clientAcceptedChangesForRecordWithIdentifier:[change recordIdentifier] formattedRecord:nil newRecordIdentifier:nil];
    [s clientCommittedAcceptedChanges]; [s cancelSyncing];
  } @finally { if(![s isCancelled]) [s cancelSyncing]; }
}
static NSDictionary *CalendarFixtureEvents(ISyncClient *client)
{
  return [[[ISyncManager sharedManager] snapshotOfRecordsInTruthWithEntityNames:[client enabledEntityNames] usingIdentifiersForClient:client]
      recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:@"com.apple.calendars.Event" forKey:ISyncRecordEntityNameKey]];
}
static NSString *EventWithTitle(NSDictionary *events,NSString *title)
{
  NSEnumerator *it=[events keyEnumerator]; NSString *key;
  while((key=[it nextObject])) if([[[events objectForKey:key] objectForKey:@"summary"] isEqual:title]) return key;
  return nil;
}
static NSString *MainEventWithTitle(NSDictionary *events,NSString *title)
{
  NSEnumerator *it=[events keyEnumerator]; NSString *key;
  while((key=[it nextObject])) if([[[events objectForKey:key] objectForKey:@"summary"] isEqual:title] &&
      ![[[events objectForKey:key] objectForKey:@"main event"] count]) return key;
  return nil;
}
static void CalendarTimeIntegration(RCTwoWayContext *c,ISyncClient *local,RCCalendarStore *store)
{
  int index;
  for(index=0;index<2;index++) {
    NSString *title=[marker stringByAppendingFormat:@"-time-%d",index],
        *href=[NSString stringWithFormat:@"https://fixture.invalid/calendar/time-%d.ics",index];
    NSString *text=TimeFixture(index ? ChangedZone() : @"",index ? @";TZID=Europe/London" : @"",@"RRULE:FREQ=WEEKLY;COUNT=40\r\n");
    text=Replace(text,@"Time fixture",title);
    NSData *body=[text dataUsingEncoding:NSUTF8StringEncoding];
    [remoteBodies setObject:body forKey:href]; [remoteETags setObject:@"\"time-base\"" forKey:href];
    NSDictionary *resource=CalendarResource(store,250+index,body,href,[remoteETags objectForKey:href]);
    c->resources=[NSArray arrayWithObject:resource]; c->graph=CalendarGraph(c->resources);
    CHECK(RCTwoWayExchange(c,&error)); CalendarFixtureSession(local,nil,nil);
    NSDictionary *events=CalendarFixtureEvents(local); NSString *root=MainEventWithTitle(events,title); CHECK(root);
    NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:[events objectForKey:root]];
    NSCalendarDate *start=[event objectForKey:@"start date"];
    CHECK(RCCalendarFloatingDate(start)==(index==0));
    NSTimeZone *zone=[start timeZone];
    [event setObject:[NSCalendarDate dateWithYear:2026 month:7 day:1 hour:9 minute:0 second:0 timeZone:zone] forKey:@"start date"];
    [event setObject:[NSCalendarDate dateWithYear:2026 month:7 day:1 hour:10 minute:0 second:0 timeZone:zone] forKey:@"end date"];
    NSMutableDictionary *changes=[NSMutableDictionary dictionaryWithObject:event forKey:root];
    if(index) {
      [changes removeAllObjects]; NSEnumerator *keys=[events keyEnumerator]; NSString *identifier;
      while((identifier=[keys nextObject])) if([[[events objectForKey:identifier] objectForKey:@"summary"] isEqual:title]) {
        NSMutableDictionary *edited=[NSMutableDictionary dictionaryWithDictionary:[events objectForKey:identifier]];
        [edited setObject:@"Whole-series native note" forKey:@"description"]; [changes setObject:edited forKey:identifier];
      }
    }
    CalendarFixtureSession(local,changes,nil);
    int before=mutations;
    CHECK(RCTwoWayExchange(c,&error));
    CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==1); CHECK(mutations==before+1);
    NSString *wire=[[[NSString alloc] initWithData:[remoteBodies objectForKey:href] encoding:NSUTF8StringEncoding] autorelease];
    CHECK([wire rangeOfString:index ? @"DESCRIPTION:Whole-series native note" : @"DTSTART:20260701T090000\r\n"].location!=NSNotFound);
    resource=CalendarResource(store,250+index,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
    c->resources=[NSArray arrayWithObject:resource]; c->graph=CalendarGraph(c->resources);
    CHECK(RCTwoWayExchange(c,&error));
    CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state IN ('queued','applied','conflict')")==0);
    CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==0);
    CHECK(mutations==before+1);
    CalendarFixtureSession(local,nil,nil);
    CHECK([MainEventWithTitle(CalendarFixtureEvents(local),title) isEqual:root]);
  }
  puts("PASS: Native floating date edits and projected custom-DST series notes upload without changing source time semantics, acknowledge on the same records, and replay without duplicate PUTs");
}
static void CalendarExceptionIntegration(RCTwoWayContext *c,ISyncClient *local,RCCalendarStore *store)
{
  NSString *title=[marker stringByAppendingString:@"-series"], *href=@"https://fixture.invalid/calendar/series.ics";
  NSData *body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:series\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nRRULE:FREQ=DAILY;COUNT=10\r\nSUMMARY:%@\r\nX-PRIVATE:keep\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",title] dataUsingEncoding:NSUTF8StringEncoding];
  [remoteBodies setObject:body forKey:href]; [remoteETags setObject:@"\"series-base\"" forKey:href];
  NSDictionary *resource=CalendarResource(store,30,body,href,[remoteETags objectForKey:href]);
  c->resources=[NSArray arrayWithObject:resource]; c->graph=CalendarGraph(c->resources);
  CHECK(RCTwoWayExchange(c,&error)); CalendarFixtureSession(local,nil,nil);
  NSDictionary *events=CalendarFixtureEvents(local); NSString *root=EventWithTitle(events,title); CHECK(root);
  NSMutableDictionary *master=[NSMutableDictionary dictionaryWithDictionary:[events objectForKey:root]], *exception=[NSMutableDictionary dictionaryWithDictionary:master];
  NSCalendarDate *original=[[[NSCalendarDate alloc] initWithTimeIntervalSinceReferenceDate:[[master objectForKey:@"start date"] timeIntervalSinceReferenceDate]+86400] autorelease];
  [exception setObject:[NSArray arrayWithObject:root] forKey:@"main event"];
  [exception setObject:original forKey:@"original date"]; [exception setObject:[NSArray array] forKey:@"recurrences"];
  [exception setObject:[title stringByAppendingString:@"-exception"] forKey:@"summary"];
  [exception setObject:original forKey:@"start date"];
  [exception setObject:[[[NSCalendarDate alloc] initWithTimeIntervalSinceReferenceDate:[original timeIntervalSinceReferenceDate]+3600] autorelease] forKey:@"end date"];
  [master setObject:[NSArray arrayWithObject:@"local-exception"] forKey:@"detached events"];
  long long creates=Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE kind='create'"); int before=mutations;
  CalendarFixtureSession(local,[NSDictionary dictionaryWithObjectsAndKeys:master,root,exception,@"local-exception",nil],nil);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
  CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE kind='create'")==creates);
  CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==1); CHECK(mutations==before+1);
  resource=CalendarResource(store,30,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
  c->resources=[NSArray arrayWithObject:resource]; c->graph=CalendarGraph(c->resources);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state IN ('queued','applied','conflict')")==0);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==0);
  CalendarFixtureSession(local,nil,nil);
  events=CalendarFixtureEvents(local); root=EventWithTitle(events,title); CHECK(root);
  NSString *detached=EventWithTitle(events,[title stringByAppendingString:@"-exception"]); CHECK(detached);
  master=[NSMutableDictionary dictionaryWithDictionary:[events objectForKey:root]];
  [master setObject:[NSArray array] forKey:@"detached events"];
  [master setObject:[NSArray arrayWithObject:original] forKey:@"exception dates"];
  CalendarFixtureSession(local,[NSDictionary dictionaryWithObject:master forKey:root],[NSArray arrayWithObject:detached]);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==1);
  resource=CalendarResource(store,30,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
  c->resources=[NSArray arrayWithObject:resource]; c->graph=CalendarGraph(c->resources);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state IN ('queued','applied','conflict')")==0);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==0);
  puts("PASS: Tiger exception creation/deletion uses one parent PUT, exact acknowledgement and replay without duplicates");
  NSString *soundTitle=[marker stringByAppendingString:@"-sound"], *soundHref=@"https://fixture.invalid/calendar/sound.ics";
  NSData *soundBody=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:sound\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:%@\r\nBEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT15M\r\nATTACH:file:///System/Library/Sounds/Basso.aiff\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",soundTitle] dataUsingEncoding:NSUTF8StringEncoding];
  [remoteBodies setObject:soundBody forKey:soundHref]; [remoteETags setObject:@"\"sound-base\"" forKey:soundHref];
  NSDictionary *soundResource=CalendarResource(store,31,soundBody,soundHref,[remoteETags objectForKey:soundHref]);
  c->resources=[NSArray arrayWithObjects:resource,soundResource,nil]; c->graph=CalendarGraph(c->resources);
  CHECK(RCTwoWayExchange(c,&error)); CalendarFixtureSession(local,nil,nil);
  events=CalendarFixtureEvents(local); NSString *soundRoot=EventWithTitle(events,soundTitle); CHECK(soundRoot);
  NSMutableDictionary *soundEvent=[NSMutableDictionary dictionaryWithDictionary:[events objectForKey:soundRoot]];
  NSString *alarmID=[[soundEvent objectForKey:@"audio alarms"] objectAtIndex:0];
  ISyncRecordSnapshot *snapshot=[[ISyncManager sharedManager] snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
  NSMutableDictionary *alarm=[NSMutableDictionary dictionaryWithDictionary:[[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:alarmID]] objectForKey:alarmID]];
  [alarm setObject:[NSURL URLWithString:@"file:///System/Library/Sounds/Glass.aiff"] forKey:@"com.apple.ical.sound"];
  CalendarFixtureSession(local,[NSDictionary dictionaryWithObjectsAndKeys:soundEvent,soundRoot,alarm,alarmID,nil],nil);
  before=mutations;
  CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==1); CHECK(mutations==before+1);
  soundResource=CalendarResource(store,31,[remoteBodies objectForKey:soundHref],soundHref,[remoteETags objectForKey:soundHref]);
  c->resources=[NSArray arrayWithObjects:resource,soundResource,nil]; c->graph=CalendarGraph(c->resources);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state IN ('queued','applied','conflict')")==0);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==0);
  puts("PASS: Tiger audio sound survives native collection, verified upload and replay");
  CalendarFixtureSession(local,nil,nil);
  events=CalendarFixtureEvents(local); soundRoot=EventWithTitle(events,soundTitle); CHECK(soundRoot);
  soundEvent=[NSMutableDictionary dictionaryWithDictionary:[events objectForKey:soundRoot]];
  alarmID=[[soundEvent objectForKey:@"audio alarms"] objectAtIndex:0];
  snapshot=[[ISyncManager sharedManager] snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
  alarm=[NSMutableDictionary dictionaryWithDictionary:[[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:alarmID]] objectForKey:alarmID]];
  [alarm setObject:[NSNumber numberWithInt:-1800] forKey:@"triggerduration"];
  [soundEvent setObject:[NSArray arrayWithObject:@"expanded-native-rule"] forKey:@"recurrences"];
  NSDictionary *rule=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Recurrence",ISyncRecordEntityNameKey,[NSArray arrayWithObject:soundRoot],@"owner",@"weekly",@"frequency",[NSNumber numberWithInt:2],@"interval",[NSNumber numberWithInt:4],@"count",@"monday",@"weekstartday",nil];
  [soundEvent setObject:[NSArray arrayWithObject:@"expanded-native-attendee"] forKey:@"attendees"];
  NSDictionary *person=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Attendee",ISyncRecordEntityNameKey,[NSArray arrayWithObject:soundRoot],@"owner",@"synthetic@example.invalid",@"email",@"requiredparticipant",@"role",@"accepted",@"status",@"individual",@"user type",[NSNumber numberWithBool:YES],@"rsvp",nil];
  CalendarFixtureSession(local,[NSDictionary dictionaryWithObjectsAndKeys:soundEvent,soundRoot,alarm,alarmID,rule,@"expanded-native-rule",person,@"expanded-native-attendee",nil],nil);
  before=mutations;
  CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==1); CHECK(mutations==before+1);
  soundResource=CalendarResource(store,31,[remoteBodies objectForKey:soundHref],soundHref,[remoteETags objectForKey:soundHref]);
  c->resources=[NSArray arrayWithObjects:resource,soundResource,nil]; c->graph=CalendarGraph(c->resources);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state IN ('queued','applied','conflict')")==0);
  CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/calendar",&error)==0);
  puts("PASS: Native recurrence, reminder timing and attendee edits upload, acknowledge and replay without duplicate PUTs");
  CalendarTimeIntegration(c,local,store);
}
static void CalendarTests(BOOL exceptionsOnly)
{
  ISyncManager *manager=[ISyncManager sharedManager]; ISyncClient *local=nil,*server=nil;
  RCCalendarStore *store=NULL;
  NSArray *entities=[NSArray arrayWithObjects:@"com.apple.calendars.Calendar",@"com.apple.calendars.Event",nil];
  NSMutableDictionary *baseline=[NSMutableDictionary dictionary];
  ISyncRecordSnapshot *snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:entities usingIdentifiersForClient:nil];
  NSEnumerator *it=[entities objectEnumerator]; NSString *entity;
  while ((entity=[it nextObject])) [baseline addEntriesFromDictionary:[snapshot recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:entity forKey:ISyncRecordEntityNameKey]]];
  CHECK([NSKeyedArchiver archiveRootObject:baseline toFile:@"Calendar-baseline.archive"]);
  @try {
    NSString *description=[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"CalendarSyncClient.plist"];
    NSMutableDictionary *desc=[NSMutableDictionary dictionaryWithContentsOfFile:description]; CHECK(desc);
    [desc setObject:@"Retro Cloud Two Way Tests" forKey:@"DisplayName"]; [desc removeObjectForKey:@"PushOnlyEntities"]; CHECK([desc writeToFile:description atomically:YES]);
    CHECK(![manager clientWithIdentifier:@"com.altivecintelligence.tw.test.cal.local"] && ![manager clientWithIdentifier:@"com.altivecintelligence.tw.test.cal.server"]);
    local=[manager registerClientWithIdentifier:@"com.altivecintelligence.tw.test.cal.local" descriptionFilePath:description]; CHECK(local);
    [local setEnabled:YES forEntityNames:[[desc objectForKey:@"Entities"] allKeys]];
    store=RCCalendarStoreOpen("TwoWayCalendar.sqlite","synthetic",&error); CHECK(store);
    RCWriteJournal j=RCCalendarStoreWriteJournal(store);
    CHECK(RCTwoWaySQL(&j,&error,"INSERT INTO calendars(account_id,url,sync_id,display_name) VALUES(%lld,'https://fixture.invalid/calendar/','fixture','Fixture')",j.account));
    if (exceptionsOnly) {
      remoteBodies=[NSMutableDictionary dictionary]; remoteETags=[NSMutableDictionary dictionary]; mutations=0;
      RCTwoWayContext subset={j,@"com.altivecintelligence.tw.test.cal.server",description,@"com.apple.calendars.Event",[NSArray array],CalendarGraph([NSArray array]),RCCalendarEncodeLocal,store,NO,RCCalendarProjectVerified,NO};
      @try { CalendarExceptionIntegration(&subset,local,store); }
      @finally { server=[manager clientWithIdentifier:subset.clientIdentifier]; }
      goto calendarDone;
    }
    NSString *href=@"https://fixture.invalid/calendar/fixture.ics";
    NSData *body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:fixture\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:%@\r\nX-PRIVATE:keep\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",marker] dataUsingEncoding:NSUTF8StringEncoding];
    remoteBodies=[NSMutableDictionary dictionaryWithObject:body forKey:href]; remoteETags=[NSMutableDictionary dictionaryWithObject:@"\"base\"" forKey:href]; mutations=0;
    NSDictionary *resource=CalendarResource(store,1,body,href,@"\"base\"");
    NSArray *resources=[NSArray arrayWithObject:resource];
    RCTwoWayContext c={j,@"com.altivecintelligence.tw.test.cal.server",description,@"com.apple.calendars.Event",resources,CalendarGraph(resources),RCCalendarEncodeLocal,store,NO,RCCalendarProjectVerified,NO};
    server=LegacyClient(c.clientIdentifier,description,c.graph);
    CHECK(![server canPullChangesForEntityName:c.rootEntity]);
    LocalSession(local,nil,NO);
    NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:[[resource objectForKey:@"graph"] objectForKey:[resource objectForKey:@"root"]]];
    [event setObject:[NSArray arrayWithObject:@"calendar"] forKey:@"calendar"];
    [event setObject:[marker stringByAppendingString:@"-new"] forKey:@"summary"];
    [event removeObjectForKey:@"all day"]; [event removeObjectForKey:@"status"]; [event removeObjectForKey:@"classification"];
    LocalSession(local,[NSDictionary dictionaryWithObject:event forKey:@"new-event"],NO);
    fprintf(stderr,"Stage: migration with an event created before initial two-way sync\n");
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK([server canPullChangesForEntityName:c.rootEntity]);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1); CHECK(mutations==1);
    NSString *newHref=nil; it=[remoteBodies keyEnumerator]; NSString *key;
    while ((key=[it nextObject])) if (![key isEqual:href]) newHref=key;
    CHECK(newHref);
    /* Another device edits the new event before the first mirror download.
       The uploaded revision is durable in the journal but is no longer current. */
    NSString *originalTitle=[marker stringByAppendingString:@"-new"];
    NSString *remoteTitle=[originalTitle stringByAppendingString:@" (remote edit)"];
    NSMutableString *newBody=[NSMutableString stringWithString:[[[NSString alloc] initWithData:[remoteBodies objectForKey:newHref] encoding:NSUTF8StringEncoding] autorelease]];
    [newBody replaceOccurrencesOfString:originalTitle withString:remoteTitle options:0 range:NSMakeRange(0,[newBody length])];
    [remoteBodies setObject:[newBody dataUsingEncoding:NSUTF8StringEncoding] forKey:newHref];
    [remoteETags setObject:@"\"newer-remote-revision\"" forKey:newHref];
    NSDictionary *created=CalendarResource(store,2,[remoteBodies objectForKey:newHref],newHref,[remoteETags objectForKey:newHref]);
    NSMutableString *replaced=[NSMutableString stringWithString:newBody];
    [replaced replaceOccurrencesOfString:@"UID:" withString:@"UID:different-object-" options:0 range:NSMakeRange(0,[replaced length])];
    NSDictionary *different=CalendarResource(store,2,[replaced dataUsingEncoding:NSUTF8StringEncoding],newHref,@"\"different-object\"");
    c.resources=[NSArray arrayWithObjects:resource,different,nil]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(c.didPublish);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='applied'")==1);
    c.resources=[NSArray arrayWithObjects:resource,created,nil]; c.graph=CalendarGraph(c.resources);
    fprintf(stderr,"Stage: acknowledge verified creation and publish newer remote title\n");
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(c.didPublish);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations")==1); CHECK(mutations==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==0);
    ISyncRecordSnapshot *updated=[manager snapshotOfRecordsInTruthWithEntityNames:entities usingIdentifiersForClient:local];
    NSDictionary *updatedEvent=[[updated recordsWithIdentifiers:[NSArray arrayWithObject:@"new-event"]] objectForKey:@"new-event"];
    CHECK([[updatedEvent objectForKey:@"summary"] isEqual:remoteTitle]);
    NSDictionary *fixtureEvents=[updated recordsWithMatchingAttributes:[NSDictionary dictionaryWithObject:@"com.apple.calendars.Event" forKey:ISyncRecordEntityNameKey]];
    NSEnumerator *fixtureIt=[fixtureEvents objectEnumerator]; NSDictionary *fixture; int fixtureCount=0;
    while ((fixture=[fixtureIt nextObject])) if ([[fixture objectForKey:@"summary"] hasPrefix:marker]) fixtureCount++;
    CHECK(fixtureCount==2);
    puts("PASS: Newer remote revision publishes on the original native identity without another PUT; a changed UID stays isolated");
    [event setObject:[marker stringByAppendingString:@" edited"] forKey:@"summary"];
    LocalSession(local,[NSDictionary dictionaryWithObject:event forKey:@"event"],NO);
    fprintf(stderr,"Stage: calendar edit after migration\n"); CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1); CHECK(mutations==2);
    resource=CalendarResource(store,1,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObjects:resource,created,nil]; c.graph=CalendarGraph(c.resources);
    [event setObject:[marker stringByAppendingString:@" edited twice"] forKey:@"summary"];
    LocalSession(local,[NSDictionary dictionaryWithObject:event forKey:@"event"],NO);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==2);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1); CHECK(mutations==3);
    resource=CalendarResource(store,1,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObjects:resource,created,nil]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==3);
    [event setObject:[marker stringByAppendingString:@" moves out of history"] forKey:@"summary"];
    LocalSession(local,[NSDictionary dictionaryWithObject:event forKey:@"event"],NO);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1);
    /* Successful history-limited inventory omits the still-existing event. */
    c.resources=[NSArray arrayWithObject:created]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(c.didPublish);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==4);
    CHECK([remoteBodies objectForKey:href]); CHECK(mutations==4);
    puts("PASS: Repeated calendar edits and uploads omitted by the history window complete without blocking");
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==0);
    puts("PASS: Push-only calendar registration migrated in place; pre-initialization creation and existing identities preserved");
    puts("PASS: Native calendar edits and creations use conditional PUT, stable identities and exact acknowledgement");
    /* Resolve an event conflict using imported aliases for a native creation. */
    ISyncRecordSnapshot *conflictSnapshot=[manager snapshotOfRecordsInTruthWithEntityNames:entities usingIdentifiersForClient:local];
    NSMutableDictionary *conflictEvent=[NSMutableDictionary dictionaryWithDictionary:
        [[conflictSnapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"new-event"]] objectForKey:@"new-event"]];
    [conflictEvent setObject:@"local conflict location" forKey:@"location"];
    LocalSession(local,[NSDictionary dictionaryWithObject:conflictEvent forKey:@"new-event"],NO);
    CHECK(RCTwoWayExchange(&c,&error));
    NSString *calendarRemote=[[[NSString alloc] initWithData:[remoteBodies objectForKey:newHref] encoding:NSUTF8StringEncoding] autorelease];
    calendarRemote=Replace(calendarRemote,@"END:VEVENT",@"DESCRIPTION:remote conflict description\r\nEND:VEVENT");
    [remoteBodies setObject:[calendarRemote dataUsingEncoding:NSUTF8StringEncoding] forKey:newHref];
    [remoteETags setObject:@"\"calendar-conflict\"" forKey:newHref];
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==1);
    created=CalendarResource(store,2,[remoteBodies objectForKey:newHref],newHref,[remoteETags objectForKey:newHref]);
    c.resources=[NSArray arrayWithObject:created]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==0);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1);
    calendarRemote=[[[NSString alloc] initWithData:[remoteBodies objectForKey:newHref] encoding:NSUTF8StringEncoding] autorelease];
    CHECK([calendarRemote rangeOfString:@"LOCATION:local conflict location"].location!=NSNotFound);
    CHECK([calendarRemote rangeOfString:@"DESCRIPTION:remote conflict description"].location!=NSNotFound);
    created=CalendarResource(store,2,[remoteBodies objectForKey:newHref],newHref,[remoteETags objectForKey:newHref]);
    c.resources=[NSArray arrayWithObject:created]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state IN ('queued','conflict','applied')")==0);
    puts("PASS: Calendar conflict resolution merges supported fields on the original native identity");
    LocalSession(local,nil,NO);
    LocalSession(local,[NSDictionary dictionaryWithObject:conflictEvent forKey:@"new-event"],YES);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='delete'")==1);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(!c.didPublishAll);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='delete'")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1);
    CHECK(![remoteBodies objectForKey:newHref]); CHECK([remoteBodies objectForKey:href]);
    c.resources=[NSArray array]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='delete' AND state='acknowledged'")==1);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==0);
    puts("PASS: Native event deletion uses conditional DELETE and leaves out-of-window events untouched");
    /* Restore the history-filtered fixture, then race its native deletion with
       a remote edit. The changed ETag must stop the original DELETE. */
    resource=CalendarResource(store,1,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObject:resource]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error)); LocalSessionAs(local,nil,NO,@"restored-event");
    LocalSession(local,[NSDictionary dictionaryWithObject:event forKey:@"restored-event"],YES);
    CHECK(RCTwoWayExchange(&c,&error));
    int beforeRace=mutations;
    NSString *raced=[[[NSString alloc] initWithData:[remoteBodies objectForKey:href] encoding:NSUTF8StringEncoding] autorelease];
    raced=Replace(raced,@"END:VEVENT",@"DESCRIPTION:edited while deleting\r\nEND:VEVENT");
    [remoteBodies setObject:[raced dataUsingEncoding:NSUTF8StringEncoding] forKey:href];
    [remoteETags setObject:@"\"delete-edit-race\"" forKey:href];
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1);
    CHECK(mutations==beforeRace); CHECK([remoteBodies objectForKey:href]);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==1);
    resource=CalendarResource(store,1,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObject:resource]; c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==0);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/calendar",&error)==1);
    if ([remoteBodies objectForKey:href]) {
      resource=CalendarResource(store,1,[remoteBodies objectForKey:href],href,[remoteETags objectForKey:href]);
      c.resources=[NSArray arrayWithObject:resource];
    } else c.resources=[NSArray array];
    c.graph=CalendarGraph(c.resources);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state IN ('queued','conflict','applied')")==0);
    puts("PASS: Concurrent remote edit prevents stale DELETE; the system's delete/edit decision completes conditionally");
    CalendarExceptionIntegration(&c,local,store);
  calendarDone: ;

  } @finally {
    Cleanup(local); Cleanup(server); if(local) [manager unregisterClient:local]; if(server) [manager unregisterClient:server];
    RCCalendarStoreClose(store);
  }
  snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:entities usingIdentifiersForClient:nil];
  NSDictionary *after=[snapshot recordsWithIdentifiers:[baseline allKeys]];
  CHECK(RCTwoWayGraphsEqual(baseline,after));
  puts("PASS: Pre-existing calendar/event records unchanged");
}
static void ContactRemoteDeleteConflict(RCTwoWayContext *c, ISyncClient *local, NSString *href)
{
    /* A verified remote deletion races a local edit. Canonical survival requires
       conditional recreation; canonical deletion requires verification only. */
    LocalSession(local,nil,NO);
    ISyncRecordSnapshot *snapshot=[[ISyncManager sharedManager] snapshotOfRecordsInTruthWithEntityNames:
        [local enabledEntityNames] usingIdentifiersForClient:local];
    /* A resolved conflict must permit a fresh user property edit. Check the
       native result before asking the coordinator to collect the deletion race. */
    ISyncChange *edit=[ISyncChange changeWithType:ISyncChangeTypeModify recordIdentifier:@"fixture"
        changes:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
        ISyncChangePropertySet,ISyncChangePropertyActionKey,@"notes",ISyncChangePropertyNameKey,
        @"edit racing remote delete",ISyncChangePropertyValueKey,nil]]];
    LocalSession(local,[NSDictionary dictionaryWithObject:edit forKey:@"fixture"],NO);
    snapshot=[[ISyncManager sharedManager] snapshotOfRecordsInTruthWithEntityNames:
        [local enabledEntityNames] usingIdentifiersForClient:local];
    CHECK([[[[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"] objectForKey:@"notes"] isEqual:@"edit racing remote delete"]);
    CHECK(RCTwoWayExchange(c,&error));
    CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    [remoteBodies removeObjectForKey:href]; [remoteETags removeObjectForKey:href];
    CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/vcard",&error)==1);
    CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state='conflict'")==1);
    c->resources=[NSArray array]; c->graph=[NSDictionary dictionary];
    CHECK(RCTwoWayExchange(c,&error));
    CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state='conflict'")==0);
    CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/vcard",&error)==1);
    if ([remoteBodies objectForKey:href]) {
      NSDictionary *resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
      c->resources=[NSArray arrayWithObject:resource]; c->graph=[resource objectForKey:@"graph"];
    }
    CHECK(RCTwoWayExchange(c,&error));
    CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations WHERE state IN ('queued','conflict','applied')")==0);
    CHECK(RCTwoWayExchange(c,&error)); CHECK(RCTwoWayRunWrites(&c->journal,(RCHTTPClient *)1,"text/vcard",&error)==0);
    puts("PASS: Local edit versus remote DELETE resolves through Sync Services without blind resurrection");
}
int main(int argc,char **argv)
{
  setvbuf(stdout,NULL,_IONBF,0);
  NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
  ISyncManager *manager=nil;
  ISyncClient *local=nil,*server=nil; RCContactStore *store=NULL; int status=1;
  @try {
    if (argc==2 && !strcmp(argv[1],"--mappers")) { MapperTests(); status=0; goto done; }
    manager=[ISyncManager sharedManager];
    if (argc==2 && !strcmp(argv[1],"--contact-publication")) {
      marker=[@"RetroCloudTwoWay-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
      CHECK([marker writeToFile:@"fixture-marker.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
      ContactCreationPolicyTests(YES); status=0; goto done;
    }
    if (argc==2 && (!strcmp(argv[1],"--calendars") || !strcmp(argv[1],"--calendar-exceptions"))) {
      marker=[@"RetroCloudTwoWay-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
      CHECK([marker writeToFile:@"fixture-marker.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
      CalendarTests(!strcmp(argv[1],"--calendar-exceptions")); status=0; goto done;
    }
    marker=[NSString stringWithContentsOfFile:@"fixture-marker.txt" encoding:NSUTF8StringEncoding error:NULL];
    if (argc==2 && !strcmp(argv[1],"--cleanup")) {
      CHECK([marker hasPrefix:@"RetroCloudTwoWay-"]);
      local=[manager clientWithIdentifier:@"com.altivecintelligence.tw.test.local"];
      server=[manager clientWithIdentifier:@"com.altivecintelligence.tw.test.server"];
      Cleanup(local); Cleanup(server); if(local) [manager unregisterClient:local]; if(server) [manager unregisterClient:server];
      local=[manager clientWithIdentifier:@"com.altivecintelligence.tw.test.cal.local"]; server=[manager clientWithIdentifier:@"com.altivecintelligence.tw.test.cal.server"];
      Cleanup(local); Cleanup(server); if(local) [manager unregisterClient:local]; if(server) [manager unregisterClient:server];
      if ([[NSFileManager defaultManager] fileExistsAtPath:@"Calendar-baseline.archive"]) {
        NSDictionary *baseline=[NSKeyedUnarchiver unarchiveObjectWithFile:@"Calendar-baseline.archive"]; CHECK(baseline);
        ISyncRecordSnapshot *snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:
            [NSArray arrayWithObjects:@"com.apple.calendars.Calendar",@"com.apple.calendars.Event",nil] usingIdentifiersForClient:nil];
        CHECK(RCTwoWayGraphsEqual(baseline,[snapshot recordsWithIdentifiers:[baseline allKeys]]));
        puts("PASS: Pre-existing calendar/event records unchanged after recovery cleanup");
      }
      local=nil; server=nil; status=0; goto done;
    }
    BOOL fieldsOnly=argc==2 && !strcmp(argv[1],"--fields");
    BOOL recoveryOnly=argc==2 && !strcmp(argv[1],"--recovery");
    BOOL editDeleteOnly=argc==2 && !strcmp(argv[1],"--edit-delete");
    BOOL conflictReplayOnly=argc==2 && !strcmp(argv[1],"--conflict-replay");
    CHECK(argc==1 || recoveryOnly || editDeleteOnly || fieldsOnly || conflictReplayOnly);
    CHECK(![manager clientWithIdentifier:@"com.altivecintelligence.tw.test.local"] && ![manager clientWithIdentifier:@"com.altivecintelligence.tw.test.server"]);
    marker=[@"RetroCloudTwoWay-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
    CHECK([marker writeToFile:@"fixture-marker.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    if (!recoveryOnly && !editDeleteOnly && !fieldsOnly && !conflictReplayOnly) { ContactCreationPolicyTests(0); ContactCreationPolicyTests(1); ContactCreationPolicyTests(2); ContactCreationPolicyTests(3); }
    mutations=0;
    NSString *description=[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"SyncClient.plist"];
    NSMutableDictionary *desc=[NSMutableDictionary dictionaryWithContentsOfFile:description]; CHECK(desc);
    [desc setObject:@"Retro Cloud Two Way Tests" forKey:@"DisplayName"]; [desc removeObjectForKey:@"PushOnlyEntities"];
    CHECK([desc writeToFile:description atomically:YES]);
    local=[manager registerClientWithIdentifier:@"com.altivecintelligence.tw.test.local" descriptionFilePath:description]; CHECK(local);
    [local setEnabled:YES forEntityNames:[[desc objectForKey:@"Entities"] allKeys]];
    store=RCContactStoreOpen("TwoWay.sqlite","synthetic",&error); CHECK(store);
    long long run,collection;
    CHECK(RCContactStoreBeginRun(store,&run,&error)); CHECK(RCContactStoreGetCollection(store,"https://fixture.invalid/book/","Fixture",&collection,&error));
    CHECK(RCContactStoreFinishCollection(store,collection,run,&error)); CHECK(RCContactStoreFinishRun(store,run,1,NULL,&error));
    NSString *raw=[NSString stringWithFormat:@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:fixture\r\nN:Fixture;%@;;;\r\nFN:%@ Fixture\r\nNOTE:base\r\nX-PRIVATE:keep\r\nEND:VCARD\r\n",marker,marker];
    NSString *href=@"https://fixture.invalid/book/fixture.vcf";
    NSData *body=[raw dataUsingEncoding:NSUTF8StringEncoding];
    remoteBodies=[NSMutableDictionary dictionaryWithObject:body forKey:href]; remoteETags=[NSMutableDictionary dictionaryWithObject:@"\"base\"" forKey:href];
    NSDictionary *resource=ContactResource(body,@"contact-fixture",href,@"\"base\"");
    RCWriteJournal j=RCContactStoreWriteJournal(store);
    RCTwoWayContext c={j,@"com.altivecintelligence.tw.test.server",description,@"com.apple.contacts.Contact",[NSArray arrayWithObject:resource],
        [resource objectForKey:@"graph"],EncodeFixtureContact,store,NO,RCContactProjectVerified,NO};
    server=LegacyClient(c.clientIdentifier,description,c.graph);
    CHECK(![server canPullChangesForEntityName:c.rootEntity]);
    if (fieldsOnly) {
      /* These cases only own marked fixtures. Exclude the existing desktop
         contacts once instead of repeatedly refusing each one every exchange. */
      CHECK(RCTwoWayInitialize(&j,&error));
      NSDictionary *baseline=[[manager snapshotOfRecordsInTruthWithEntityNames:[server enabledEntityNames]
          usingIdentifiersForClient:server] recordsWithMatchingAttributes:
          [NSDictionary dictionaryWithObject:c.rootEntity forKey:ISyncRecordEntityNameKey]];
      CHECK(RCTwoWaySQL(&j,&error,"BEGIN IMMEDIATE"));
      NSEnumerator *baselineIDs=[baseline keyEnumerator]; NSString *baselineID;
      while ((baselineID=[baselineIDs nextObject])) if (![[[baseline objectForKey:baselineID] objectForKey:@"first name"] hasPrefix:marker])
        CHECK(RCTwoWaySQL(&j,&error,"INSERT OR IGNORE INTO two_way_excluded VALUES(%lld,%Q)",j.account,[baselineID UTF8String]));
      CHECK(RCTwoWaySQL(&j,&error,"COMMIT"));
    }
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error));
    server=[manager clientWithIdentifier:c.clientIdentifier]; CHECK(server);
    LocalSession(local,nil,NO);
    if (conflictReplayOnly) goto sameFieldConflict;
    if (editDeleteOnly) {
      ContactRemoteDeleteConflict(&c,local,href);
      Cleanup(local); Cleanup(server); [manager unregisterClient:local]; [manager unregisterClient:server];
      local=nil; server=nil; status=0; goto done;
    }
    NSMutableDictionary *card=[NSMutableDictionary dictionaryWithDictionary:[[resource objectForKey:@"graph"] objectForKey:@"contact-fixture"]];
    [card setObject:@"local edit" forKey:@"notes"];
    if (fieldsOnly) {
      const unsigned char gif[]={71,73,70,56,57,97,1,0,1,0,128,0,0,0,0,0,255,255,255,33,249,4,1,0,0,0,0,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59};
      [card setObject:[NSData dataWithBytes:gif length:sizeof(gif)] forKey:@"image"];
    }
    LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"fixture"],NO);
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    CHECK(mutations==0);
    loseResponse=YES;
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==-1);
    CHECK(mutations==1);
    RCContactStoreClose(store); store=RCContactStoreOpen("TwoWay.sqlite","synthetic",&error); CHECK(store);
      if (normalizePhotos) photoStore=store;
    j=RCContactStoreWriteJournal(store); c.journal=j; c.context=store;
    CHECK(RCTwoWaySQL(&j,&error,"UPDATE write_operations SET retry_at=0 WHERE state='uncertain'"));
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==1);
    resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObject:resource]; c.graph=[resource objectForKey:@"graph"];
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
    if (fieldsOnly) { normalizePhotos=YES; remotePhotos=[NSMutableDictionary dictionary]; photoStore=store; }
    [card setObject:[marker stringByAppendingString:@"-new"] forKey:@"first name"];
    if (fieldsOnly) {
      NSMutableDictionary *newCard=[NSMutableDictionary dictionaryWithDictionary:card];
      [newCard setObject:[NSArray arrayWithObject:@"new-website"] forKey:@"URLs"];
      [newCard setObject:[NSArray arrayWithObject:@"new-address"] forKey:@"street addresses"];
      NSDictionary *website=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.URL",ISyncRecordEntityNameKey,
          @"home page",@"type",[NSURL URLWithString:@"https://fixture.invalid/home"],@"value",[NSArray arrayWithObject:@"new-fixture"],@"contact",nil];
      NSDictionary *address=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.Street Address",ISyncRecordEntityNameKey,
          @"work",@"type",@"Fixture City",@"city",[NSArray arrayWithObject:@"new-fixture"],@"contact",nil];
      [newCard setObject:@"Synthetic phonetic" forKey:@"first name yomi"];
      [newCard setObject:[NSArray arrayWithObject:@"new-date"] forKey:@"dates"];
      [newCard setObject:[NSArray arrayWithObject:@"new-related"] forKey:@"related names"];
      [newCard setObject:[NSArray arrayWithObject:@"new-im"] forKey:@"IMs"];
      NSDictionary *date=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.Date",ISyncRecordEntityNameKey,@"anniversary",@"type",[NSCalendarDate dateWithYear:2000 month:1 day:2 hour:12 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]],@"value",[NSArray arrayWithObject:@"new-fixture"],@"contact",nil];
      NSDictionary *related=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.Related Name",ISyncRecordEntityNameKey,@"partner",@"type",@"Synthetic partner",@"value",[NSArray arrayWithObject:@"new-fixture"],@"contact",nil];
      NSDictionary *im=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.IM",ISyncRecordEntityNameKey,@"home",@"type",@"jabber",@"service",@"synthetic@example.invalid",@"user",[NSArray arrayWithObject:@"new-fixture"],@"contact",nil];
      LocalSession(local,[NSDictionary dictionaryWithObjectsAndKeys:newCard,@"new-fixture",website,@"new-website",address,@"new-address",date,@"new-date",related,@"new-related",im,@"new-im",nil],NO);
    } else LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"new-fixture"],NO);
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==2);
    NSString *newHref=nil; NSEnumerator *it=[remoteBodies keyEnumerator]; NSString *key;
    while ((key=[it nextObject])) if (![key isEqual:href]) newHref=key;
    CHECK(newHref);
    NSDictionary *created=ContactResource([remoteBodies objectForKey:newHref],@"contact-downloaded-create",newHref,[remoteETags objectForKey:newHref]);
    NSMutableDictionary *full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
    c.graph=full; c.resources=[NSArray arrayWithObjects:resource,created,nil];
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==2);
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(mutations==2);
    if (fieldsOnly) {
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_pending_fields")==0);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_field_scopes")==2);
      CHECK([[created objectForKey:@"graph"] count]==6);
      CHECK([[[[created objectForKey:@"graph"] objectForKey:@"contact-downloaded-create"] objectForKey:@"image"] isEqual:[card objectForKey:@"image"]]);
      CHECK([[[[resource objectForKey:@"graph"] objectForKey:@"contact-fixture"] objectForKey:@"image"] isEqual:[card objectForKey:@"image"]]);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_aliases WHERE imported_id LIKE 'contact-downloaded-create%'")==6);
      ISyncRecordSnapshot *snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
      NSDictionary *native=[snapshot recordsWithIdentifiers:[NSArray arrayWithObjects:@"fixture",@"new-fixture",nil]];
      CHECK([[[native objectForKey:@"fixture"] objectForKey:@"image"] isEqual:[card objectForKey:@"image"]]);
      CHECK([[[native objectForKey:@"new-fixture"] objectForKey:@"image"] isEqual:[card objectForKey:@"image"]]);
      [card setObject:marker forKey:@"first name"]; [card setObject:@"second supported edit" forKey:@"notes"];
      NSMutableData *updatedPhoto=[NSMutableData dataWithData:[card objectForKey:@"image"]];
      ((unsigned char *)[updatedPhoto mutableBytes])[13]=127;
      [card setObject:updatedPhoto forKey:@"image"];
      LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"fixture"],NO);
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==3);
      resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
      full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
      c.graph=full; c.resources=[NSArray arrayWithObjects:resource,created,nil];
      [card setObject:@"newer supported edit" forKey:@"notes"];
      LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"fixture"],NO);
      RCContactStoreClose(store); store=RCContactStoreOpen("TwoWay.sqlite","synthetic",&error); CHECK(store);
      if (normalizePhotos) photoStore=store;
      j=RCContactStoreWriteJournal(store); c.journal=j; c.context=store;
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
      CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==4);
      resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
      CHECK([[[[resource objectForKey:@"graph"] objectForKey:@"contact-fixture"] objectForKey:@"notes"] isEqual:@"newer supported edit"]);
      full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
      c.graph=full; c.resources=[NSArray arrayWithObjects:resource,created,nil];
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayExchange(&c,&error));
      CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
      CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==4);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_pending_fields")==0);
      snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
      CHECK([[[[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"] objectForKey:@"image"] isEqual:[card objectForKey:@"image"]]);
      NSString *remoteText=[[[NSString alloc] initWithData:[remoteBodies objectForKey:href] encoding:NSUTF8StringEncoding] autorelease];
      remoteText=Replace(remoteText,@"NOTE:newer supported edit",@"NOTE:new remote note");
      [remoteBodies setObject:[remoteText dataUsingEncoding:NSUTF8StringEncoding] forKey:href]; [remoteETags setObject:@"\"remote-after-partial\"" forKey:href];
      resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
      full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
      c.graph=full; c.resources=[NSArray arrayWithObjects:resource,created,nil];
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
      LocalSession(local,nil,NO);
      snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
      NSDictionary *remoteApplied=[[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"];
      CHECK([[remoteApplied objectForKey:@"notes"] isEqual:@"new remote note"]);
      CHECK([[remoteApplied objectForKey:@"image"] isEqual:[card objectForKey:@"image"]]);
      card=[NSMutableDictionary dictionaryWithDictionary:remoteApplied]; [card removeObjectForKey:@"image"];
      LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"fixture"],NO);
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_pending_fields")==0);
      CHECK(mutations==5);
      resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
      CHECK(![[[resource objectForKey:@"graph"] objectForKey:@"contact-fixture"] objectForKey:@"image"]);
      full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
      c.graph=full; c.resources=[NSArray arrayWithObjects:resource,created,nil];
      CHECK(RCTwoWayExchange(&c,&error));
      [card setObject:@"supported edit after image removal" forKey:@"notes"];
      LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"fixture"],NO);
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
      CHECK(mutations==6);
      resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
      full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
      c.graph=full; c.resources=[NSArray arrayWithObjects:resource,created,nil];
      CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayExchange(&c,&error));
      CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0); CHECK(mutations==6);
      CHECK(Scalar(&j,"SELECT count(*) FROM two_way_pending_fields")==0);
      snapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
      remoteApplied=[[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"];
      CHECK(![remoteApplied objectForKey:@"image"]);
      CHECK([[remoteApplied objectForKey:@"notes"] isEqual:@"supported edit after image removal"]);
      puts("PASS: Incoming remote edits preserve uploaded images; image removal uploads and later notes still complete");
      puts("PASS: Real Sync Services completes iCloud-style PHOTO URI creation/update, cache recovery, removal and replay without duplicate PUTs");
      Cleanup(local); Cleanup(server); [manager unregisterClient:local]; [manager unregisterClient:server];
      local=nil; server=nil; status=0; goto done;
    }
    [card setObject:marker forKey:@"first name"]; [card setObject:@"local edit" forKey:@"notes"];
    [card setObject:[NSArray arrayWithObject:@"phone"] forKey:@"phone numbers"];
    NSDictionary *phone=[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.contacts.Phone Number",ISyncRecordEntityNameKey,
        @"home",@"type",@"555-1234",@"value",[NSArray arrayWithObject:@"fixture"],@"contact",nil];
    LocalSession(local,[NSDictionary dictionaryWithObjectsAndKeys:card,@"fixture",phone,@"phone",nil],NO);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==3);
    resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
    full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
    c.resources=[NSArray arrayWithObjects:resource,created,nil]; c.graph=full;
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==3);
    LocalSession(local,[NSDictionary dictionaryWithObject:phone forKey:@"phone"],YES);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==4);
    resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
    full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
    c.resources=[NSArray arrayWithObjects:resource,created,nil]; c.graph=full;
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==4);
    [card removeObjectForKey:@"phone numbers"];
    [card setObject:marker forKey:@"first name"]; [card setObject:@"new local edit" forKey:@"notes"];
    LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"fixture"],NO);
    CHECK(RCTwoWayExchange(&c,&error));
    NSData *conflictBase=[remoteBodies objectForKey:href];
    NSString *collision=[[[NSString alloc] initWithData:conflictBase encoding:NSUTF8StringEncoding] autorelease];
    collision=Replace(collision,@"UID:",@"UID:different-");
    [remoteBodies setObject:[collision dataUsingEncoding:NSUTF8StringEncoding] forKey:href];
    [remoteETags setObject:@"\"concurrent\"" forKey:href];
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==1); CHECK(mutations==4);
    NSMutableDictionary *unrelated=[NSMutableDictionary dictionaryWithDictionary:card];
    [unrelated setObject:[marker stringByAppendingString:@"-unrelated"] forKey:@"first name"];
    LocalSession(local,[NSDictionary dictionaryWithObject:unrelated forKey:@"unrelated"],NO);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(c.didPublish); CHECK(mutations==4);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1); CHECK(mutations==5);
    CHECK(!c.didPublishAll);
    NSString *independentHref=nil;
    it=[remoteBodies keyEnumerator];
    while ((key=[it nextObject])) if (![key isEqual:href] && ![key isEqual:newHref]) independentHref=key;
    CHECK(independentHref);
    NSMutableString *independentBody=[NSMutableString stringWithString:
        [[[NSString alloc] initWithData:[remoteBodies objectForKey:independentHref] encoding:NSUTF8StringEncoding] autorelease]];
    [independentBody replaceOccurrencesOfString:@"NOTE:new local edit" withString:@"NOTE:unrelated remote edit"
        options:0 range:NSMakeRange(0,[independentBody length])];
    [remoteBodies setObject:[independentBody dataUsingEncoding:NSUTF8StringEncoding] forKey:independentHref];
    [remoteETags setObject:@"\"independent-remote\"" forKey:independentHref];
    NSDictionary *independent=ContactResource([remoteBodies objectForKey:independentHref],@"contact-independent",independentHref,[remoteETags objectForKey:independentHref]);
    full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
    [full addEntriesFromDictionary:[created objectForKey:@"graph"]]; [full addEntriesFromDictionary:[independent objectForKey:@"graph"]];
    c.resources=[NSArray arrayWithObjects:resource,created,independent,nil]; c.graph=full;
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(!c.didPublishAll);
    ISyncRecordSnapshot *independentSnapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
    CHECK([[[[independentSnapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"unrelated"]] objectForKey:@"unrelated"] objectForKey:@"notes"] isEqual:@"unrelated remote edit"]);
    [remoteBodies removeObjectForKey:independentHref]; [remoteETags removeObjectForKey:independentHref];
    full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]]; [full addEntriesFromDictionary:[created objectForKey:@"graph"]];
    c.resources=[NSArray arrayWithObjects:resource,created,nil]; c.graph=full;
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(!c.didPublishAll);
    independentSnapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
    CHECK(![[independentSnapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"unrelated"]] objectForKey:@"unrelated"]);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0); CHECK(mutations==5);
    puts("PASS: A conflicted contact stays protected while unrelated uploads, downloads and remote deletions continue");
    puts("PASS: Lost PUT response, reopened journal and concurrent remote edit retain exact intent without duplicate or blind writes");
    puts("PASS: Native collection -> conditional PUT -> verified mirror -> exact acceptance; create identities and replay");
    /* Retire the deliberate identity-collision fixture, then cause a fresh
       supported conflict through the writer's normal GET path. */
    CHECK(RCWriteJournalCancel(&j,Scalar(&j,"SELECT id FROM write_operations WHERE state='conflict'"),&error));
    [remoteBodies setObject:conflictBase forKey:href];
    resource=ContactResource(conflictBase,@"contact-fixture",href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObjects:resource,created,nil];
    full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
    [full addEntriesFromDictionary:[created objectForKey:@"graph"]]; c.graph=full;
    CHECK(RCTwoWayExchange(&c,&error));

    NSString *conflictText=[[[NSString alloc] initWithData:conflictBase encoding:NSUTF8StringEncoding] autorelease];
    conflictText=Replace(conflictText,@"END:VCARD",@"TITLE:remote job\r\nEND:VCARD");
    NSData *conflictBody=[conflictText dataUsingEncoding:NSUTF8StringEncoding];
    [remoteBodies setObject:conflictBody forKey:href];
    [remoteETags setObject:@"\"supported-conflict\"" forKey:href];
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
    resource=ContactResource(conflictBody,@"contact-fixture",href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObjects:resource,created,nil];
    full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
    [full addEntriesFromDictionary:[created objectForKey:@"graph"]]; c.graph=full;
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==0);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_resolutions")==1);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
    NSString *resolvedText=[[[NSString alloc] initWithData:[remoteBodies objectForKey:href] encoding:NSUTF8StringEncoding] autorelease];
    CHECK([resolvedText rangeOfString:@"TITLE:remote job"].location!=NSNotFound);
    CHECK([resolvedText rangeOfString:@"NOTE:new local edit"].location!=NSNotFound);
    resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObjects:resource,created,nil];
    full=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"graph"]];
    [full addEntriesFromDictionary:[created objectForKey:@"graph"]]; c.graph=full;
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state IN ('queued','applied','conflict')")==0);
    puts("PASS: Production contact conflict resolution preserves different-field edits and acknowledges its successor");
    LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"new-fixture"],YES);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='delete'")==1);
    int beforeDelete=mutations; loseResponse=YES;
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==-1);
    CHECK(![remoteBodies objectForKey:newHref]); CHECK(mutations==beforeDelete+1);
    RCContactStoreClose(store); store=RCContactStoreOpen("TwoWay.sqlite","synthetic",&error); CHECK(store);
      if (normalizePhotos) photoStore=store;
    j=RCContactStoreWriteJournal(store); c.journal=j; c.context=store;
    CHECK(RCTwoWaySQL(&j,&error,"UPDATE write_operations SET retry_at=0 WHERE state='uncertain'"));
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
    CHECK(mutations==beforeDelete+1);
    c.resources=[NSArray arrayWithObject:resource]; c.graph=[resource objectForKey:@"graph"];
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='delete' AND state='acknowledged'")==1);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
    puts("PASS: Native contact DELETE survives a lost response and reopened journal without duplicate mutation");
  sameFieldConflict: ;
    /* A same-field conflict follows the system's canonical decision, without
       assuming that Tiger displays a chooser or always prefers one side. */
    ISyncRecordSnapshot *sameSnapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
    NSMutableDictionary *sameCard=[NSMutableDictionary dictionaryWithDictionary:
        [[sameSnapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"]];
    [sameCard setObject:@"same-field local" forKey:@"notes"];
    LocalSession(local,[NSDictionary dictionaryWithObject:sameCard forKey:@"fixture"],NO);
    CHECK(RCTwoWayExchange(&c,&error));
    NSString *sameText=[[[NSString alloc] initWithData:[remoteBodies objectForKey:href] encoding:NSUTF8StringEncoding] autorelease];
    sameText=Replace(sameText,conflictReplayOnly ? @"NOTE:base" : @"NOTE:new local edit",@"NOTE:same-field remote");
    [remoteBodies setObject:[sameText dataUsingEncoding:NSUTF8StringEncoding] forKey:href];
    [remoteETags setObject:@"\"same-field\"" forKey:href];
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
    resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObject:resource]; c.graph=[resource objectForKey:@"graph"];
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='conflict'")==0);
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
    resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
    c.resources=[NSArray arrayWithObject:resource]; c.graph=[resource objectForKey:@"graph"];
    CHECK(RCTwoWayExchange(&c,&error));
    /* Conflict Resolver is a separate native UI, not the Sync Alert permission
       prompt. Give the test runner/operator time to resolve it before making a
       new user edit; a provisional canonical snapshot is not a settled choice. */
    NSTask *review=[[[NSTask alloc] init] autorelease];
    [review setLaunchPath:@"/usr/bin/osascript"];
    [review setArguments:[NSArray arrayWithObjects:@"-e",
        @"tell application \"System Events\"\nrepeat 180 times\nif not (exists process \"Conflict Resolver\") then return\ndelay 1\nend repeat\nerror \"Test conflict review was not completed\"\nend tell",nil]];
    [review launch]; [review waitUntilExit]; CHECK([review terminationStatus]==0);
    /* The system may publish its final same-field decision in a later
       session. Pull it into the fixture client and drain conditional successors
       before asserting convergence or starting a new, unrelated edit/delete race. */
    int settle;
    for (settle=0;settle<4;settle++) {
      LocalSession(local,nil,NO);
      CHECK(RCTwoWayExchange(&c,&error));
      if (Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==0) break;
      CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
      resource=ContactResource([remoteBodies objectForKey:href],@"contact-fixture",href,[remoteETags objectForKey:href]);
      c.resources=[NSArray arrayWithObject:resource]; c.graph=[resource objectForKey:@"graph"];
      CHECK(RCTwoWayExchange(&c,&error));
    }
    CHECK(settle<4);
    sameSnapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
    NSDictionary *canonical=[[sameSnapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"];
    CHECK([[[[resource objectForKey:@"graph"] objectForKey:@"contact-fixture"] objectForKey:@"notes"] isEqual:[canonical objectForKey:@"notes"]]);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state IN ('queued','conflict','applied')")==0);
    puts("PASS: Same-field conflict uses and acknowledges the system's canonical value");
    ContactRemoteDeleteConflict(&c,local,href);

    Cleanup(local); Cleanup(server); [manager unregisterClient:local]; [manager unregisterClient:server]; local=nil;server=nil;
    if (!conflictReplayOnly) CalendarTests(NO);
    status=0;
  } @catch(NSException *exception) {
    fprintf(stderr,"FAIL: %s\n",[[exception reason] UTF8String]);
    @try { Cleanup(local); Cleanup(server); if(local) [manager unregisterClient:local]; if(server) [manager unregisterClient:server]; }
    @catch(NSException *cleanup) { fprintf(stderr,"Cleanup requires --cleanup: %s\n",[[cleanup reason] UTF8String]); }
  }
done:
  RCContactStoreClose(store); [pool release]; return status;
}
