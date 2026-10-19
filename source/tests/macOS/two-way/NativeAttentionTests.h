/* Synthetic coordinator regressions; no native stores or network access. */
static long AttentionCount(sqlite3 *db,const char *where)
{
  sqlite3_stmt *q=NULL;
  char *sql=sqlite3_mprintf("SELECT count(*) FROM two_way_attention WHERE %s",where);
  CHECK(sqlite3_prepare_v2(db,sql,-1,&q,NULL)==SQLITE_OK); sqlite3_free(sql);
  CHECK(sqlite3_step(q)==SQLITE_ROW); long count=sqlite3_column_int(q,0);
  sqlite3_finalize(q); return count;
}
static NSMutableDictionary *AttentionEncode(void *context,
    NSDictionary *base,NSDictionary *truth,NSString *root,RCError *failure)
{
  (void)context; (void)base; (void)failure;
  return [NSMutableDictionary dictionaryWithObjectsAndKeys:root,@"root",
      root,@"key",@"https://fixture.invalid/created.ics",@"href",
      [@"body" dataUsingEncoding:NSUTF8StringEncoding],@"body",truth,@"graph",
      [NSDictionary dictionaryWithObject:root forKey:@"event:"],@"paths",nil];
}
static void NativeAttentionTests(void)
{
  sqlite3 *db=NULL; CHECK(sqlite3_open(":memory:",&db)==SQLITE_OK);
  @try {
    RCTwoWayContext c; memset(&c,0,sizeof(c));
    c.journal.db=db; c.journal.account=1;
    c.rootEntity=@"com.apple.calendars.Event";
    c.graph=[NSDictionary dictionary]; c.resources=[NSArray array];
    RCWriteJournal *j=&c.journal;
    CHECK(RCWriteJournalInitialize(db,&error));
    CHECK(RCTwoWayInitialize(j,&error));
    CHECK(RCTwoWaySQL(j,&error,
        "CREATE TABLE calendars(id INTEGER,account_id INTEGER,remote_missing INTEGER);"
        "CREATE TABLE calendar_resources(calendar_id INTEGER,href TEXT,remote_missing INTEGER,scope_excluded INTEGER);"));
    backendMode=3; backendLookups=0;
    CHECK(RCTwoWayAttention(j,@"native-event-deleted","unsupported-native-creation",&error));
    CHECK(RCTwoWayAttention(j,@"native-event-series","native-series-unverified",&error));
    CHECK(RCTwoWayAttention(j,@"native-event-outside-window","unsupported-native-creation",&error));
    CHECK(RCTwoWayAttention(j,@"native-event-conflict","remote-delete-local-edit",&error));
    CHECK(RCTwoWayAttention(j,@"cloud-series","native-series-unverified",&error));
    CHECK(RCTwoWayAttention(j,@"native-contact-other","unsupported-native-creation",&error));
    CHECK(RCTwoWaySQL(j,&error,"INSERT INTO two_way_attention VALUES(2,'native-event-deleted','unsupported-native-creation')"));
    backendExisting=[NSSet setWithObject:@"native-event-outside-window"];
    /* Denied, failed discovery, and failed direct lookup preserve all warnings. */
    backendMode=2;
    CHECK(!RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==7 && backendLookups==0);
    backendMode=6;
    CHECK(!RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==7 && backendLookups==0);
    backendMode=3; backendLookupError=@"native-event-series";
    CHECK(!RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==7 && sqlite3_get_autocommit(db));
    backendLookupError=nil;
    RCStopRequested=1;
    CHECK(!RCNativeExchange(&c,YES,ContractFactory,&error));
    RCStopRequested=0;
    CHECK(AttentionCount(db,"1")==7);
    CHECK(RCNativeExchange(&c,NO,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==7);
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==5);
    CHECK(AttentionCount(db,"account_id=1 AND record_id IN ('native-event-deleted','native-event-series')")==0);
    CHECK(c.didPublishAll);
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==5); /* idempotent */

    /* Still-discovered series and pending fields are never disappearance. */
    NSDictionary *record=[NSDictionary dictionaryWithObject:
        [NSArray arrayWithObject:@"rule"] forKey:@"recurrences"];
    NSDictionary *resource=[NSDictionary dictionaryWithObjectsAndKeys:
        @"native-event-seen",@"root",
        [NSDictionary dictionaryWithObject:record forKey:@"native-event-seen"],@"graph",nil];
    backendDiscovered=[NSArray arrayWithObject:resource];
    CHECK(RCTwoWayAttention(j,@"native-event-fields","unsupported-native-creation",&error));
    CHECK(RCTwoWaySQL(j,&error,"INSERT INTO two_way_pending_fields VALUES(1,'native-event-fields',X'00')"));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"record_id IN ('native-event-seen','native-event-fields')")==2);
    CHECK(!c.didPublishAll);
    backendDiscovered=nil;

    /* Legacy unfinished operations protect their root even without ownership;
       unrelated verified-deleted roots may still clear. */
    long long operation=0;
    CHECK(RCWriteJournalEnqueue(j,"pending","pending","https://fixture.invalid/pending.ics",
        "create",0,"body",4,&operation,&error));
    CHECK(RCTwoWaySaveResource(j,operation,
        [NSDictionary dictionaryWithObject:@"native-event-pending" forKey:@"root"],&error));
    CHECK(RCTwoWayAttention(j,@"native-event-pending","unsupported-native-creation",&error));
    CHECK(RCTwoWayAttention(j,@"native-event-unrelated-deleted","unsupported-native-creation",&error));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"record_id='native-event-pending'")==1);
    CHECK(AttentionCount(db,"record_id='native-event-unrelated-deleted'")==0);
    CHECK(RCTwoWaySQL(j,&error,"DELETE FROM two_way_resources"));
    CHECK(RCTwoWayAttention(j,@"native-event-unknown-owner","unsupported-native-creation",&error));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"record_id='native-event-unknown-owner'")==1);
    CHECK(RCTwoWaySQL(j,&error,"UPDATE write_operations SET state='cancelled'"));

    /* Unchanged owned records clear only resolved edit/publication reasons. */
    CHECK(RCTwoWaySQL(j,&error,"DELETE FROM two_way_pending_fields; DELETE FROM two_way_attention"));
    NSString *root=@"native-event-owned";
    NSDictionary *graph=[NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:@"com.apple.calendars.Event"
            forKey:RCRecordEntityNameKey] forKey:root];
    resource=[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",
        @"https://fixture.invalid/owned.ics",@"href",@"\"base\"",@"etag",
        [@"body" dataUsingEncoding:NSUTF8StringEncoding],@"body",graph,@"graph",nil];
    c.resources=[NSArray arrayWithObject:resource]; c.graph=graph;
    backendMode=5; backendTruth=graph;
    CHECK(RCTwoWayAttention(j,root,"unsupported-native-edit",&error));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==0);
    CHECK(RCTwoWayAttention(j,root,"native-publication-pending",&error));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==0);
    CHECK(RCTwoWayAttention(j,root,"unsupported-native-creation",&error));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"1")==1); /* owned, not a deleted creation */
    CHECK(RCTwoWayAttention(j,root,"verified-write-awaits-local-acceptance",&error));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"reason='verified-write-awaits-local-acceptance'")==1);

    /* A corrected creation becomes queued work, not stale rejection attention. */
    c.resources=[NSArray array]; c.graph=[NSDictionary dictionary];
    c.encode=AttentionEncode; backendMode=7; backendTruth=nil;
    root=@"native-event-corrected";
    graph=[NSDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObject:@"com.apple.calendars.Event"
            forKey:RCRecordEntityNameKey] forKey:root];
    backendDiscovered=[NSArray arrayWithObject:
        [NSDictionary dictionaryWithObjectsAndKeys:root,@"root",graph,@"graph",nil]];
    CHECK(RCTwoWayAttention(j,root,"unsupported-native-creation",&error));
    CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
    CHECK(AttentionCount(db,"record_id='native-event-corrected'")==0);
    sqlite3_stmt *q=NULL;
    CHECK(sqlite3_prepare_v2(db,"SELECT count(*) FROM write_operations WHERE state='queued'",-1,&q,NULL)==SQLITE_OK);
    CHECK(sqlite3_step(q)==SQLITE_ROW && sqlite3_column_int(q,0)==1);
    sqlite3_finalize(q);
    CHECK(!c.didPublishAll);
  } @finally {
    RCStopRequested=0;
    backendSaved=nil; backendDiscovered=nil; backendExisting=nil;
    backendLookupError=nil; backendTruth=nil; backendMode=3;
    sqlite3_close(db);
  }
  puts("PASS: Native attention clears verified deleted creations and reverted edits; access, scope, ownership, pending writes and unrelated warnings stay protected");
}
