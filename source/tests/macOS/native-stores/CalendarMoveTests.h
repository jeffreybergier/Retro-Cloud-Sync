#import "../../../macOS-daemon/RCCalendarOperations.h"

/* Shared EventKit regression: real local moves, simulated GET-verified remote
   completion through the production checkpoint. No live DAV requests. */
static void MoveSeed(RCCalendarStore *store,NSData *body,BOOL moved,
    const char *etag)
{
  CHECK(RCCalendarStoreBeginRun(store,&error));
  RCDAVCollection c; memset(&c,0,sizeof(c)); long long source=0,target=0;
  c.url="https://fixture.invalid/calendar/"; c.displayName="rCloud Move Source";
  CHECK(RCCalendarStoreCollection(store,&c,&source,&error));
  c.url="https://fixture.invalid/destination/"; c.displayName="rCloud Move Target";
  CHECK(RCCalendarStoreCollection(store,&c,&target,&error));
  CHECK(RCCalendarStoreSave(store,moved ? target : source,
      moved ? "https://fixture.invalid/destination/event.ics" :
          "https://fixture.invalid/calendar/event.ics",
      etag,[body bytes],[body length],&error));
  CHECK(RCCalendarStoreFinishRun(store,1,NULL,&error));
}
static NSString *MoveContainerID(RCWriteJournal j,const char *url)
{
  sqlite3_stmt *q=NULL;
  CHECK(sqlite3_prepare_v2(j.db,"SELECT n.root,n.native FROM "
      "native_store_resources n JOIN calendars c ON n.account_id=c.account_id "
      "AND n.root='@calendar-'||c.sync_id WHERE c.account_id=? AND c.url=?",
      -1,&q,NULL)==SQLITE_OK);
  sqlite3_bind_int64(q,1,j.account);
  sqlite3_bind_text(q,2,url,-1,SQLITE_TRANSIENT);
  CHECK(sqlite3_step(q)==SQLITE_ROW);
  NSString *root=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
  NSDictionary *ids=[NSKeyedUnarchiver unarchiveObjectWithData:
      [NSData dataWithBytes:sqlite3_column_blob(q,1) length:sqlite3_column_bytes(q,1)]];
  NSString *identifier=[ids objectForKey:root]; CHECK(identifier);
  sqlite3_finalize(q); return identifier;
}
static void CalendarMoveTests(NSString *directory)
{
  RCCalendarStore *store=RCCalendarStoreOpen(
      [[directory stringByAppendingPathComponent:@"calendar-moves.sqlite"]
          fileSystemRepresentation],"offline-calendar-moves",&error);
  CHECK(store); RCWriteJournal j=RCCalendarStoreWriteJournal(store);
  EKEventStore *events=[[EKEventStore alloc] init]; EKCalendar *outside=nil;
  @try {
    NSData *body=Data(@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n"
        "UID:offline-managed-move\r\nDTSTART:20260610T120000Z\r\n"
        "DTEND:20260610T130000Z\r\nSUMMARY:Reservation: offline move\r\n"
        "DESCRIPTION:original\r\nX-PRIVATE-MOVE:preserve\r\nEND:VEVENT\r\n"
        "END:VCALENDAR\r\n");
    MoveSeed(store,body,NO,"\"move-original\""); SyncCalendar(store,NO,YES);
    NSDictionary *row=FirstRow(j); NSString *identifier=[row objectForKey:@"id"];
    NSString *root=[[row objectForKey:@"resource"] objectForKey:@"root"];
    EKCalendar *destination=[events calendarWithIdentifier:
        MoveContainerID(j,"https://fixture.invalid/destination/")];
    CHECK(destination);
    EKEvent *event=[events eventWithIdentifier:identifier]; CHECK(event);
    /* A same-title calendar with no account-owned receipt is not a destination. */
    if([EKCalendar respondsToSelector:@selector(calendarForEntityType:eventStore:)])
      outside=[[EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:events] retain];
    [outside setSource:[destination source]]; [outside setTitle:[destination title]];
    CHECK(outside && [events saveCalendar:outside commit:YES error:NULL]);
    [event setCalendar:outside];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    long count=0;
    CHECK(!RCCurrentSyncBackend()->syncCalendars(store,NULL,YES,&count,&error));
    CHECK(Count(j,"SELECT count(*) FROM calendar_actions")==0);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    event=[events eventWithIdentifier:identifier]; CHECK(event);
    CHECK([[[event calendar] calendarIdentifier] isEqual:[outside calendarIdentifier]]);
    [event setCalendar:destination];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    CHECK([[event eventIdentifier] isEqual:identifier]);
    SyncCalendar(store,YES,NO); SyncCalendar(store,YES,NO);
    CHECK(Count(j,"SELECT count(*) FROM calendar_actions WHERE kind='move' AND state='queued'")==1);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    /* A server-rejected move can be explicitly reverted and then retried. */
    CHECK(sqlite3_exec(j.db,"UPDATE calendar_actions SET state='conflict'",
        NULL,NULL,NULL)==SQLITE_OK);
    event=[events eventWithIdentifier:identifier];
    [event setCalendar:[events calendarWithIdentifier:
        MoveContainerID(j,"https://fixture.invalid/calendar/")]];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM calendar_actions")==0);
    event=[events eventWithIdentifier:identifier]; [event setCalendar:destination];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    /* Switching to one-way must not overwrite a queued move. */
    SyncCalendar(store,NO,NO);
    event=[events eventWithIdentifier:identifier];
    CHECK([[[event calendar] calendarIdentifier] isEqual:[destination calendarIdentifier]]);
    [event setNotes:@"edit after move was queued"];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    CHECK(RCCalendarCommitVerifiedMove(&j,root,
        @"https://fixture.invalid/calendar/event.ics",
        @"https://fixture.invalid/destination/event.ics",
        @"\"move-verified\"",body,&error));
    CHECK(Count(j,"SELECT count(*) FROM calendar_actions")==0);
    CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:identifier]);
    CHECK([[[FirstRow(j) objectForKey:@"resource"] objectForKey:@"body"] isEqual:body]);
    SyncCalendar(store,YES,NO);
    CHECK(Count(j,"SELECT count(*) FROM calendar_actions")==0);
    CHECK(Count(j,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    NSData *confirmed=ConfirmWrite(j);
    NSString *wire=[[[NSString alloc] initWithData:confirmed encoding:NSUTF8StringEncoding] autorelease];
    CHECK([wire rangeOfString:@"DESCRIPTION:edit after move was queued"].location!=NSNotFound);
    CHECK([wire rangeOfString:@"X-PRIVATE-MOVE:preserve"].location!=NSNotFound);
    MoveSeed(store,confirmed,YES,"\"confirmed\"");
    SyncCalendar(store,YES,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    CHECK(Count(j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    CHECK(Count(j,"SELECT count(*) FROM native_store_resources WHERE root NOT LIKE '@%'")==1);
    CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:identifier]);
    CHECK(Count(j,"SELECT count(*) FROM two_way_attention")==0);
    puts("PASS: Managed EventKit calendar move queues once, preserves identity and later edits, acknowledges/replays without duplicates; unmanaged destinations and one-way overwrite are blocked");
  } @finally {
    Cleanup(j,NO);
    if(outside) CHECK([events removeCalendar:outside commit:YES error:NULL]);
    [outside release]; [events release]; RCCalendarStoreClose(store);
  }
}
