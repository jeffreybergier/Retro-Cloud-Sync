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
    CHECK([events saveEvent:event span:EKSpanFutureEvents commit:YES error:NULL]);
    SyncCalendar(calendars,YES,NO);
    CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    SyncCalendar(calendars,YES,NO);
    CHECK(Count(ej,"SELECT count(*) FROM write_operations WHERE kind='create'")==1);
    [calendarID release];
    puts("PASS: Locally created contacts/events queue once across repeated exchanges"); result=0;
  } @catch(NSException *exception) { fprintf(stderr,"FAIL: %s\n",[[exception reason] UTF8String]); }
  @try { if(contacts) Cleanup(RCContactStoreWriteJournal(contacts),YES); if(calendars) Cleanup(RCCalendarStoreWriteJournal(calendars),NO); }
  @catch(NSException *exception) { fprintf(stderr,"Cleanup needs retry: %s\n",[[exception name] UTF8String]); result=1; }
  RCContactStoreClose(contacts); RCCalendarStoreClose(calendars);
  if(!result) puts("PASS: Native store offline suite; disposable contacts, events and containers removed");
  [pool release]; return result;
}
