#import "../../../macOS-daemon/RCNativeSystemStore.h"
#import "../../../macOS-daemon/RCTwoWayInternal.h"
#import "../../../macOS-daemon/RCNativeGraphChanges.h"

/* Exercise the production checkpoint with an injected native readback. No
   AddressBook/EventKit access or network requests occur in this fixture. */
@interface RCReceiptTestStore : RCNativeSystemStore {
  NSDictionary *readback_;
}
- (id)initWithTestContext:(RCTwoWayContext *)context;
- (void)setReadback:(NSDictionary *)readback;
@end
@implementation RCReceiptTestStore
- (id)initWithTestContext:(RCTwoWayContext *)context;
{
  self=[super init]; if(self) context_=context; return self;
}
- (void)setReadback:(NSDictionary *)readback;
{
  [readback retain]; [readback_ release]; readback_=readback;
}
- (NSDictionary *)rawGraph:(NSDictionary *)resource error:(RCError *)failure;
{
  (void)resource;
  if(!readback_) RCErrorSet(failure,1,"Synthetic store unavailable");
  return readback_;
}
- (void)dealloc;
{
  [readback_ release]; [super dealloc];
}
@end
static void ReceiptCheckpointTests(void)
{
  sqlite3 *db=NULL; CHECK(sqlite3_open(":memory:",&db)==SQLITE_OK);
  RCTwoWayContext context; memset(&context,0,sizeof(context));
  context.journal.db=db; context.journal.account=1;
  RCWriteJournal *j=&context.journal;
  CHECK(RCWriteJournalInitialize(db,&error)); CHECK(RCTwoWayInitialize(j,&error));
  CHECK(RCTwoWaySQL(j,&error,
      "CREATE TABLE native_store_resources(account_id,root,resource,native,snapshot,pending,PRIMARY KEY(account_id,root));"
      "CREATE TABLE native_upload_receipts(operation_id PRIMARY KEY,account_id,root,native,snapshot);"));
  NSDictionary *ids=[NSDictionary dictionaryWithObject:@"native-id" forKey:@"event"];
  NSDictionary *before=[NSDictionary dictionaryWithObjectsAndKeys:@"before",@"summary",@"unsupported original",@"private",nil];
  NSDictionary *after=[NSDictionary dictionaryWithObjectsAndKeys:@"uploaded",@"summary",@"unsupported edit",@"private",nil];
  NSDictionary *base=[NSDictionary dictionaryWithObject:before forKey:@"event"];
  NSDictionary *raw=[NSDictionary dictionaryWithObject:after forKey:@"event"];
  NSDictionary *receipt=[NSDictionary dictionaryWithObject:
      [NSDictionary dictionaryWithObjectsAndKeys:@"uploaded",@"summary",@"unsupported original",@"private",nil] forKey:@"event"];
  NSDictionary *scopes=[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:@"summary"] forKey:@"event"];
  NSDictionary *resource=[NSDictionary dictionaryWithObjectsAndKeys:@"event",@"root",base,@"graph",ids,@"_ids",base,@"_snapshot",nil];
  RCReceiptTestStore *native=[[RCReceiptTestStore alloc] initWithTestContext:&context];
  @try {
    CHECK([native rememberResource:resource native:resource error:&error]);
    // An unrelated interrupted save must not block the receipt's own root.
    CHECK(RCTwoWaySQL(j,&error,"INSERT INTO native_store_resources SELECT account_id,'unrelated',resource,native,snapshot,1 FROM native_store_resources"));
    long long operation=0;
    CHECK(RCWriteJournalEnqueue(j,"fixture","key","https://fixture.invalid/event.ics","create",0,"body",4,&operation,&error));
    CHECK(RCTwoWaySaveIntent(j,operation,receipt,[NSDictionary dictionary],scopes,&error));
    [native setReadback:raw];
    CHECK([native captureReceipt:receipt operation:operation scopes:scopes resource:resource error:&error]);
    CHECK(RCWriteJournalBeginAttempt(j,operation,2000000000,&error));
    CHECK(RCWriteJournalRecordResult(j,operation,"applied",200,"\"verified\"","body",4,&error));
    [native setReadback:nil]; // A later native failure cannot revoke the upload.
    for(int replay=0;replay<2;replay++) {
      CHECK([native acceptReceipt:receipt operation:operation scopes:scopes newerTruth:NULL error:&error]);
      NSDictionary *snapshot=CalendarSnapshot(*j,@"event");
      CHECK([[[snapshot objectForKey:@"event"] objectForKey:@"summary"] isEqual:@"uploaded"]);
      CHECK([[[snapshot objectForKey:@"event"] objectForKey:@"private"] isEqual:@"unsupported original"]);
    }
    CHECK(RCTwoWaySQL(j,&error,"DELETE FROM native_store_resources WHERE root='unrelated'"));
    NSDictionary *saved=[FirstRow(*j) objectForKey:@"resource"];
    CHECK([[saved objectForKey:@"etag"] isEqual:@"\"verified\""]);
    CHECK([[saved objectForKey:@"body"] isEqual:Data(@"body")]);
    NSDictionary *later=[NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObjectsAndKeys:@"later edit",@"summary",@"unsupported edit",@"private",nil] forKey:@"event"];
    NSDictionary *delta=RCChangedGraph([saved objectForKey:@"graph"],CalendarSnapshot(*j,@"event"),later);
    CHECK([[[delta objectForKey:@"event"] objectForKey:@"summary"] isEqual:@"later edit"]);
    CHECK([[[delta objectForKey:@"event"] objectForKey:@"private"] isEqual:@"unsupported edit"]);
    CHECK(RCTwoWaySQL(j,&error,"UPDATE native_store_resources SET pending=1 WHERE root='event'"));
    CHECK(![native acceptReceipt:receipt operation:operation scopes:scopes newerTruth:NULL error:&error]);
    CHECK(RCTwoWaySQL(j,&error,"UPDATE native_store_resources SET pending=0 WHERE root='event';DELETE FROM native_upload_receipts"));
    // Legacy receipts already represented by the baseline need no live read.
    CHECK([native acceptReceipt:receipt operation:operation scopes:scopes newerTruth:NULL error:&error]);
    puts("PASS: Scoped native receipt acknowledges offline despite unavailable/unrelated stores; partial fields, verified base and crash replay remain intact");
  } @finally { [native release]; sqlite3_close(db); }
}
