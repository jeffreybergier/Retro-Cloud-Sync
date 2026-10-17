#import "../../../macOS-daemon/RCContactDates.h"
#import "../../../macOS-daemon/RCNativeGraphChanges.h"
#import "../../../macOS-daemon/RCTwoWayInternal.h"

/* Synthetic dates and an injected store only; no native contacts, timezone
   preferences, credentials or network are changed by this regression. */
static void ContactDateTests(RCContactStore *store)
{
  NSString *root=@"date-contact";
  NSData *body=[@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:date-contact\r\nN:Fixture;Date;;;\r\nFN:Date Fixture\r\nBDAY:1900-02-28\r\nitem1.X-ABDATE:2000-02-29\r\nitem1.X-ABLabel:Anniversary\r\nX-PRIVATE:retain\r\nEND:VCARD\r\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *resource=ContactResource(body,root,
      @"https://fixture.invalid/book/date.vcf",@"\"date-base\"");
  NSDictionary *base=[resource objectForKey:@"graph"];
  NSTimeZone *utc=[NSTimeZone timeZoneForSecondsFromGMT:0];
  NSArray *zones=[NSArray arrayWithObjects:@"Asia/Yakutsk",
      @"America/Los_Angeles",@"Pacific/Kiritimati",@"Pacific/Pago_Pago",
      @"Asia/Kathmandu",@"Europe/London",nil];
  NSMutableDictionary *legacy=[NSMutableDictionary dictionaryWithDictionary:base];
  NSEnumerator *records=[base keyEnumerator]; NSString *identifier;
  while((identifier=[records nextObject])) {
    NSDictionary *record=[base objectForKey:identifier];
    NSString *field=[identifier isEqual:root] ? @"birthday" : @"value";
    id value=[record objectForKey:field];
    if(![value isKindOfClass:[NSDate class]]) continue;
    NSMutableDictionary *old=[NSMutableDictionary dictionaryWithDictionary:record];
    NSDate *native=RCContactDateToNative(value,[NSTimeZone timeZoneWithName:@"Asia/Yakutsk"]);
    /* Old snapshots persisted absolute NSDate values without a timezone. */
    [old setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:
        [native timeIntervalSinceReferenceDate]] forKey:field];
    [legacy setObject:old forKey:identifier];
    NSEnumerator *names=[zones objectEnumerator]; NSString *name;
    while((name=[names nextObject])) {
      NSTimeZone *zone=[NSTimeZone timeZoneWithName:name]; CHECK(zone);
      id local=RCContactDateToNative(value,zone);
      CHECK([[local rc_descriptionWithCalendarFormat:@"%Y-%m-%d"
          timeZone:zone locale:nil] isEqual:[value
          rc_descriptionWithCalendarFormat:@"%Y-%m-%d" timeZone:utc locale:nil]]);
      CHECK([RCContactDateFromNative(local,zone) isEqual:value]);
    }
  }
  legacy=[NSKeyedUnarchiver unarchiveObjectWithData:
      [NSKeyedArchiver archivedDataWithRootObject:legacy]];
  NSDictionary *truth=RCChangedGraph(base,legacy,base);
  CHECK(RCTwoWayGraphsEqual(truth,base));
  NSDictionary *desired=RCContactEncodeLocal(store,resource,truth,root,&error);
  CHECK(desired && [[desired objectForKey:@"body"] isEqual:body]);
  /* A real one-day edit, including leap day, must still survive the encoder. */
  NSMutableDictionary *changed=[NSMutableDictionary dictionaryWithDictionary:base];
  NSMutableDictionary *card=[NSMutableDictionary dictionaryWithDictionary:[base objectForKey:root]];
  NSTimeZone *zone=[NSTimeZone timeZoneWithName:@"Pacific/Kiritimati"];
  [card setObject:RCContactDateFromNative([RCCalendarDate dateWithYear:1900
      month:3 day:1 hour:12 minute:0 second:0 timeZone:zone],zone) forKey:@"birthday"];
  [changed setObject:card forKey:root];
  truth=RCChangedGraph(base,legacy,changed);
  desired=RCContactEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
  NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"]
      encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"BDAY:1900-03-01"].location!=NSNotFound);
  CHECK([wire rangeOfString:@"X-PRIVATE:retain"].location!=NSNotFound);
  [card removeObjectForKey:@"birthday"]; [changed setObject:card forKey:root];
  desired=RCContactEncodeLocal(store,resource,RCChangedGraph(base,legacy,changed),root,&error);
  CHECK(desired);
  wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([wire rangeOfString:@"BDAY:"].location==NSNotFound);
  /* Compare civil dates, not UTC days or a tolerance: with a +14-hour zone,
     the following day's native noon is only ten hours after UTC noon. */
  NSDate *leap=[RCCalendarDate dateWithYear:2000 month:2 day:29
      hour:12 minute:0 second:0 timeZone:utc];
  NSTimeZone *east=[NSTimeZone timeZoneForSecondsFromGMT:14*3600];
  NSDate *next=[RCCalendarDate dateWithYear:2000 month:3 day:1
      hour:12 minute:0 second:0 timeZone:east];
  CHECK([next timeIntervalSinceDate:leap]==10*3600);
  CHECK(![RCContactDateFromNative(next,east) isEqual:leap]);
  CHECK(RCContactDateFromNative(nil,east)==nil);

  /* Exercise the coordinator's unchanged-resource path: old birthday attention
     clears without publishing a native contact or queuing a cloud write. */
  RCWriteJournal j=RCContactStoreWriteJournal(store);
  CHECK(RCTwoWayInitialize(&j,&error));
  NSDictionary *pending=[NSDictionary dictionaryWithObject:
      [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:@"birthday"]
      forKey:root] forKey:@"pendingFields"];
  CHECK(RCTwoWaySavePendingFields(&j,root,pending,&error));
  CHECK(RCTwoWayAttention(&j,@"unrelated-contact","unsupported-native-edit",&error));
  RCTwoWayContext c; memset(&c,0,sizeof(c)); c.journal=j;
  c.rootEntity=@"com.apple.contacts.Contact"; c.graph=base;
  c.resources=[NSArray arrayWithObject:resource];
  c.encode=RCContactEncodeLocal; c.context=store;
  backendMode=5; backendTruth=RCChangedGraph(base,legacy,base);
  CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
  sqlite3_stmt *q=NULL;
  CHECK(sqlite3_prepare_v2(j.db,"SELECT (SELECT count(*) FROM two_way_pending_fields),"
      "(SELECT count(*) FROM two_way_attention WHERE record_id='date-contact'),"
      "(SELECT count(*) FROM two_way_attention WHERE record_id='unrelated-contact'),"
      "(SELECT count(*) FROM write_operations)",-1,&q,NULL)==SQLITE_OK);
  CHECK(sqlite3_step(q)==SQLITE_ROW);
  CHECK(sqlite3_column_int(q,0)==0 && sqlite3_column_int(q,1)==0 &&
      sqlite3_column_int(q,2)==1 && sqlite3_column_int(q,3)==0);
  sqlite3_finalize(q); backendTruth=nil;
  pending=[NSDictionary dictionaryWithObject:
      [NSDictionary dictionaryWithObject:[NSArray arrayWithObjects:
      @"birthday",@"opaque native flag",nil] forKey:root] forKey:@"pendingFields"];
  CHECK(RCTwoWaySavePendingFields(&j,root,pending,&error));
  backendTruth=base;
  CHECK(RCNativeExchange(&c,YES,ContractFactory,&error));
  CHECK(sqlite3_prepare_v2(j.db,"SELECT fields FROM two_way_pending_fields WHERE root_id='date-contact'",-1,&q,NULL)==SQLITE_OK);
  CHECK(sqlite3_step(q)==SQLITE_ROW);
  NSDictionary *remaining=RCTwoWayUnarchive(q,0);
  CHECK([[remaining objectForKey:root] isEqual:
      [NSArray arrayWithObject:@"opaque native flag"]]);
  sqlite3_finalize(q); backendTruth=nil;
  CHECK(RCTwoWaySQL(&j,&error,"DELETE FROM two_way_pending_fields WHERE root_id='date-contact'; DELETE FROM two_way_attention WHERE record_id='date-contact'"));
  CHECK(RCTwoWaySQL(&j,&error,"DELETE FROM two_way_attention WHERE record_id='unrelated-contact'"));
  puts("PASS: Contact dates survive timezone changes, legacy snapshots, real edits and deletion; verified stale warnings clear without writes");
}
