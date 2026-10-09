#import "../../../macOS-daemon/RCNativeStore.h"
#import "../../../macOS-daemon/RCMacNativeBackend.h"

/* Exercise the framework-free native exchange on Tiger as well as modern Macs.
   No system store or network is touched; the factory is an injected backend. */
static int backendMode, backendReleased;
@interface RCContractStore : NSObject <RCNativeStore> {
  RCTwoWayContext *context_;
}
- (id)initWithContext:(RCTwoWayContext *)context;
@end
@implementation RCContractStore
- (id)initWithContext:(RCTwoWayContext *)context
{ self=[super init]; if(self) context_=context; return self; }
- (void)dealloc { backendReleased++; [super dealloc]; }
- (BOOL)syncContainers:(RCError *)failure
{
  if(backendMode==1) {
    RCTwoWaySQL(&context_->journal,failure,"BEGIN IMMEDIATE; INSERT INTO two_way_attention VALUES(1,'fixture','rollback')");
    [NSException raise:@"SyntheticStoreFailure" format:@"fixture"];
  }
  if(backendMode==2) { RCErrorSet(failure,1,"Store access denied"); return NO; }
  return YES;
}
- (NSDictionary *)savedResources:(RCError *)failure
{
  if(backendMode==4) { RCErrorSet(failure,1,"Store temporarily unavailable"); return nil; }
  return [NSDictionary dictionary];
}
- (NSArray *)untrackedResources:(RCError *)failure
{ (void)failure; return [NSArray array]; }
- (NSDictionary *)readResource:(NSDictionary *)saved error:(RCError *)failure
{ (void)saved; RCErrorSet(failure,1,"Unexpected read"); return nil; }
- (BOOL)rememberResource:(NSDictionary *)resource native:(NSDictionary *)saved error:(RCError *)failure
{ (void)resource; (void)saved; RCErrorSet(failure,1,"Unexpected remember"); return NO; }
- (BOOL)canPublishResource:(NSDictionary *)resource error:(RCError *)failure
{ (void)resource; RCErrorSet(failure,1,"Unsupported fixture projection"); return NO; }
- (BOOL)publishResource:(NSDictionary *)resource error:(RCError *)failure
{ (void)resource; RCErrorSet(failure,1,"Unexpected publication"); return NO; }
- (BOOL)removeResource:(NSDictionary *)saved error:(RCError *)failure
{ (void)saved; RCErrorSet(failure,1,"Unexpected removal"); return NO; }
- (BOOL)acceptReceipt:(NSDictionary *)receipt scopes:(NSDictionary *)scopes
    newerTruth:(NSDictionary **)newer error:(RCError *)failure
{ (void)receipt; (void)scopes; (void)newer; RCErrorSet(failure,1,"Unexpected receipt"); return NO; }
@end
static id<RCNativeStore> ContractFactory(RCTwoWayContext *context,RCError *failure)
{
  /* The coordinator must initialize its journal before constructing a store. */
  sqlite3_stmt *q=NULL;
  int ready=sqlite3_prepare_v2(context->journal.db,"SELECT * FROM two_way_intents",-1,&q,NULL);
  sqlite3_finalize(q);
  if(ready!=SQLITE_OK || backendMode==0) { RCErrorSet(failure,1,"Factory unavailable"); return nil; }
  return [[RCContractStore alloc] initWithContext:context];
}
static void NativeBackendContractTests(void)
{
  CHECK([RCRecordEntityNameKey isEqual:ISyncRecordEntityNameKey]);
  CHECK(!RCUsesNativeStoresForVersion(10,8));
  CHECK(RCUsesNativeStoresForVersion(10,9));
  CHECK(RCUsesNativeStoresForVersion(11,0));
  CHECK(!strcmp(RCCurrentSyncBackend()->name,RCUsesNativeStores() ?
      "mac-addressbook-eventkit" : "mac-syncservices"));
  sqlite3 *db=NULL; CHECK(sqlite3_open(":memory:",&db)==SQLITE_OK);
  @try {
    RCTwoWayContext context; memset(&context,0,sizeof(context));
    context.journal.db=db; context.journal.account=1;
    context.rootEntity=@"com.apple.contacts.Contact";
    context.graph=[NSDictionary dictionary]; context.resources=[NSArray array];
    CHECK(RCWriteJournalInitialize(db,&error));
    CHECK(RCTwoWaySQL(&context.journal,&error,
        "CREATE TABLE collections(id INTEGER,account_id INTEGER,remote_missing INTEGER);"
        "CREATE TABLE contacts(collection_id INTEGER,remote_missing INTEGER,parse_error TEXT)"));
    for(backendMode=0;backendMode<5;backendMode++) {
      context.didPublish=YES; context.didPublishAll=YES; backendReleased=0;
      BOOL result=RCNativeExchange(&context,NO,ContractFactory,&error);
      CHECK(result==(backendMode==3));
      CHECK(context.didPublish==(backendMode==3) && context.didPublishAll==(backendMode==3));
      CHECK(backendReleased==(backendMode==0 ? 0 : 1));
      CHECK(sqlite3_get_autocommit(db));
      sqlite3_stmt *q=NULL;
      CHECK(sqlite3_prepare_v2(db,"SELECT count(*) FROM two_way_attention",-1,&q,NULL)==SQLITE_OK);
      CHECK(sqlite3_step(q)==SQLITE_ROW && sqlite3_column_int(q,0)==0); sqlite3_finalize(q);
    }
    /* Unsupported publication is partial success, never full acknowledgement. */
    backendMode=3;
    context.resources=[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
        @"root",@"root",@"fixture",@"href",[NSDictionary dictionary],@"graph",nil]];
    CHECK(RCNativeExchange(&context,NO,ContractFactory,&error));
    CHECK(context.didPublish && !context.didPublishAll);
  } @finally { sqlite3_close(db); }
  puts("PASS: Backend selection, graph compatibility, native factory lifetime, failure rollback and partial publication");
}
