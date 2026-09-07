#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#import "../../../macOS-daemon/RCTwoWayNative.h"
#import "../../../macOS-daemon/RCSyncConflictSession.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static RCError error;
static NSMutableDictionary *remoteBodies, *remoteETags;
static int mutations=0;
static BOOL loseResponse=NO;
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
  r->statusCode=body ? 200 : 404;
  if (body) {
    r->etag=strdup([[remoteETags objectForKey:href] UTF8String]); r->bodyLength=[body length];
    r->body=malloc(r->bodyLength+1); memcpy(r->body,[body bytes],r->bodyLength); r->body[r->bodyLength]=0;
  }
  return 1;
}
int RCHTTPClientRequest(RCHTTPClient *c,const char *method,const char *url,const char *depth,
    const char *type,const void *body,size_t length,RCHTTPResponse *r,RCError *e)
{
  (void)c;(void)depth;(void)type;(void)body;(void)length;
  if (strcmp(method,"GET") || !Response(url,r)) { RCErrorSet(e,1,"Non-fixture request rejected"); return 0; }
  return 1;
}
int RCHTTPClientConditionalRequest(RCHTTPClient *c,const char *method,const char *url,const char *type,
    const void *body,size_t length,const char *etag,int create,RCHTTPResponse *r,RCError *e)
{
  (void)c;(void)type;
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
    [remoteBodies setObject:[NSData dataWithBytes:body length:length] forKey:href];
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
    NSString *name=[[NSString stringWithUTF8String:doc.properties[p].name] uppercaseString];
    if ([name isEqual:@"TEL"] || [name isEqual:@"EMAIL"] || [name isEqual:@"ADR"] || [name isEqual:@"URL"]) {
      int n=[[counts objectForKey:name] intValue]; [counts setObject:[NSNumber numberWithInt:n+1] forKey:name];
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
  return [NSDictionary dictionaryWithObjectsAndKeys:root,@"key",root,@"root",href,@"href",etag,@"etag",body,@"body",
      ContactGraph(body,root),@"graph",RCContactNativePaths(body,ContactGraph(body,root),root,&error),@"paths",[NSNumber numberWithInt:1],@"revision",nil];
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
    local=[manager registerClientWithIdentifier:@"com.retrocloudsync.tw.test.local" descriptionFilePath:description]; CHECK(local);
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
    RCTwoWayContext c={j,@"com.retrocloudsync.tw.test.server",description,@"com.apple.contacts.Contact",
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
    CHECK(RCTwoWayExchange(&c,&error));
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
  NSDictionary *desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); CHECK(desired);
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
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); CHECK(desired);
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
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); CHECK(desired);
  NSMutableDictionary *editedPhone=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:@"fixture-TEL-1"]];
  [editedPhone setObject:@"456" forKey:@"value"]; [truth setObject:editedPhone forKey:@"fixture-TEL-1"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); CHECK(desired);
  result=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([result rangeOfString:@"TEL:\r\nTEL;TYPE=HOME:456\r\n"].location!=NSNotFound);
  [card removeObjectForKey:@"phone numbers"]; [truth removeObjectForKey:@"fixture-TEL-1"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); CHECK(desired);
  result=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([result rangeOfString:@"TEL:\r\n"].location!=NSNotFound);
  CHECK([result rangeOfString:@"TEL;TYPE=HOME:123"].location==NSNotFound);
  [card setObject:[NSArray arrayWithObject:@"added-phone"] forKey:@"phone numbers"];
  [truth setObject:editedPhone forKey:@"added-phone"];
  desired=RCContactEncodeLocal(contacts,r,truth,@"fixture",&error); CHECK(desired);
  CHECK([[[desired objectForKey:@"paths"] objectForKey:@"TEL:1"] isEqual:@"added-phone"]);
  puts("PASS: Empty raw contact fields preserve occurrence identities through note edits, value edits, removal and addition");
  RCContactStoreClose(contacts);

  RCCalendarStore *cal=RCCalendarStoreOpen("MapperCalendar.sqlite","synthetic",&error); CHECK(cal);
  RCWriteJournal j=RCCalendarStoreWriteJournal(cal);
  CHECK(RCTwoWaySQL(&j,&error,"INSERT INTO calendars(account_id,url,sync_id,display_name) VALUES(%lld,'https://fixture.invalid/calendar/','fixture','Fixture')",j.account));
  NSData *ics=[@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:fixture\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:Original\r\nX-APPLE-PRIVATE:preserve\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n" dataUsingEncoding:NSUTF8StringEncoding];
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
  CHECK(RCCalendarEncodeLocal(cal,r,truth,id,&error));
  CHECK(RCCalendarEncodeLocal(cal,nil,truth,id,&error));
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
  RCCalendarStoreClose(cal);
  puts("PASS: Production contact/calendar reverse mappers preserve private fields and reject unsupported changes");
}
static NSDictionary *CalendarResource(RCCalendarStore *store, long long identifier, NSData *body, NSString *href, NSString *etag)
{
  NSDictionary *mapped=RCCalendarNativeGraph(store,identifier,@"calendar-fixture",body,&error); CHECK(mapped);
  NSString *root=nil; NSEnumerator *it=[mapped keyEnumerator]; NSString *id;
  while ((id=[it nextObject])) if ([[[mapped objectForKey:id] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Event"]) root=id;
  CHECK(root);
  return [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"resource-%lld",identifier],@"key",root,@"root",href,@"href",etag,@"etag",body,@"body",
      mapped,@"graph",[NSDictionary dictionaryWithObject:root forKey:@"event:"],@"paths",[NSNumber numberWithInt:1],@"revision",nil];
}
static NSDictionary *CalendarGraph(NSArray *resources)
{
  NSMutableDictionary *graph=[NSMutableDictionary dictionary]; NSMutableArray *events=[NSMutableArray array];
  NSEnumerator *it=[resources objectEnumerator]; NSDictionary *resource;
  while ((resource=[it nextObject])) { [graph addEntriesFromDictionary:[resource objectForKey:@"graph"]]; [events addObject:[resource objectForKey:@"root"]]; }
  [graph setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Calendar",ISyncRecordEntityNameKey,marker,@"title",
      [NSNumber numberWithBool:NO],@"read only",events,@"events",[NSArray array],@"tasks",nil] forKey:@"calendar-fixture"];
  return graph;
}
static void CalendarTests(void)
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
    CHECK(![manager clientWithIdentifier:@"com.retrocloudsync.tw.test.cal.local"] && ![manager clientWithIdentifier:@"com.retrocloudsync.tw.test.cal.server"]);
    local=[manager registerClientWithIdentifier:@"com.retrocloudsync.tw.test.cal.local" descriptionFilePath:description]; CHECK(local);
    [local setEnabled:YES forEntityNames:[[desc objectForKey:@"Entities"] allKeys]];
    store=RCCalendarStoreOpen("TwoWayCalendar.sqlite","synthetic",&error); CHECK(store);
    RCWriteJournal j=RCCalendarStoreWriteJournal(store);
    CHECK(RCTwoWaySQL(&j,&error,"INSERT INTO calendars(account_id,url,sync_id,display_name) VALUES(%lld,'https://fixture.invalid/calendar/','fixture','Fixture')",j.account));
    NSString *href=@"https://fixture.invalid/calendar/fixture.ics";
    NSData *body=[[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:fixture\r\nDTSTART:20260907T100000Z\r\nDTEND:20260907T110000Z\r\nSUMMARY:%@\r\nX-PRIVATE:keep\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",marker] dataUsingEncoding:NSUTF8StringEncoding];
    remoteBodies=[NSMutableDictionary dictionaryWithObject:body forKey:href]; remoteETags=[NSMutableDictionary dictionaryWithObject:@"\"base\"" forKey:href]; mutations=0;
    NSDictionary *resource=CalendarResource(store,1,body,href,@"\"base\"");
    NSArray *resources=[NSArray arrayWithObject:resource];
    RCTwoWayContext c={j,@"com.retrocloudsync.tw.test.cal.server",description,@"com.apple.calendars.Event",resources,CalendarGraph(resources),RCCalendarEncodeLocal,store,NO,RCCalendarProjectVerified,NO};
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
    NSMutableDictionary *sameCard=[NSMutableDictionary dictionaryWithDictionary:
        [[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"]];
    [sameCard setObject:@"edit racing remote delete" forKey:@"notes"];
    LocalSession(local,[NSDictionary dictionaryWithObject:sameCard forKey:@"fixture"],NO);
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
  ISyncManager *manager=[ISyncManager sharedManager];
  ISyncClient *local=nil,*server=nil; RCContactStore *store=NULL; int status=1;
  @try {
    if (argc==2 && !strcmp(argv[1],"--mappers")) { MapperTests(); status=0; goto done; }
    if (argc==2 && !strcmp(argv[1],"--contact-publication")) {
      marker=[@"RetroCloudTwoWay-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
      CHECK([marker writeToFile:@"fixture-marker.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
      ContactCreationPolicyTests(YES); status=0; goto done;
    }
    if (argc==2 && !strcmp(argv[1],"--calendars")) {
      marker=[@"RetroCloudTwoWay-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
      CHECK([marker writeToFile:@"fixture-marker.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
      CalendarTests(); status=0; goto done;
    }
    marker=[NSString stringWithContentsOfFile:@"fixture-marker.txt" encoding:NSUTF8StringEncoding error:NULL];
    if (argc==2 && !strcmp(argv[1],"--cleanup")) {
      CHECK([marker hasPrefix:@"RetroCloudTwoWay-"]);
      local=[manager clientWithIdentifier:@"com.retrocloudsync.tw.test.local"];
      server=[manager clientWithIdentifier:@"com.retrocloudsync.tw.test.server"];
      Cleanup(local); Cleanup(server); if(local) [manager unregisterClient:local]; if(server) [manager unregisterClient:server];
      local=[manager clientWithIdentifier:@"com.retrocloudsync.tw.test.cal.local"]; server=[manager clientWithIdentifier:@"com.retrocloudsync.tw.test.cal.server"];
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
    BOOL recoveryOnly=argc==2 && !strcmp(argv[1],"--recovery");
    BOOL editDeleteOnly=argc==2 && !strcmp(argv[1],"--edit-delete");
    CHECK(argc==1 || recoveryOnly || editDeleteOnly);
    CHECK(![manager clientWithIdentifier:@"com.retrocloudsync.tw.test.local"] && ![manager clientWithIdentifier:@"com.retrocloudsync.tw.test.server"]);
    marker=[@"RetroCloudTwoWay-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
    CHECK([marker writeToFile:@"fixture-marker.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    if (!recoveryOnly && !editDeleteOnly) { ContactCreationPolicyTests(0); ContactCreationPolicyTests(1); ContactCreationPolicyTests(2); ContactCreationPolicyTests(3); }
    mutations=0;
    NSString *description=[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"SyncClient.plist"];
    NSMutableDictionary *desc=[NSMutableDictionary dictionaryWithContentsOfFile:description]; CHECK(desc);
    [desc setObject:@"Retro Cloud Two Way Tests" forKey:@"DisplayName"]; [desc removeObjectForKey:@"PushOnlyEntities"];
    CHECK([desc writeToFile:description atomically:YES]);
    local=[manager registerClientWithIdentifier:@"com.retrocloudsync.tw.test.local" descriptionFilePath:description]; CHECK(local);
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
    RCTwoWayContext c={j,@"com.retrocloudsync.tw.test.server",description,@"com.apple.contacts.Contact",[NSArray arrayWithObject:resource],
        [resource objectForKey:@"graph"],EncodeFixtureContact,store,NO,RCContactProjectVerified,NO};
    server=LegacyClient(c.clientIdentifier,description,c.graph);
    CHECK(![server canPullChangesForEntityName:c.rootEntity]);
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error));
    server=[manager clientWithIdentifier:c.clientIdentifier]; CHECK(server);
    LocalSession(local,nil,NO);
    if (editDeleteOnly) {
      ContactRemoteDeleteConflict(&c,local,href);
      Cleanup(local); Cleanup(server); [manager unregisterClient:local]; [manager unregisterClient:server];
      local=nil; server=nil; status=0; goto done;
    }
    NSMutableDictionary *card=[NSMutableDictionary dictionaryWithDictionary:[[resource objectForKey:@"graph"] objectForKey:@"contact-fixture"]];
    [card setObject:@"local edit" forKey:@"notes"];
    LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"fixture"],NO);
    fprintf(stderr,"Stage: exchange at line %d\n",__LINE__);
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    CHECK(mutations==0);
    loseResponse=YES;
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==-1);
    CHECK(mutations==1);
    RCContactStoreClose(store); store=RCContactStoreOpen("TwoWay.sqlite","synthetic",&error); CHECK(store);
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
    [card setObject:[marker stringByAppendingString:@"-new"] forKey:@"first name"];
    LocalSession(local,[NSDictionary dictionaryWithObject:card forKey:@"new-fixture"],NO);
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
    j=RCContactStoreWriteJournal(store); c.journal=j; c.context=store;
    CHECK(RCTwoWaySQL(&j,&error,"UPDATE write_operations SET retry_at=0 WHERE state='uncertain'"));
    CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==1);
    CHECK(mutations==beforeDelete+1);
    c.resources=[NSArray arrayWithObject:resource]; c.graph=[resource objectForKey:@"graph"];
    CHECK(RCTwoWayExchange(&c,&error));
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE kind='delete' AND state='acknowledged'")==1);
    CHECK(RCTwoWayExchange(&c,&error)); CHECK(RCTwoWayRunWrites(&j,(RCHTTPClient *)1,"text/vcard",&error)==0);
    puts("PASS: Native contact DELETE survives a lost response and reopened journal without duplicate mutation");
    /* A same-field conflict follows the system's canonical decision, without
       assuming that Tiger displays a chooser or always prefers one side. */
    ISyncRecordSnapshot *sameSnapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
    NSMutableDictionary *sameCard=[NSMutableDictionary dictionaryWithDictionary:
        [[sameSnapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"]];
    [sameCard setObject:@"same-field local" forKey:@"notes"];
    LocalSession(local,[NSDictionary dictionaryWithObject:sameCard forKey:@"fixture"],NO);
    CHECK(RCTwoWayExchange(&c,&error));
    NSString *sameText=[[[NSString alloc] initWithData:[remoteBodies objectForKey:href] encoding:NSUTF8StringEncoding] autorelease];
    sameText=Replace(sameText,@"NOTE:new local edit",@"NOTE:same-field remote");
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
    sameSnapshot=[manager snapshotOfRecordsInTruthWithEntityNames:[local enabledEntityNames] usingIdentifiersForClient:local];
    NSDictionary *canonical=[[sameSnapshot recordsWithIdentifiers:[NSArray arrayWithObject:@"fixture"]] objectForKey:@"fixture"];
    CHECK([[[[resource objectForKey:@"graph"] objectForKey:@"contact-fixture"] objectForKey:@"notes"] isEqual:[canonical objectForKey:@"notes"]]);
    CHECK(Scalar(&j,"SELECT count(*) FROM write_operations WHERE state IN ('queued','conflict','applied')")==0);
    puts("PASS: Same-field conflict uses and acknowledges the system's canonical value");
    ContactRemoteDeleteConflict(&c,local,href);

    Cleanup(local); Cleanup(server); [manager unregisterClient:local]; [manager unregisterClient:server]; local=nil;server=nil;
    CalendarTests();
    status=0;
  } @catch(NSException *exception) {
    fprintf(stderr,"FAIL: %s\n",[[exception reason] UTF8String]);
    @try { Cleanup(local); Cleanup(server); if(local) [manager unregisterClient:local]; if(server) [manager unregisterClient:server]; }
    @catch(NSException *cleanup) { fprintf(stderr,"Cleanup requires --cleanup: %s\n",[[cleanup reason] UTF8String]); }
  }
done:
  RCContactStoreClose(store); [pool release]; return status;
}
