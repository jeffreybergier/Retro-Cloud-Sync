#import <Cocoa/Cocoa.h>
#import <AddressBook/AddressBook.h>
#import <EventKit/EventKit.h>
#import "../../../macOS-daemon/RCNativeSync.h"
#import "../../../macOS-daemon/RCTwoWayNative.h"
#include <unistd.h>
static RCError error;
static NSMutableArray *extraContacts;
#define CHECK(x) do { RCErrorClear(&error); if(!(x)) [NSException raise:@"TestFailure" format:@"line %d: %s: %s",__LINE__,#x,error.message]; } while(0)
/* No networking code is called: fixtures enter the production mirror stores,
   and verified remote outcomes are simulated directly in the write journal. */
static NSData *Data(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static void ContactsSeed(RCContactStore *store,NSData *body,const char *etag)
{
  long long run,collection; int invalid=0;
  CHECK(RCContactStoreBeginRun(store,&run,&error));
  CHECK(RCContactStoreGetCollection(store,"https://fixture.invalid/book/","Offline fixture",&collection,&error));
  if(body) CHECK(RCContactStoreSaveResource(store,collection,run,"https://fixture.invalid/book/contact.vcf",etag,[body bytes],[body length],&invalid,&error) && !invalid);
  CHECK(RCContactStoreFinishCollection(store,collection,run,&error));
  CHECK(RCContactStoreFinishRun(store,run,1,NULL,&error));
}
static void CalendarSeed(RCCalendarStore *store,NSData *body,const char *etag)
{
  CHECK(RCCalendarStoreBeginRun(store,&error));
  RCDAVCollection collection; memset(&collection,0,sizeof(collection));
  collection.url="https://fixture.invalid/calendar/"; collection.displayName="rCloud Offline Test";
  long long identifier=0;
  CHECK(RCCalendarStoreCollection(store,&collection,&identifier,&error));
  if(body) CHECK(RCCalendarStoreSave(store,identifier,"https://fixture.invalid/calendar/event.ics",etag,[body bytes],[body length],&error));
  CHECK(RCCalendarStoreFinishRun(store,1,NULL,&error));
}
static NSDictionary *FirstRow(RCWriteJournal j)
{
  sqlite3_stmt *q=NULL; NSDictionary *row=nil;
  CHECK(sqlite3_prepare_v2(j.db,"SELECT resource,native FROM native_store_resources WHERE account_id=? AND root NOT LIKE '@%'",-1,&q,NULL)==SQLITE_OK);
  sqlite3_bind_int64(q,1,j.account);
  if(sqlite3_step(q)==SQLITE_ROW) {
    NSDictionary *r=[NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(q,0) length:sqlite3_column_bytes(q,0)]];
    NSDictionary *ids=[NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(q,1) length:sqlite3_column_bytes(q,1)]];
    row=[NSDictionary dictionaryWithObjectsAndKeys:r,@"resource",[ids objectForKey:[r objectForKey:@"root"]],@"id",nil];
  }
  sqlite3_finalize(q); return row;
}
static long Count(RCWriteJournal j,const char *sql)
{
  sqlite3_stmt *q=NULL; CHECK(sqlite3_prepare_v2(j.db,sql,-1,&q,NULL)==SQLITE_OK);
  CHECK(sqlite3_step(q)==SQLITE_ROW); long n=sqlite3_column_int(q,0); sqlite3_finalize(q); return n;
}
static void SyncContacts(RCContactStore *store,BOOL twoWay,BOOL full)
{
  long count=0; CHECK(RCNativeSyncContacts(store,twoWay,&count,&error)); CHECK(full ? count>=0 : count<0);
}
static void SyncCalendar(RCCalendarStore *store,BOOL twoWay,BOOL full)
{
  long count=0; CHECK(RCNativeSyncCalendars(store,twoWay,&count,&error)); CHECK(full ? count>=0 : count<0);
}
static NSData *ConfirmWrite(RCWriteJournal j)
{
  long long operation=0; CHECK(RCWriteJournalNext(&j,2000000000,&operation,&error)); CHECK(operation>0);
  RCWriteOperation o; CHECK(RCWriteJournalGet(&j,operation,&o,&error));
  NSData *body=o.desiredBody ? [NSData dataWithBytes:o.desiredBody length:o.desiredLength] : nil;
  CHECK(RCWriteJournalBeginAttempt(&j,operation,2000000000,&error));
  CHECK(RCWriteJournalRecordResult(&j,operation,"applied",body ? 200 : 404,body ? "\"confirmed\"" : NULL,[body bytes],[body length],&error));
  RCWriteOperationClear(&o); return body;
}
static void Cleanup(RCWriteJournal j,BOOL contacts)
{
  sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(j.db,"SELECT root,native FROM native_store_resources WHERE account_id=?",-1,&q,NULL)!=SQLITE_OK) return;
  sqlite3_bind_int64(q,1,j.account);
  ABAddressBook *book=contacts ? [ABAddressBook addressBook] : nil;
  EKEventStore *events=contacts ? nil : [[[EKEventStore alloc] init] autorelease];
  NSMutableArray *containers=[NSMutableArray array];
  while(sqlite3_step(q)==SQLITE_ROW) {
    NSString *root=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
    NSDictionary *ids=[NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(q,1) length:sqlite3_column_bytes(q,1)]];
    NSString *identifier=[ids objectForKey:root]; if(!identifier) continue;
    if(contacts) { ABRecord *r=[book recordForUniqueId:identifier]; if(r) [book removeRecord:r]; }
    else if([root hasPrefix:@"@"]) [containers addObject:identifier];
    else { EKEvent *event=[events eventWithIdentifier:identifier]; if(event) [events removeEvent:event span:EKSpanFutureEvents commit:YES error:NULL]; }
  }
  sqlite3_finalize(q);
  if(contacts) {
    for(NSString *identifier in extraContacts) { ABRecord *r=[book recordForUniqueId:identifier]; if(r) [book removeRecord:r]; }
    [book save];
  }
  for(NSString *identifier in containers) { EKCalendar *calendar=[events calendarWithIdentifier:identifier]; if(calendar) [events removeCalendar:calendar commit:YES error:NULL]; }
}
/* Exercise the real native projection, durable baseline, reverse mapper and
   queued wire body. No participant data is fabricated in the EventKit copy. */
static void InvitationTests(NSString *directory)
{
  NSString *path=[directory stringByAppendingPathComponent:@"invitations.sqlite"];
  RCCalendarStore *store=RCCalendarStoreOpen([path fileSystemRepresentation],
      "offline-invitation-test",&error); CHECK(store);
  @try {
    RCWriteJournal j=RCCalendarStoreWriteJournal(store);
    NSString *body=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//rCloud offline//EN\r\n"
        @"BEGIN:VEVENT\r\nUID:offline-invitation\r\nDTSTART:20261012T090000Z\r\nDTEND:20261012T100000Z\r\n"
        @"SUMMARY:Offline invitation\r\nDESCRIPTION:Original notes\r\nLOCATION:Original room\r\n"
        @"ORGANIZER;CN=Fixture Host;X-PRIVATE=host:mailto:host@example.invalid\r\n"
        @"ATTENDEE;CN=Fixture One;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;\r\n"
        @" RSVP=TRUE;X-PRIVATE=one:mailto:one@example.invalid\r\n"
        @"ATTENDEE;CN=Fixture Two;ROLE=OPT-PARTICIPANT;PARTSTAT=TENTATIVE;RSVP=FALSE:mailto:two@example.invalid\r\n"
        @"X-PRIVATE-FIXTURE:preserve\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    CalendarSeed(store,Data(body),"\"invite-1\""); SyncCalendar(store,NO,YES);
    NSDictionary *row=FirstRow(j); CHECK(row);
    NSString *eventID=[row objectForKey:@"id"];
    EKEventStore *events=[[[EKEventStore alloc] init] autorelease];
    EKEvent *event=[events eventWithIdentifier:eventID];
    CHECK(event && [[event title] isEqual:@"Offline invitation"]);
    CHECK([[event attendees] count]==0 && [event organizer]==nil);
    SyncCalendar(store,NO,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    CHECK(Count(j,"SELECT count(*) FROM two_way_attention")==0);
    puts("PASS: Invitation imports without native participants; one-way and switching to two-way queue no writes");

    // Reopen the journal as after a daemon restart, then edit supported fields.
    RCCalendarStoreClose(store); store=NULL;
    store=RCCalendarStoreOpen([path fileSystemRepresentation],"offline-invitation-test",&error); CHECK(store);
    j=RCCalendarStoreWriteJournal(store);
    [event setTitle:@"Locally edited invitation"]; [event setLocation:nil];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    long long operation=0; CHECK(RCWriteJournalNext(&j,2000000000,&operation,&error)); CHECK(operation>0);
    RCWriteOperation o; CHECK(RCWriteJournalGet(&j,operation,&o,&error));
    NSString *expected=[[body stringByReplacingOccurrencesOfString:@"SUMMARY:Offline invitation"
        withString:@"SUMMARY:Locally edited invitation"]
        stringByReplacingOccurrencesOfString:@"LOCATION:Original room\r\n" withString:@""];
    CHECK(!strcmp(o.kind,"update") && !strcmp(o.baseETag,"\"invite-1\""));
    CHECK([[NSData dataWithBytes:o.baseBody length:o.baseLength] isEqual:Data(body)]);
    CHECK([[NSData dataWithBytes:o.desiredBody length:o.desiredLength] isEqual:Data(expected)]);
    RCWriteOperationClear(&o);
    NSData *confirmed=ConfirmWrite(j); CalendarSeed(store,confirmed,"\"confirmed\"");
    SyncCalendar(store,YES,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    CHECK(Count(j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    puts("PASS: Invitation edits preserve exact attendee/organizer lines, parameters and folding after reopen and acknowledgement");

    // A remote participant change updates the durable base even though there
    // is no visible native participant change. Later local edits must retain it.
    body=[expected stringByReplacingOccurrencesOfString:@"PARTSTAT=TENTATIVE" withString:@"PARTSTAT=DECLINED"];
    body=[body stringByReplacingOccurrencesOfString:@"END:VEVENT"
        withString:@"ATTENDEE;CN=Fixture Three;PARTSTAT=ACCEPTED:mailto:three@example.invalid\r\nEND:VEVENT"];
    CalendarSeed(store,Data(body),"\"invite-2\""); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    CHECK([[[FirstRow(j) objectForKey:@"resource"] objectForKey:@"body"] isEqual:Data(body)]);

    // Deleting an incomplete local invitation must not delete it from iCloud.
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK(event);
    CHECK([events removeEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    CHECK(Count(j,"SELECT count(*) FROM two_way_attention WHERE reason='unsupported-native-edit'")==1);
    SyncCalendar(store,NO,YES); // Restore the local copy from the retained mirror.
    eventID=[FirstRow(j) objectForKey:@"id"];
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK(event);
    puts("PASS: Local invitation deletion stays pending and never queues a cloud DELETE");

    RCCalendarStoreClose(store); store=NULL;
    store=RCCalendarStoreOpen([path fileSystemRepresentation],"offline-invitation-test",&error); CHECK(store);
    j=RCCalendarStoreWriteJournal(store);
    [event setNotes:@"Second local edit"];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    NSString *newRemote=[body stringByReplacingOccurrencesOfString:@"PARTSTAT=DECLINED" withString:@"PARTSTAT=ACCEPTED"];
    CalendarSeed(store,Data(newRemote),"\"invite-3\""); SyncCalendar(store,YES,NO);
    CHECK(RCWriteJournalNext(&j,2000000000,&operation,&error)); CHECK(operation>0);
    CHECK(RCWriteJournalGet(&j,operation,&o,&error));
    expected=[body stringByReplacingOccurrencesOfString:@"DESCRIPTION:Original notes" withString:@"DESCRIPTION:Second local edit"];
    CHECK(!strcmp(o.baseETag,"\"invite-2\""));
    CHECK([[NSData dataWithBytes:o.baseBody length:o.baseLength] isEqual:Data(body)]);
    CHECK([[NSData dataWithBytes:o.desiredBody length:o.desiredLength] isEqual:Data(expected)]);
    RCWriteOperationClear(&o);
    // Simulate the writer's conditional-write conflict and verification GET.
    CHECK(RCWriteJournalBeginAttempt(&j,operation,2000000000,&error));
    NSData *remote=Data(newRemote);
    CHECK(RCWriteJournalRecordResult(&j,operation,"conflict",200,"\"invite-3\"",[remote bytes],[remote length],&error));
    SyncCalendar(store,YES,NO); SyncCalendar(store,YES,NO);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==2);
    CHECK(RCWriteJournalGet(&j,operation,&o,&error));
    CHECK(!strcmp(o.state,"conflict") && !strcmp(o.baseETag,"\"invite-2\""));
    CHECK([[NSData dataWithBytes:o.desiredBody length:o.desiredLength] isEqual:Data(expected)]);
    RCWriteOperationClear(&o);
    puts("PASS: Remote participant updates survive later edits; concurrent changes retain the immutable ETag base and remain in conflict");
  } @finally {
    if(store) { Cleanup(RCCalendarStoreWriteJournal(store),NO); RCCalendarStoreClose(store); }
  }
}
static void PendingCalendarSave(RCWriteJournal j,NSString *root,BOOL loseIdentity)
{
  NSData *empty=[NSKeyedArchiver archivedDataWithRootObject:[NSDictionary dictionary]];
  sqlite3_stmt *q=NULL;
  CHECK(sqlite3_prepare_v2(j.db,"UPDATE native_store_resources SET pending=1,native=CASE WHEN ? THEN ? ELSE native END,snapshot=CASE WHEN ? THEN ? ELSE snapshot END WHERE account_id=? AND root=?",-1,&q,NULL)==SQLITE_OK);
  sqlite3_bind_int(q,1,loseIdentity); sqlite3_bind_blob(q,2,[empty bytes],[empty length],SQLITE_TRANSIENT);
  sqlite3_bind_int(q,3,loseIdentity); sqlite3_bind_blob(q,4,[empty bytes],[empty length],SQLITE_TRANSIENT);
  sqlite3_bind_int64(q,5,j.account); sqlite3_bind_text(q,6,[root UTF8String],-1,SQLITE_TRANSIENT);
  CHECK(sqlite3_step(q)==SQLITE_DONE); sqlite3_finalize(q);
  CHECK(RCTwoWaySQL(&j,&error,"INSERT OR REPLACE INTO two_way_attention VALUES(%lld,%Q,'native-publication-pending')",j.account,[root UTF8String]));
}
static void ExpectCalendarRecoveryBlocked(RCCalendarStore *store)
{
  long count=0; RCErrorClear(&error);
  BOOL ok=RCNativeSyncCalendars(store,NO,&count,&error);
  BOOL blocked=strstr(error.message,"no unique unchanged native match")!=NULL;
  CHECK(!ok && blocked);
  CHECK(Count(RCCalendarStoreWriteJournal(store),"SELECT count(*) FROM native_store_resources WHERE pending=1")==1);
}
static void AllDayAlarmTests(NSString *directory)
{
  NSString *path=[directory stringByAppendingPathComponent:@"all-day-alarms.sqlite"];
  RCCalendarStore *store=RCCalendarStoreOpen([path fileSystemRepresentation],
      "offline-all-day-test",&error); CHECK(store);
  @try {
    NSString *body=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//rCloud offline//EN\r\n"
        @"BEGIN:VEVENT\r\nUID:offline-all-day\r\nDTSTART;VALUE=DATE:20301012\r\nDTEND;VALUE=DATE:20301019\r\n"
        @"SUMMARY:Offline all-day alarm\r\nBEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT15H\r\n"
        @"ATTACH;VALUE=URI:Basso\r\nX-APPLE-DEFAULT-ALARM:TRUE\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    CalendarSeed(store,Data(body),"\"all-day-1\""); SyncCalendar(store,NO,YES);
    RCWriteJournal j=RCCalendarStoreWriteJournal(store);
    NSDictionary *row=FirstRow(j); CHECK(row);
    EKEventStore *events=[[[EKEventStore alloc] init] autorelease];
    EKEvent *event=[events eventWithIdentifier:[row objectForKey:@"id"]]; CHECK(event);
    CHECK([event isAllDay]); CHECK([[event alarms] count]==1);
    EKAlarm *alarm=[[event alarms] objectAtIndex:0];
    CHECK([alarm type]==EKAlarmTypeAudio && [[alarm soundName] isEqual:@"Basso"]);
    SyncCalendar(store,NO,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    puts("PASS: Multi-day all-day event with a default sound alarm imports and replays without ambiguity");

    NSString *root=[[row objectForKey:@"resource"] objectForKey:@"root"];
    NSString *eventID=[row objectForKey:@"id"];
    NSPredicate *predicate=[events predicateForEventsWithStartDate:[[event startDate] dateByAddingTimeInterval:-1]
        endDate:[[event endDate] dateByAddingTimeInterval:1] calendars:[NSArray arrayWithObject:[event calendar]]];
    // Reproduce the previous release: a fresh equivalent alarm enables both
    // the implicit all-day default and its explicit copy, then readback fails
    // before the event identifier and snapshot have reached the journal.
    EKAlarm *replacement=[EKAlarm alarmWithRelativeOffset:-54000]; [replacement setSoundName:@"Basso"];
    [event setAlarms:[NSArray arrayWithObject:replacement]];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event alarms] count]==2);
    PendingCalendarSave(j,root,YES);
    RCCalendarStoreClose(store); store=NULL;
    store=RCCalendarStoreOpen([path fileSystemRepresentation],"offline-all-day-test",&error); CHECK(store);
    j=RCCalendarStoreWriteJournal(store);
    SyncCalendar(store,NO,YES); SyncCalendar(store,NO,YES);
    CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:eventID]);
    CHECK(Count(j,"SELECT count(*) FROM native_store_resources WHERE pending=1")==0);
    CHECK(Count(j,"SELECT count(*) FROM two_way_attention")==0);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event alarms] count]==1);
    CHECK([[events eventsMatchingPredicate:predicate] count]==1);
    puts("PASS: Legacy all-day save with lost identity recovers its unique event, removes the duplicate and replays without creation");

    [event setTitle:@"Edited all-day alarm"]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    NSString *edited=[body stringByReplacingOccurrencesOfString:@"SUMMARY:Offline all-day alarm" withString:@"SUMMARY:Edited all-day alarm"];
    NSData *confirmed=ConfirmWrite(j); CHECK([confirmed isEqual:Data(edited)]);
    CalendarSeed(store,confirmed,"\"confirmed\""); SyncCalendar(store,YES,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    [events reset]; event=[events eventWithIdentifier:eventID];
    PendingCalendarSave(j,root,NO);
    [event setTitle:@"Unacknowledged local edit"]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    ExpectCalendarRecoveryBlocked(store);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event title] isEqual:@"Unacknowledged local edit"]);
    [event setTitle:@"Edited all-day alarm"]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,NO,YES);
    puts("PASS: Recovered all-day event edits retain the original alarm bytes; pending recovery never overwrites a newer local edit");

    // An otherwise exact candidate already owned by another resource must
    // never be adopted for a pending save whose original identity was lost.
    NSData *otherIDs=[NSKeyedArchiver archivedDataWithRootObject:
        [NSDictionary dictionaryWithObject:eventID forKey:@"other-offline-event"]];
    sqlite3_stmt *owner=NULL;
    CHECK(sqlite3_prepare_v2(j.db,"INSERT INTO native_store_resources SELECT account_id,'other-offline-event',resource,?,snapshot,0 FROM native_store_resources WHERE account_id=? AND root=?",-1,&owner,NULL)==SQLITE_OK);
    sqlite3_bind_blob(owner,1,[otherIDs bytes],[otherIDs length],SQLITE_TRANSIENT);
    sqlite3_bind_int64(owner,2,j.account); sqlite3_bind_text(owner,3,[root UTF8String],-1,SQLITE_TRANSIENT);
    CHECK(sqlite3_step(owner)==SQLITE_DONE); sqlite3_finalize(owner);
    PendingCalendarSave(j,root,YES); ExpectCalendarRecoveryBlocked(store);
    CHECK(sqlite3_exec(j.db,"DELETE FROM native_store_resources WHERE root='other-offline-event'",NULL,NULL,NULL)==SQLITE_OK);
    SyncCalendar(store,NO,YES); CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:eventID]);
    puts("PASS: Recovery refuses an event already owned by another resource");

    EKEvent *twin=[EKEvent eventWithEventStore:events];
    [twin setCalendar:[event calendar]]; [twin setAllDay:YES]; [twin setTitle:[event title]];
    [twin setStartDate:[event startDate]]; [twin setEndDate:[event endDate]];
    replacement=[EKAlarm alarmWithRelativeOffset:-54000]; [replacement setSoundName:@"Basso"];
    [twin setAlarms:[NSArray arrayWithObject:replacement]];
    CHECK([events saveEvent:twin span:EKSpanFutureEvents commit:YES error:NULL]);
    NSString *twinID=[twin eventIdentifier];
    PendingCalendarSave(j,root,YES); ExpectCalendarRecoveryBlocked(store);
    [events reset]; CHECK([[events eventsMatchingPredicate:predicate] count]==2);
    twin=[events eventWithIdentifier:twinID]; CHECK(twin);
    CHECK([events removeEvent:twin span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,NO,YES); CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:eventID]);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK(event);
    PendingCalendarSave(j,root,YES);
    CHECK([events removeEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    ExpectCalendarRecoveryBlocked(store);
    [events reset]; CHECK([[events eventsMatchingPredicate:predicate] count]==0);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    puts("PASS: Missing and multiple all-day recovery candidates stay pending without new events or uploads");
  } @finally {
    if(store) { Cleanup(RCCalendarStoreWriteJournal(store),NO); RCCalendarStoreClose(store); }
  }
}
static NSDictionary *CalendarSnapshot(RCWriteJournal j,NSString *root)
{
  sqlite3_stmt *q=NULL;
  CHECK(sqlite3_prepare_v2(j.db,"SELECT snapshot FROM native_store_resources WHERE account_id=? AND root=?",-1,&q,NULL)==SQLITE_OK);
  sqlite3_bind_int64(q,1,j.account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
  CHECK(sqlite3_step(q)==SQLITE_ROW);
  NSDictionary *snapshot=[NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(q,0) length:sqlite3_column_bytes(q,0)]];
  sqlite3_finalize(q); return snapshot;
}
static void LegacyDisplaySnapshot(RCWriteJournal j,NSString *root)
{
  NSDictionary *resource=[FirstRow(j) objectForKey:@"resource"];
  NSArray *keys=[[[resource objectForKey:@"graph"] objectForKey:root] objectForKey:@"display alarms"];
  if(!keys) keys=[NSArray array];
  NSDictionary *current=CalendarSnapshot(j,root);
  NSString *extra=[root stringByAppendingFormat:@"/alarm/%lu",(unsigned long)[keys count]];
  NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:[current objectForKey:root]];
  [event setObject:[keys arrayByAddingObject:extra] forKey:@"display alarms"];
  [event setObject:[NSArray array] forKey:@"audio alarms"];
  // The old ordinal mapper classified the implicit audio default as display
  // and assigned it to the second source key, shifting that reminder to /2.
  NSMutableDictionary *old=[NSMutableDictionary dictionaryWithObject:event forKey:root];
  if([keys count]==2) {
    [old setObject:[current objectForKey:[keys objectAtIndex:0]] forKey:[keys objectAtIndex:0]];
    [old setObject:[current objectForKey:[keys objectAtIndex:0]] forKey:[keys objectAtIndex:1]];
    [old setObject:[current objectForKey:[keys objectAtIndex:1]] forKey:extra];
  } else {
    NSString *audio=[[[current objectForKey:root] objectForKey:@"audio alarms"] objectAtIndex:0];
    NSMutableDictionary *defaultAlarm=[NSMutableDictionary dictionaryWithDictionary:[current objectForKey:audio]];
    [defaultAlarm setObject:@"com.apple.calendars.DisplayAlarm" forKey:@"com.apple.syncservices.RecordEntityName"];
    [defaultAlarm removeObjectForKey:@"com.apple.ical.sound"];
    [old setObject:defaultAlarm forKey:[keys count] ? [keys objectAtIndex:0] : extra];
    if([keys count]) [old setObject:[current objectForKey:[keys objectAtIndex:0]] forKey:extra];
  }
  NSData *data=[NSKeyedArchiver archivedDataWithRootObject:old]; sqlite3_stmt *q=NULL;
  CHECK(sqlite3_prepare_v2(j.db,"UPDATE native_store_resources SET snapshot=? WHERE account_id=? AND root=?",-1,&q,NULL)==SQLITE_OK);
  sqlite3_bind_blob(q,1,[data bytes],[data length],SQLITE_TRANSIENT);
  sqlite3_bind_int64(q,2,j.account); sqlite3_bind_text(q,3,[root UTF8String],-1,SQLITE_TRANSIENT);
  CHECK(sqlite3_step(q)==SQLITE_DONE); sqlite3_finalize(q);
}
static void LegacyDefaultDisplayTests(NSString *directory,NSUInteger reminders)
{
  NSString *account=[NSString stringWithFormat:@"offline-legacy-%lu-display-test",(unsigned long)reminders];
  NSString *path=[directory stringByAppendingPathComponent:[account stringByAppendingString:@".sqlite"]];
  RCCalendarStore *store=RCCalendarStoreOpen([path fileSystemRepresentation],[account UTF8String],&error); CHECK(store);
  @try {
    NSString *body=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//rCloud offline//EN\r\n"
        @"BEGIN:VEVENT\r\nUID:offline-legacy-display\r\nDTSTART;VALUE=DATE:20301012\r\nDTEND;VALUE=DATE:20301013\r\n"
        @"SUMMARY:Offline legacy reminders\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15H\r\n"
        @"DESCRIPTION:First reminder\r\nX-PRIVATE-ALARM:first\r\nEND:VALARM\r\n"
        @"BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-P6DT15H\r\nDESCRIPTION:Second reminder\r\n"
        @"X-PRIVATE-ALARM:second\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    if(reminders<2) {
      body=[body stringByReplacingOccurrencesOfString:@"BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-P6DT15H\r\nDESCRIPTION:Second reminder\r\nX-PRIVATE-ALARM:second\r\nEND:VALARM\r\n" withString:@""];
      body=[body stringByReplacingOccurrencesOfString:@"TRIGGER:-PT15H" withString:@"TRIGGER:-PT10M"];
    }
    if(!reminders) {
      NSRange alarm=[body rangeOfString:@"BEGIN:VALARM"];
      NSRange end=[body rangeOfString:@"END:VALARM\r\n"];
      CHECK(alarm.location!=NSNotFound && end.location!=NSNotFound);
      body=[body stringByReplacingCharactersInRange:NSMakeRange(alarm.location,NSMaxRange(end)-alarm.location) withString:@""];
    }
    CalendarSeed(store,Data(body),"\"legacy-display-1\""); SyncCalendar(store,NO,YES);
    RCWriteJournal j=RCCalendarStoreWriteJournal(store);
    NSDictionary *row=FirstRow(j); NSString *root=[[row objectForKey:@"resource"] objectForKey:@"root"], *eventID=[row objectForKey:@"id"];
    EKEventStore *events=[[[EKEventStore alloc] init] autorelease]; EKEvent *event=[events eventWithIdentifier:eventID];
    CHECK(event && [[event alarms] count]==reminders+1);
    LegacyDisplaySnapshot(j,root); SyncCalendar(store,NO,YES);
    CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:eventID]);
    RCCalendarStoreClose(store); store=RCCalendarStoreOpen([path fileSystemRepresentation],[account UTF8String],&error); CHECK(store);
    j=RCCalendarStoreWriteJournal(store);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event alarms] count]==reminders+1);
    [event setAlarms:[[[event alarms] reverseObjectEnumerator] allObjects]];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,NO,YES); SyncCalendar(store,YES,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    puts("PASS: Legacy misidentified display reminders recover without changing native alarms, creating events or uploading the implicit default");

    [events reset]; event=[events eventWithIdentifier:eventID]; [event setTitle:@"Edited legacy reminders"];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    NSData *confirmed=ConfirmWrite(j);
    CHECK([confirmed isEqual:Data([body stringByReplacingOccurrencesOfString:@"SUMMARY:Offline legacy reminders" withString:@"SUMMARY:Edited legacy reminders"])]);
    CalendarSeed(store,confirmed,"\"confirmed\""); SyncCalendar(store,YES,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    puts("PASS: Edits after legacy alarm recovery retain exact source reminders and never add a default audio alarm to the wire body");

    LegacyDisplaySnapshot(j,root);
    [events reset]; event=[events eventWithIdentifier:eventID]; [event setTitle:@"Newer local edit"];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    long count=0; RCErrorClear(&error); BOOL ok=RCNativeSyncCalendars(store,YES,&count,&error);
    CHECK(!ok); CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event title] isEqual:@"Newer local edit"]);
    [event setTitle:@"Edited legacy reminders"]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,YES);
    puts("PASS: Legacy snapshot recovery refuses a changed event and preserves its newer local edit");
    if(reminders==2) {
      NSTimeInterval original=-572400;
      EKAlarmType type=EKAlarmTypeDisplay;
      LegacyDisplaySnapshot(j,root);
      [events reset]; event=[events eventWithIdentifier:eventID];
      NSMutableArray *alarms=[NSMutableArray arrayWithArray:[event alarms]];
      for(NSUInteger n=0;n<[alarms count];n++) if([(EKAlarm *)[alarms objectAtIndex:n] type]==type && [[alarms objectAtIndex:n] relativeOffset]==original) {
        EKAlarm *alarm=[[[alarms objectAtIndex:n] copy] autorelease]; [alarm setRelativeOffset:original+300]; [alarms replaceObjectAtIndex:n withObject:alarm];
      }
      [event setAlarms:alarms]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
      RCErrorClear(&error); ok=RCNativeSyncCalendars(store,YES,&count,&error); CHECK(!ok);
      CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
      [events reset]; event=[events eventWithIdentifier:eventID]; BOOL edited=NO;
      alarms=[NSMutableArray arrayWithArray:[event alarms]];
      for(NSUInteger n=0;n<[alarms count];n++) if([(EKAlarm *)[alarms objectAtIndex:n] type]==type && [[alarms objectAtIndex:n] relativeOffset]==original+300) {
        edited=YES; EKAlarm *alarm=[[[alarms objectAtIndex:n] copy] autorelease]; [alarm setRelativeOffset:original]; [alarms replaceObjectAtIndex:n withObject:alarm];
      }
      [event setAlarms:alarms]; CHECK(edited); CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
      SyncCalendar(store,YES,YES);
      puts("PASS: Legacy receipt repair refuses a changed alarm and leaves its native edit intact");
    } else if(!reminders) {
      LegacyDisplaySnapshot(j,root);
      [events reset]; event=[events eventWithIdentifier:eventID];
      [event addAlarm:[EKAlarm alarmWithRelativeOffset:-300]];
      CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
      [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event alarms] count]==2);
      RCErrorClear(&error); ok=RCNativeSyncCalendars(store,YES,&count,&error); CHECK(!ok);
      CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
      [events reset]; event=[events eventWithIdentifier:eventID];
      NSMutableArray *alarms=[NSMutableArray arrayWithArray:[event alarms]]; BOOL edited=NO;
      for(EKAlarm *alarm in [event alarms]) if([alarm type]==EKAlarmTypeDisplay && [alarm relativeOffset]==-300) {
        edited=YES; [alarms removeObject:alarm];
      }
      CHECK(edited); CHECK([[event alarms] count]==2);
      [event setAlarms:alarms]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
      SyncCalendar(store,YES,YES);
      puts("PASS: Legacy default-only receipt repair refuses and preserves a newly added local reminder");
    }

    [events reset]; event=[events eventWithIdentifier:eventID];
    [event addAlarm:[EKAlarm alarmWithRelativeOffset:-300]];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    [events reset]; event=[events eventWithIdentifier:eventID];
    [event setAlarms:[[[event alarms] reverseObjectEnumerator] allObjects]];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    confirmed=ConfirmWrite(j);
    NSString *updated=[[[NSString alloc] initWithData:confirmed encoding:NSUTF8StringEncoding] autorelease];
    CHECK([[updated componentsSeparatedByString:@"ACTION:DISPLAY"] count]==reminders+2);
    CHECK([updated rangeOfString:@"ACTION:AUDIO"].location==NSNotFound);
    CHECK(!reminders || [updated rangeOfString:@"X-PRIVATE-ALARM:first"].location!=NSNotFound);
    CHECK(reminders<2 || [updated rangeOfString:@"X-PRIVATE-ALARM:second"].location!=NSNotFound);
    CalendarSeed(store,confirmed,"\"confirmed-2\""); SyncCalendar(store,YES,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==2);
    puts("PASS: Adding a real local reminder uploads that reminder without copying the unchanged native-only Basso default");

  } @finally {
    if(store) { Cleanup(RCCalendarStoreWriteJournal(store),NO); RCCalendarStoreClose(store); }
  }
}
static void AudioAlarmTests(NSString *directory)
{
  NSString *path=[directory stringByAppendingPathComponent:@"audio-alarms.sqlite"];
  RCCalendarStore *store=RCCalendarStoreOpen([path fileSystemRepresentation],
      "offline-audio-test",&error); CHECK(store);
  @try {
    RCWriteJournal j=RCCalendarStoreWriteJournal(store);
    NSString *body=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//rCloud offline//EN\r\n"
        @"BEGIN:VEVENT\r\nUID:offline-audio\r\nDTSTART:20301012T090000Z\r\nDTEND:20301012T100000Z\r\n"
        @"SUMMARY:Offline sound alarms\r\nDESCRIPTION:Original notes\r\nRRULE:FREQ=YEARLY;COUNT=3\r\n"
        @"BEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT10M\r\n"
        @"ATTACH;FMTTYPE=audio/basic:file://localhost/System/Library/Sounds/Glass.aiff\r\nEND:VALARM\r\n"
        @"BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nDESCRIPTION:Display reminder\r\nEND:VALARM\r\n"
        @"BEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER;VALUE=DATE-TIME:20301012T080000Z\r\n"
        @"ATTACH;VALUE=URI:https://fixture.invalid/custom-tone.aiff\r\nX-PRIVATE-ALARM:keep\r\nEND:VALARM\r\n"
        @"BEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT5M\r\nEND:VALARM\r\n"
        @"BEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT30M\r\nATTACH;VALUE=URI:Ping\r\nEND:VALARM\r\n"
        @"END:VEVENT\r\nEND:VCALENDAR\r\n";
    CalendarSeed(store,Data(body),"\"audio-1\""); SyncCalendar(store,NO,YES);
    NSString *eventID=[FirstRow(j) objectForKey:@"id"]; CHECK(eventID);
    EKEventStore *events=[[[EKEventStore alloc] init] autorelease];
    EKEvent *event=[events eventWithIdentifier:eventID]; CHECK(event);
    CHECK([[event alarms] count]==5 && [[event recurrenceRules] count]==1);
    int audio=0,display=0;
    for(EKAlarm *alarm in [event alarms]) {
      if([alarm type]==EKAlarmTypeDisplay) { display++; CHECK([alarm relativeOffset]==-900); }
      else {
        CHECK([alarm type]==EKAlarmTypeAudio); audio++;
        if([alarm absoluteDate]) {
          CHECK([[alarm absoluteDate] isEqual:[NSCalendarDate dateWithYear:2030 month:10 day:12 hour:8 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]]]);
          CHECK([[alarm soundName] isEqual:@"Basso"]);
        } else if([alarm relativeOffset]==-600) CHECK([[alarm soundName] isEqual:@"Glass"]);
        else if([alarm relativeOffset]==-1800) CHECK([[alarm soundName] isEqual:@"Ping"]);
        else { CHECK([alarm relativeOffset]==-300); CHECK([[alarm soundName] isEqual:@"Basso"]); }
      }
    }
    CHECK(audio==4 && display==1);
    SyncCalendar(store,NO,YES); CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:eventID]);
    puts("PASS: Recurring one-way events import mixed display/audio alarms, named and file sounds, absolute triggers and default/custom fallbacks");

    body=[body stringByReplacingOccurrencesOfString:@"RRULE:FREQ=YEARLY;COUNT=3\r\n" withString:@""];
    CalendarSeed(store,Data(body),"\"audio-2\""); SyncCalendar(store,NO,YES);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK(event);
    [event setAlarms:[[[event alarms] reverseObjectEnumerator] allObjects]];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,YES); CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    RCCalendarStoreClose(store); store=NULL;
    store=RCCalendarStoreOpen([path fileSystemRepresentation],"offline-audio-test",&error); CHECK(store);
    j=RCCalendarStoreWriteJournal(store);
    [event setNotes:@"Edited notes"]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    NSString *expected=[body stringByReplacingOccurrencesOfString:@"DESCRIPTION:Original notes" withString:@"DESCRIPTION:Edited notes"];
    NSData *confirmed=ConfirmWrite(j); CHECK([confirmed isEqual:Data(expected)]);
    CalendarSeed(store,confirmed,"\"confirmed\""); SyncCalendar(store,YES,YES); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==1);
    CHECK(Count(j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    puts("PASS: Alarm reordering, database reopen and event edits preserve original attachment bytes and absent default ATTACH across acknowledgement/replay");

    // Changing the locally chosen fallback is a real user edit; only that
    // alarm's attachment may change, not the other audio or display alarms.
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK(event);
    NSMutableArray *alarms=[NSMutableArray arrayWithArray:[event alarms]]; BOOL changed=NO;
    for(NSUInteger n=0;n<[alarms count];n++) if([[alarms objectAtIndex:n] absoluteDate]) {
      EKAlarm *alarm=[[[alarms objectAtIndex:n] copy] autorelease]; [alarm setSoundName:@"Glass"];
      [alarms replaceObjectAtIndex:n withObject:alarm]; changed=YES;
    }
    CHECK(changed); [event setAlarms:alarms]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO);
    expected=[expected stringByReplacingOccurrencesOfString:@"https://fixture.invalid/custom-tone.aiff"
        withString:@"file:///System/Library/Sounds/Glass.aiff"];
    confirmed=ConfirmWrite(j); CHECK([confirmed isEqual:Data(expected)]);
    CalendarSeed(store,confirmed,"\"confirmed\""); SyncCalendar(store,YES,YES);
    CHECK(Count(j,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==2);
    puts("PASS: Explicit local sound change replaces only the intended attachment and retains its URI parameters");

    // Never silently flatten repeated alarms or guess between identical native
    // projections (different unavailable attachments can share one fallback).
    NSString *unsupported=[expected stringByReplacingOccurrencesOfString:@"TRIGGER:-PT5M\r\n"
        withString:@"TRIGGER:-PT5M\r\nREPEAT:2\r\nDURATION:PT1M\r\n"];
    CalendarSeed(store,Data(unsupported),"\"audio-repeat\""); SyncCalendar(store,NO,NO);
    CHECK([[[FirstRow(j) objectForKey:@"resource"] objectForKey:@"body"] isEqual:Data(expected)]);
    unsupported=[expected stringByReplacingOccurrencesOfString:@"TRIGGER:-PT30M\r\nATTACH;VALUE=URI:Ping"
        withString:@"TRIGGER:-PT5M\r\nATTACH;VALUE=URI:https://fixture.invalid/missing.aiff"];
    CalendarSeed(store,Data(unsupported),"\"audio-duplicate\""); SyncCalendar(store,NO,NO);
    CHECK([[[FirstRow(j) objectForKey:@"resource"] objectForKey:@"body"] isEqual:Data(expected)]);
    CalendarSeed(store,Data(expected),"\"audio-restored\""); SyncCalendar(store,NO,YES);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK(event);
    alarms=[NSMutableArray arrayWithArray:[event alarms]];
    for(NSUInteger n=0;n<[alarms count];n++) if([(EKAlarm *)[alarms objectAtIndex:n] type]==EKAlarmTypeAudio &&
        ![[alarms objectAtIndex:n] absoluteDate]) {
      EKAlarm *alarm=[[[alarms objectAtIndex:n] copy] autorelease];
      [alarm setRelativeOffset:[alarm relativeOffset]-60]; [alarms replaceObjectAtIndex:n withObject:alarm];
    }
    [event setAlarms:alarms]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    long count=0; CHECK(!RCNativeSyncCalendars(store,YES,&count,&error));
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==2);
    puts("PASS: Repeating alarms, duplicate fallback projections and ambiguous multiple alarm edits are held without unsafe uploads");
  } @finally {
    if(store) { Cleanup(RCCalendarStoreWriteJournal(store),NO); RCCalendarStoreClose(store); }
  }
}
int main(int argc,char **argv)
{
  NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init]; setbuf(stdout,NULL); int result=1;
  if(argc==2) {
    NSString *log=[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:@"test.log"];
    freopen([log fileSystemRepresentation],"a",stdout); freopen([log fileSystemRepresentation],"a",stderr); setbuf(stdout,NULL);
  }
  [NSApplication sharedApplication]; extraContacts=[NSMutableArray array];
  RCContactStore *contacts=NULL; RCCalendarStore *calendars=NULL;
  @try {
    CHECK(argc==2); CHECK(!RCUsesNativeStoresForVersion(10,8)); CHECK(RCUsesNativeStoresForVersion(10,9)); CHECK(RCUsesNativeStoresForVersion(11,0)); CHECK(RCUsesNativeStores());
    NSString *directory=[NSString stringWithUTF8String:argv[1]];
    contacts=RCContactStoreOpen([[directory stringByAppendingPathComponent:@"contacts.sqlite"] fileSystemRepresentation],"offline-native-test",&error); CHECK(contacts);
    calendars=RCCalendarStoreOpen([[directory stringByAppendingPathComponent:@"calendars.sqlite"] fileSystemRepresentation],"offline-native-test",&error); CHECK(calendars);
    RCWriteJournal cj=RCContactStoreWriteJournal(contacts),ej=RCCalendarStoreWriteJournal(calendars);
    long count=0; CHECK(!RCNativeSyncContacts(contacts,NO,&count,&error)); CHECK(!RCNativeSyncCalendars(calendars,NO,&count,&error));
    puts("PASS: 10.9 cutoff and incomplete-inventory guards");
    NSString *vcard=@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:offline-native-contact\r\nN:Native;RetroCloud;;;\r\nFN:RetroCloud Native\r\nEMAIL;TYPE=HOME:fixture@example.invalid\r\nTEL;TYPE=CELL:555-0100\r\nNOTE:offline initial\r\nX-PRIVATE-FIXTURE:preserve\r\nEND:VCARD\r\n";
    ContactsSeed(contacts,Data(vcard),"\"c1\"");
    for(int attempt=0;attempt<600;attempt++) {
      RCErrorClear(&error); if(RCNativeSyncContacts(contacts,NO,&count,&error) && count>=0) break;
      if(attempt==0) printf("WAITING FOR CONTACTS ACCESS: %s\n",error.message);
      if(attempt==599) CHECK(NO); [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    }
    NSDictionary *row=FirstRow(cj); CHECK(row); NSString *contactID=[[row objectForKey:@"id"] copy];
    ABAddressBook *book=[ABAddressBook addressBook]; ABPerson *person=(ABPerson *)[book recordForUniqueId:contactID];
    CHECK([[person valueForProperty:kABFirstNameProperty] isEqual:@"RetroCloud"]);
    CHECK([[(ABMultiValue *)[person valueForProperty:kABEmailProperty] valueAtIndex:0] isEqual:@"fixture@example.invalid"]);
    SyncContacts(contacts,NO,YES); CHECK([[[FirstRow(cj) objectForKey:@"id"] description] isEqual:contactID]);
    vcard=[vcard stringByReplacingOccurrencesOfString:@"offline initial" withString:@"remote update"];
    ContactsSeed(contacts,Data(vcard),"\"c2\""); SyncContacts(contacts,NO,YES);
    book=[ABAddressBook addressBook]; person=(ABPerson *)[book recordForUniqueId:contactID];
    CHECK([[person valueForProperty:kABNoteProperty] isEqual:@"remote update"]);
    CHECK(Count(cj,"SELECT count(*) FROM write_operations")==0);
    puts("PASS: Contacts create, stable identity, repeat publication, remote update, one-way has no uploads");
    CHECK([person setValue:@"local update" forProperty:kABNoteProperty]); CHECK([book save]);
    SyncContacts(contacts,YES,NO); CHECK(Count(cj,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    SyncContacts(contacts,YES,NO); CHECK(Count(cj,"SELECT count(*) FROM write_operations")==1);
    NSData *confirmed=ConfirmWrite(cj); CHECK([[[[NSString alloc] initWithData:confirmed encoding:NSUTF8StringEncoding] autorelease] rangeOfString:@"X-PRIVATE-FIXTURE:preserve"].location!=NSNotFound);
    ContactsSeed(contacts,confirmed,"\"confirmed\""); SyncContacts(contacts,YES,YES);
    CHECK(Count(cj,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    SyncContacts(contacts,YES,YES); CHECK(Count(cj,"SELECT count(*) FROM write_operations")==1);
    puts("PASS: Contacts local edit, immutable upload, acknowledgement and replay without duplicate writes");
    NSString *ical=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//rCloud offline//EN\r\nBEGIN:VEVENT\r\nUID:offline-native-event\r\nDTSTART:20261012T090000Z\r\nDTEND:20261012T100000Z\r\nSUMMARY:rCloud Offline Event\r\nDESCRIPTION:offline initial\r\nRRULE:FREQ=DAILY;COUNT=3\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT10M\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nX-PRIVATE-FIXTURE:preserve\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    CalendarSeed(calendars,Data(ical),"\"e1\"");
    for(int attempt=0;attempt<600;attempt++) {
      RCErrorClear(&error); if(RCNativeSyncCalendars(calendars,NO,&count,&error) && count>=0) break;
      if(attempt==0) printf("WAITING FOR CALENDAR ACCESS: %s\n",error.message);
      if(attempt==599) CHECK(NO); [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    }
    AllDayAlarmTests(directory); LegacyDefaultDisplayTests(directory,2); LegacyDefaultDisplayTests(directory,1); LegacyDefaultDisplayTests(directory,0);
    row=FirstRow(ej); CHECK(row); NSString *eventID=[[row objectForKey:@"id"] copy];
    EKEventStore *events=[[[EKEventStore alloc] init] autorelease];
    EKEvent *event=[events eventWithIdentifier:eventID]; CHECK(event); CHECK([[event title] isEqual:@"rCloud Offline Event"]);
    CHECK([[event recurrenceRules] count]==1 && [[event alarms] count]==1);
    NSString *calendarID=[[[event calendar] calendarIdentifier] copy];
    SyncCalendar(calendars,NO,YES); CHECK([[FirstRow(ej) objectForKey:@"id"] isEqual:eventID]);
    ical=[ical stringByReplacingOccurrencesOfString:@"offline initial" withString:@"remote update"];
    CalendarSeed(calendars,Data(ical),"\"e2\""); SyncCalendar(calendars,NO,YES);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event notes] isEqual:@"remote update"]);
    CHECK(Count(ej,"SELECT count(*) FROM write_operations")==0);
    puts("PASS: EventKit create, recurring event, alarm, stable identity, remote update and one-way isolation");
    SyncCalendar(calendars,YES,NO); // Series cannot be fully read back via EventKit.
    CHECK(Count(ej,"SELECT count(*) FROM write_operations")==0);
    ical=[ical stringByReplacingOccurrencesOfString:@"RRULE:FREQ=DAILY;COUNT=3\r\n" withString:@""];
    CalendarSeed(calendars,Data(ical),"\"e3\""); SyncCalendar(calendars,NO,YES);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK(event);
    [event setNotes:@"local update"]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(calendars,YES,NO); CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    confirmed=ConfirmWrite(ej); CalendarSeed(calendars,confirmed,"\"confirmed\""); SyncCalendar(calendars,YES,YES);
    CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    SyncCalendar(calendars,YES,YES); CHECK(Count(ej,"SELECT count(*) FROM write_operations")==1);
    puts("PASS: EventKit local edit, verified acknowledgement and replay without duplicate uploads");
    ContactsSeed(contacts,nil,NULL); SyncContacts(contacts,NO,YES);
    CalendarSeed(calendars,nil,NULL); SyncCalendar(calendars,NO,YES);
    CHECK([[ABAddressBook addressBook] recordForUniqueId:contactID]==nil); [events reset]; CHECK([events eventWithIdentifier:eventID]==nil);
    [contactID release]; [eventID release];
    puts("PASS: Remote deletions remove only owned native records");
    // New records are adopted atomically with their queued create, including
    // their stable href. A second exchange must not queue a second create.
    sqlite3_stmt *groupQuery=NULL;
    CHECK(sqlite3_prepare_v2(cj.db,"SELECT native FROM native_store_resources WHERE root='@contacts'",-1,&groupQuery,NULL)==SQLITE_OK);
    CHECK(sqlite3_step(groupQuery)==SQLITE_ROW);
    NSDictionary *groupIDs=[NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(groupQuery,0) length:sqlite3_column_bytes(groupQuery,0)]];
    sqlite3_finalize(groupQuery);
    book=[ABAddressBook addressBook]; ABGroup *group=(ABGroup *)[book recordForUniqueId:[groupIDs objectForKey:@"@contacts"]]; CHECK(group);
    person=[[[ABPerson alloc] init] autorelease];
    CHECK([person setValue:@"RetroCloud New Offline" forProperty:kABFirstNameProperty]);
    CHECK([book addRecord:person]); [extraContacts addObject:[person uniqueId]];
    CHECK([group addMember:person]); CHECK([book save]);
    SyncContacts(contacts,YES,NO);
    CHECK(Count(cj,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    SyncContacts(contacts,YES,NO);
    CHECK(Count(cj,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    [events reset]; EKCalendar *calendar=[events calendarWithIdentifier:calendarID]; CHECK(calendar);
    event=[EKEvent eventWithEventStore:events]; [event setCalendar:calendar]; [event setTitle:@"rCloud New Offline Event"];
    [event setStartDate:[NSDate dateWithTimeIntervalSince1970:1791795600]];
    [event setEndDate:[NSDate dateWithTimeIntervalSince1970:1791799200]];
    EKAlarm *newAlarm=[EKAlarm alarmWithRelativeOffset:-600]; [newAlarm setSoundName:@"Glass"];
    [event addAlarm:newAlarm];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(calendars,YES,NO);
    CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    long long newOperation=0; CHECK(RCWriteJournalNext(&ej,2000000000,&newOperation,&error)); CHECK(newOperation>0);
    RCWriteOperation newWrite; CHECK(RCWriteJournalGet(&ej,newOperation,&newWrite,&error));
    CHECK(!strcmp(newWrite.kind,"create"));
    NSString *newBody=[[[NSString alloc] initWithBytes:newWrite.desiredBody length:newWrite.desiredLength encoding:NSUTF8StringEncoding] autorelease];
    CHECK([newBody rangeOfString:@"ACTION:AUDIO"].location!=NSNotFound);
    CHECK([newBody rangeOfString:@"Glass.aiff"].location!=NSNotFound);
    RCWriteOperationClear(&newWrite);
    SyncCalendar(calendars,YES,NO);
    CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    [calendarID release];
    puts("PASS: Locally created contacts/events queue once across repeated exchanges");
    InvitationTests(directory); AudioAlarmTests(directory); result=0;
  } @catch(NSException *exception) { fprintf(stderr,"FAIL: %s\n",[[exception reason] UTF8String]); }
  @try { if(contacts) Cleanup(RCContactStoreWriteJournal(contacts),YES); if(calendars) Cleanup(RCCalendarStoreWriteJournal(calendars),NO); }
  @catch(NSException *exception) { fprintf(stderr,"Cleanup needs retry: %s\n",[[exception name] UTF8String]); result=1; }
  RCContactStoreClose(contacts); RCCalendarStoreClose(calendars);
  if(!result) puts("PASS: Native store offline suite; disposable contacts, events and containers removed");
  [pool release]; return result;
}
