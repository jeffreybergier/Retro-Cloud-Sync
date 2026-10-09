#import <Foundation/Foundation.h>
#import <AddressBook/AddressBook.h>
#import <EventKit/EventKit.h>
#import "RCIOSAccess.h"
#import "RCIOSNativeBackend.h"
#import "RCTwoWayNative.h"
#import "RCPlatformDate.h"
#include <stdio.h>
#include "RCICloudCredentials.h"
#include <unistd.h>
static RCError error;
#define CHECK(x) do { RCErrorClear(&error); if(!(x)) [NSException raise:@"TestFailure" format:@"line %d: %s: %s",__LINE__,#x,error.message]; } while(0)
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
static NSData *ConfirmWrite(RCWriteJournal j)
{
  long long operation=0; CHECK(RCWriteJournalNext(&j,2000000000,&operation,&error)); CHECK(operation>0);
  RCWriteOperation o; CHECK(RCWriteJournalGet(&j,operation,&o,&error));
  NSData *body=o.desiredBody ? [NSData dataWithBytes:o.desiredBody length:o.desiredLength] : nil;
  CHECK(RCWriteJournalBeginAttempt(&j,operation,2000000000,&error));
  CHECK(RCWriteJournalRecordResult(&j,operation,"applied",body ? 200 : 404,body ? "\"confirmed\"" : NULL,[body bytes],[body length],&error));
  RCWriteOperationClear(&o); return body;
}
static void SyncContacts(RCContactStore *store,BOOL twoWay,BOOL full) {
  long count=0; CHECK(RCCurrentSyncBackend()->syncContacts(store,NULL,twoWay,&count,&error)); CHECK(full ? count>=0 : count<0);
}
static void SyncCalendar(RCCalendarStore *store,BOOL twoWay,BOOL full) {
  long count=0; CHECK(RCCurrentSyncBackend()->syncCalendars(store,NULL,twoWay,&count,&error)); CHECK(full ? count>=0 : count<0);
}
static id Value(ABRecordRef r,ABPropertyID p) { return r ? [(id)ABRecordCopyValue(r,p) autorelease] : nil; }
static NSData *ContactsSnapshot(void) {
  ABAddressBookRef book=RCIOSCreateAddressBook(NULL); CHECK(book);
  CFArrayRef people=ABAddressBookCopyArrayOfAllPeople(book);
  CFDataRef data=ABPersonCreateVCardRepresentationWithPeople(people);
  NSData *result=[(id)data autorelease]; CFRelease(people); CFRelease(book); return result;
}
static void Cleanup(RCWriteJournal j,BOOL contacts) {
  sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(j.db,"SELECT root,native FROM native_store_resources WHERE account_id=?",-1,&q,NULL)!=SQLITE_OK) return;
  sqlite3_bind_int64(q,1,j.account);
  ABAddressBookRef book=contacts ? RCIOSCreateAddressBook(NULL) : NULL;
  EKEventStore *events=contacts ? nil : [[[EKEventStore alloc] init] autorelease];
  NSMutableArray *containers=[NSMutableArray array];
  while(sqlite3_step(q)==SQLITE_ROW) {
    NSString *root=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
    NSDictionary *ids=[NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(q,1) length:sqlite3_column_bytes(q,1)]];
    NSString *identifier=[ids objectForKey:root]; if(!identifier) continue;
    if(contacts && book) {
      ABRecordRef r=[root hasPrefix:@"@"] ? ABAddressBookGetGroupWithRecordID(book,[identifier intValue]) : ABAddressBookGetPersonWithRecordID(book,[identifier intValue]);
      if(r) CHECK(ABAddressBookRemoveRecord(book,r,NULL));
    } else if([root hasPrefix:@"@"]) [containers addObject:identifier];
    else { EKEvent *event=[events eventWithIdentifier:identifier]; if(event) CHECK([events removeEvent:event span:EKSpanFutureEvents commit:YES error:NULL]); }
  }
  sqlite3_finalize(q);
  if(book) { CHECK(ABAddressBookSave(book,NULL)); CFRelease(book); }
  for(NSString *identifier in containers) {
    EKCalendar *calendar=[events calendarWithIdentifier:identifier];
    if(calendar) CHECK([events removeCalendar:calendar commit:YES error:NULL]);
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
static void ExcludedOccurrenceTests(NSString *directory,BOOL allDay)
{
  NSString *account=allDay ? @"offline-date-exclusions" : @"offline-time-exclusions";
  NSString *path=[directory stringByAppendingPathComponent:[account stringByAppendingString:@".sqlite"]];
  RCCalendarStore *store=RCCalendarStoreOpen([path fileSystemRepresentation],[account UTF8String],&error); CHECK(store);
  @try {
    NSString *dates=allDay ? @"DTSTART;VALUE=DATE:20301012\r\nDTEND;VALUE=DATE:20301013\r\nEXDATE;VALUE=DATE:20301013,\r\n 20301014\r\n" :
        @"DTSTART;TZID=Asia/Tokyo:20301012T090000\r\nDTEND;TZID=Asia/Tokyo:20301012T100000\r\nEXDATE;TZID=Asia/Tokyo:20301013T090000,\r\n 20301014T090000\r\n";
    NSString *body=[NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//rCloud offline//EN\r\nBEGIN:VEVENT\r\nUID:offline-exclusions\r\n%@SUMMARY:Offline excluded occurrences\r\nRRULE:FREQ=DAILY;COUNT=4\r\nX-PRIVATE-FIXTURE:preserve\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",dates];
    if(!allDay) body=[body stringByReplacingOccurrencesOfString:@"BEGIN:VEVENT"
        withString:@"BEGIN:VTIMEZONE\r\nTZID:Asia/Tokyo\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0900\r\nTZOFFSETTO:+0900\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT"];
    CalendarSeed(store,Data(body),"\"exclusions-1\""); SyncCalendar(store,NO,YES);
    RCWriteJournal j=RCCalendarStoreWriteJournal(store); NSDictionary *row=FirstRow(j);
    NSString *root=[[row objectForKey:@"resource"] objectForKey:@"root"], *eventID=[row objectForKey:@"id"];
    NSDictionary *resource=[row objectForKey:@"resource"];
    CHECK([[[resource objectForKey:@"graph"] objectForKey:root] objectForKey:@"exception dates"]);
    CHECK([[[[resource objectForKey:@"graph"] objectForKey:root] objectForKey:@"exception dates"] count]==2);
    CHECK([[resource objectForKey:@"body"] isEqual:Data(body)]);
    CHECK([[[CalendarSnapshot(j,root) objectForKey:root] objectForKey:@"exception dates"] count]==0);
    EKEventStore *events=[[[EKEventStore alloc] init] autorelease]; EKEvent *event=[events eventWithIdentifier:eventID];
    CHECK(event && [[event recurrenceRules] count]==1);
    NSPredicate *predicate=[events predicateForEventsWithStartDate:[[event startDate] dateByAddingTimeInterval:-86400]
        endDate:[[event startDate] dateByAddingTimeInterval:5*86400] calendars:[NSArray arrayWithObject:[event calendar]]];
    CHECK([[events eventsMatchingPredicate:predicate] count]==4);
    SyncCalendar(store,NO,YES); CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:eventID]);
    CHECK(Count(j,"SELECT count(*) FROM two_way_attention")==0);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    RCCalendarStoreClose(store); store=RCCalendarStoreOpen([path fileSystemRepresentation],[account UTF8String],&error); CHECK(store);
    j=RCCalendarStoreWriteJournal(store); SyncCalendar(store,NO,YES);
    CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:eventID]);
    printf("PASS: %s EXDATE series imports all native occurrences, preserves exact exclusions and replays after reopen without duplicate events\n",allDay ? "All-day" : "Time-zone");

    // Recurring-series writes remain blocked, including supported title edits.
    // A master-only native copy cannot prove edits to excluded occurrences.
    [events reset]; event=[events eventWithIdentifier:eventID]; [event setTitle:@"Local excluded-series edit"];
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO); SyncCalendar(store,YES,NO);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    CHECK(Count(j,"SELECT count(*) FROM two_way_attention WHERE reason='native-series-needs-review'")==1);
    CHECK([[[FirstRow(j) objectForKey:@"resource"] objectForKey:@"body"] isEqual:Data(body)]);
    [events reset]; event=[events eventWithIdentifier:eventID]; CHECK([[event title] isEqual:@"Local excluded-series edit"]);
    CHECK([events removeEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(store,YES,NO); CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    CHECK([[[FirstRow(j) objectForKey:@"resource"] objectForKey:@"body"] isEqual:Data(body)]);
    puts("PASS: Local series edits/deletions stay pending and never upload EXDATE removal or delete the cloud series");

    // A new remote exclusion set must replace the retained base, even though
    // neither set is represented in the native copy.
    NSString *updated=[body stringByReplacingOccurrencesOfString:allDay ? @"20301014\r\n" : @"20301014T090000\r\n"
        withString:allDay ? @"20301015\r\n" : @"20301015T090000\r\n"];
    CalendarSeed(store,Data(updated),"\"exclusions-2\""); SyncCalendar(store,NO,YES);
    CHECK([[[FirstRow(j) objectForKey:@"resource"] objectForKey:@"body"] isEqual:Data(updated)]);
    CHECK(Count(j,"SELECT count(*) FROM two_way_attention")==0);
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    SyncCalendar(store,YES,NO); CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    puts("PASS: Remote exclusion updates retain exact folded EXDATE data without generating any cloud writes");
  } @finally {
    if(store) { Cleanup(RCCalendarStoreWriteJournal(store),NO); RCCalendarStoreClose(store); }
  }
}
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

static void ContactRecoveryTests(NSString *directory) {
  RCContactStore *store=RCContactStoreOpen([[directory stringByAppendingPathComponent:@"contact-recovery.sqlite"] fileSystemRepresentation],"ios-contact-recovery",&error); CHECK(store);
  @try {
    ContactsSeed(store,Data(@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ios-recovery\r\nN:Fixture;RetroCloudIOSRecovery;;;\r\nFN:RetroCloudIOSRecovery Fixture\r\nEND:VCARD\r\n"),"\"r1\"");
    SyncContacts(store,NO,YES); RCWriteJournal j=RCContactStoreWriteJournal(store);
    NSString *identifier=[FirstRow(j) objectForKey:@"id"];
    CHECK(RCTwoWaySQL(&j,&error,"UPDATE native_store_resources SET pending=1 WHERE root NOT LIKE '@%%'"));
    long count=0; CHECK(!RCCurrentSyncBackend()->syncContacts(store,NULL,NO,&count,&error));
    CHECK([[FirstRow(j) objectForKey:@"id"] isEqual:identifier]);
    CHECK(RCTwoWaySQL(&j,&error,"UPDATE native_store_resources SET pending=0 WHERE root NOT LIKE '@%%'"));
    sqlite3_stmt *q=NULL; CHECK(sqlite3_prepare_v2(j.db,"SELECT native FROM native_store_resources WHERE root='@contacts'",-1,&q,NULL)==SQLITE_OK);
    CHECK(sqlite3_step(q)==SQLITE_ROW);
    NSDictionary *ids=[NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(q,0) length:sqlite3_column_bytes(q,0)]];
    NSString *groupID=[[ids objectForKey:@"@contacts"] retain]; sqlite3_finalize(q);
    ABAddressBookRef book=RCIOSCreateAddressBook(NULL);
    ABRecordRef group=ABAddressBookGetGroupWithRecordID(book,[groupID intValue]); CHECK(group);
    CHECK(ABAddressBookRemoveRecord(book,group,NULL)); CHECK(ABAddressBookSave(book,NULL));
    CHECK(!RCCurrentSyncBackend()->syncContacts(store,NULL,YES,&count,&error));
    CHECK(ABAddressBookGetPersonWithRecordID(book,[identifier intValue]));
    CHECK(Count(j,"SELECT count(*) FROM write_operations")==0);
    CFRelease(book); [groupID release];
    puts("PASS: interrupted Contacts save and missing group block replay without duplicate creation or cloud deletion");
  } @finally { if(store) { Cleanup(RCContactStoreWriteJournal(store),YES); RCContactStoreClose(store); } }
}
static void Credentials(void) {
  NSString *account=[@"rcloud-offline-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
  char *password=NULL,*username=NULL; size_t length=0;
  @try {
    CHECK(RCICloudCredentialsSave([account UTF8String],"synthetic-one",13,"unused",&error));
    CHECK(RCICloudCredentialsCopyPassword([account UTF8String],&password,&length,&error));
    CHECK(length==13 && !memcmp(password,"synthetic-one",13));
    RCICloudCredentialsClearPassword(password,length); password=NULL;
    CHECK(RCICloudCredentialsCopyUsername([account UTF8String],&username,&error));
    CHECK(!strcmp(username,[account UTF8String])); free(username); username=NULL;
    CHECK(RCICloudCredentialsSave([account UTF8String],"synthetic-two",13,"unused",&error));
    CHECK(RCICloudCredentialsCopyPassword([account UTF8String],&password,&length,&error));
    CHECK(length==13 && !memcmp(password,"synthetic-two",13));
  } @finally {
    RCICloudCredentialsClearPassword(password,length); free(username);
    CHECK(RCICloudCredentialsRemove([account UTF8String],&error));
  }
  puts("PASS: mobile daemon Keychain save/read/update and synthetic credential cleanup");
}
static void Dates(void) {
  RCCalendarDate *d=[RCCalendarDate dateWithYear:2025 month:3 day:9 hour:12 minute:34 second:56 timeZone:[NSTimeZone localTimeZone]];
  CHECK([d yearOfCommonEra]==2025 && [d monthOfYear]==3 && [d dayOfMonth]==9 && [d hourOfDay]==12);
  NSData *data=[NSKeyedArchiver archivedDataWithRootObject:d];
  RCCalendarDate *copy=[NSKeyedUnarchiver unarchiveObjectWithData:data];
  CHECK([copy isKindOfClass:[RCCalendarDate class]] && [copy timeZone]==[NSTimeZone localTimeZone]);
  CHECK([copy isEqualToDate:d]);
  CHECK([[copy rc_descriptionWithCalendarFormat:@"%Y%m%dT%H%M%S" timeZone:[NSTimeZone localTimeZone] locale:nil] isEqual:@"20250309T123456"]);
  puts("PASS: iOS calendar dates retain wall time and floating marker across journal restart");
}
int RCIOSNativeTests(const char *path) {
  NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init]; setbuf(stdout,NULL); int result=1;
  RCContactStore *contacts=NULL; RCCalendarStore *calendars=NULL; NSData *baseline=nil;
  @try {
    CHECK(getuid()==501); CHECK(RCIOSWaitForAccess(YES,&error)); CHECK(RCIOSWaitForAccess(NO,&error));
    Dates(); Credentials(); baseline=[ContactsSnapshot() retain];
    NSString *directory=[NSString stringWithUTF8String:path];
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:@"contacts.sqlite"]]);
    contacts=RCContactStoreOpen([[directory stringByAppendingPathComponent:@"contacts.sqlite"] fileSystemRepresentation],"offline-ios-test",&error); CHECK(contacts);
    calendars=RCCalendarStoreOpen([[directory stringByAppendingPathComponent:@"calendars.sqlite"] fileSystemRepresentation],"offline-ios-test",&error); CHECK(calendars);
    RCWriteJournal cj=RCContactStoreWriteJournal(contacts),ej=RCCalendarStoreWriteJournal(calendars);
    long count=0; CHECK(!RCCurrentSyncBackend()->syncContacts(contacts,NULL,NO,&count,&error));
    CHECK(!RCCurrentSyncBackend()->syncCalendars(calendars,NULL,NO,&count,&error));
    puts("PASS: incomplete inventory cannot publish empty native stores");
    NSString *vcard=@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:offline-native-contact\r\nN:Native;RetroCloudIOSTest;;;\r\nFN:RetroCloudIOSTest Native\r\nEMAIL;TYPE=HOME:fixture@example.invalid\r\nTEL;TYPE=CELL:555-0100\r\nBDAY:1980-02-29\r\nNOTE:offline initial\r\nX-PRIVATE-FIXTURE:preserve\r\nEND:VCARD\r\n";
    ContactsSeed(contacts,Data(vcard),"\"c1\""); SyncContacts(contacts,NO,YES);
    NSString *contactID=[[FirstRow(cj) objectForKey:@"id"] copy]; CHECK(contactID);
    ABAddressBookRef book=RCIOSCreateAddressBook(NULL); ABRecordRef person=ABAddressBookGetPersonWithRecordID(book,[contactID intValue]);
    CHECK([Value(person,kABPersonFirstNameProperty) isEqual:@"RetroCloudIOSTest"]);
    CHECK([Value(person,kABPersonNoteProperty) isEqual:@"offline initial"]); CFRelease(book);
    SyncContacts(contacts,NO,YES); CHECK([[FirstRow(cj) objectForKey:@"id"] isEqual:contactID]);
    vcard=[vcard stringByReplacingOccurrencesOfString:@"offline initial" withString:@"remote update"];
    ContactsSeed(contacts,Data(vcard),"\"c2\""); SyncContacts(contacts,NO,YES);
    book=RCIOSCreateAddressBook(NULL); person=ABAddressBookGetPersonWithRecordID(book,[contactID intValue]);
    CHECK([Value(person,kABPersonNoteProperty) isEqual:@"remote update"]);
    CHECK(ABRecordSetValue(person,kABPersonNoteProperty,CFSTR("local update"),NULL)); CHECK(ABAddressBookSave(book,NULL)); CFRelease(book);
    SyncContacts(contacts,YES,NO); CHECK(Count(cj,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    NSData *confirmed=ConfirmWrite(cj);
    CHECK([confirmed isEqual:Data([vcard stringByReplacingOccurrencesOfString:@"remote update" withString:@"local update"])]);
    ContactsSeed(contacts,confirmed,"\"confirmed\""); SyncContacts(contacts,YES,YES); SyncContacts(contacts,YES,YES);
    CHECK(Count(cj,"SELECT count(*) FROM write_operations")==1); CHECK(Count(cj,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    [contactID release]; puts("PASS: iOS contacts import/update, stable identity, local edit, exact acknowledgement and replay");
    NSString *ical=@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:offline-native-event\r\nDTSTART:20271009T120000Z\r\nDTEND:20271009T130000Z\r\nSUMMARY:RetroCloudIOSTest\r\nDESCRIPTION:offline initial\r\nBEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER:-PT10M\r\nATTACH;VALUE=URI:Basso\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    CalendarSeed(calendars,Data(ical),"\"e1\""); SyncCalendar(calendars,NO,YES);
    NSString *eventID=[[FirstRow(ej) objectForKey:@"id"] copy]; CHECK(eventID);
    EKEventStore *events=[[[EKEventStore alloc] init] autorelease]; EKEvent *event=[events eventWithIdentifier:eventID];
    CHECK(event && [[event title] isEqual:@"RetroCloudIOSTest"] && [[event alarms] count]==1);
    SyncCalendar(calendars,NO,YES); CHECK([[FirstRow(ej) objectForKey:@"id"] isEqual:eventID]);
    [event setNotes:@"local update"]; CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(calendars,YES,NO); CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE state='queued'")==1);
    confirmed=ConfirmWrite(ej); CalendarSeed(calendars,confirmed,"\"confirmed\""); SyncCalendar(calendars,YES,YES); SyncCalendar(calendars,YES,YES);
    CHECK(Count(ej,"SELECT count(*) FROM write_operations")==1); CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE state='acknowledged'")==1);
    CHECK([[[[NSString alloc] initWithData:confirmed encoding:NSUTF8StringEncoding] autorelease] rangeOfString:@"ACTION:AUDIO"].location!=NSNotFound);
    PendingCalendarSave(ej,[[[FirstRow(ej) objectForKey:@"resource"] objectForKey:@"root"] description],NO);
    SyncCalendar(calendars,NO,YES);
    CHECK(Count(ej,"SELECT count(*) FROM native_store_resources WHERE pending=1")==0);
    CHECK([[FirstRow(ej) objectForKey:@"id"] isEqual:eventID]);
    [eventID release]; puts("PASS: iOS EventKit import, audio projection, local edit, exact acknowledgement and replay");
    ContactsSeed(contacts,nil,NULL); SyncContacts(contacts,NO,YES);
    CalendarSeed(calendars,nil,NULL); SyncCalendar(calendars,NO,YES);
    CHECK(Count(cj,"SELECT count(*) FROM native_store_resources WHERE root NOT LIKE '@%'")==0);
    CHECK(Count(ej,"SELECT count(*) FROM native_store_resources WHERE root NOT LIKE '@%'")==0);
    puts("PASS: remote deletion removes only owned native records");
    ContactRecoveryTests(directory); ExcludedOccurrenceTests(directory,NO); ExcludedOccurrenceTests(directory,YES); InvitationTests(directory);
    result=0;
  } @catch(NSException *exception) {
    fprintf(stderr,"FAIL: %s\n",[[exception reason] UTF8String]);
  } @finally {
    @try {
      if(contacts) Cleanup(RCContactStoreWriteJournal(contacts),YES);
      if(calendars) Cleanup(RCCalendarStoreWriteJournal(calendars),NO);
      if(baseline) CHECK([baseline isEqual:ContactsSnapshot()]);
      puts("PASS: fixtures removed; pre-existing contacts unchanged");
    } @catch(NSException *exception) { (void)exception; result=1; puts("FAIL: fixture cleanup or baseline verification"); }
    if(contacts) RCContactStoreClose(contacts); if(calendars) RCCalendarStoreClose(calendars); [baseline release];
  }
  [pool drain]; return result;
}
