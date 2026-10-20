#import "RCPlatformDate.h"
#import "RCNativeSystemStore.h"
#import "RCRecordGraph.h"
#import "RCAutorelease.h"
#import "RCLogger.h"
#import "RCSyncFieldScope.h"
#import "RCCalendarTime.h"
#import "RCCalendarGraph.h"
#if defined(__LP64__) || TARGET_OS_IPHONE
#import <EventKit/EventKit.h>
#import "RCNativeCalendarDates.h"
#import "RCNativeGraphChanges.h"
#include <openssl/sha.h>
static BOOL EKSave(EKEventStore *store,SEL selector,id item,BOOL event,RCError *error)
{
  NSError *nativeError=nil; BOOL ok=NO;
  if(selector==@selector(saveEvent:span:commit:error:))
    ok=[store saveEvent:item span:EKSpanFutureEvents commit:YES error:&nativeError];
  else if(selector==@selector(removeEvent:span:commit:error:))
    ok=[store removeEvent:item span:EKSpanFutureEvents commit:YES error:&nativeError];
  else if(selector==@selector(saveCalendar:commit:error:))
    ok=[store saveCalendar:item commit:YES error:&nativeError];
  else if(selector==@selector(removeCalendar:commit:error:))
    ok=[store removeCalendar:item commit:YES error:&nativeError];
  (void)event;
  if(!ok) RCErrorSet(error,1,"EventKit save/remove failed (%ld); check Calendar access",(long)[nativeError code]);
  return ok;
}
static id RCDecode(sqlite3_stmt *q,int column)
{
  return [NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(q,column)
      length:sqlite3_column_bytes(q,column)]];
}
static BOOL RCSaveNative(RCWriteJournal j,NSDictionary *resource,NSDictionary *ids,NSDictionary *snapshot,BOOL pending,RCError *error)
{
  sqlite3_stmt *q=NULL;
  BOOL ok=sqlite3_prepare_v2(j.db,"INSERT OR REPLACE INTO native_store_resources VALUES(?,?,?,?,?,?)",-1,&q,NULL)==SQLITE_OK;
  if(ok) {
    NSData *r=[NSKeyedArchiver archivedDataWithRootObject:resource], *n=[NSKeyedArchiver archivedDataWithRootObject:ids],
        *s=[NSKeyedArchiver archivedDataWithRootObject:snapshot ?: [NSDictionary dictionary]];
    sqlite3_bind_int64(q,1,j.account); sqlite3_bind_text(q,2,[[resource objectForKey:@"root"] UTF8String],-1,SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,3,[r bytes],(int)[r length],SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,4,[n bytes],(int)[n length],SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,5,[s bytes],(int)[s length],SQLITE_TRANSIENT); sqlite3_bind_int(q,6,pending);
    ok=sqlite3_step(q)==SQLITE_DONE;
  }
  sqlite3_finalize(q);
  if(!ok) RCErrorSet(error,1,"Could not checkpoint native resource ownership");
  return ok;
}
static NSDictionary *RCLoadNative(RCWriteJournal j,NSString *root,RCError *error)
{
  sqlite3_stmt *q=NULL; NSMutableDictionary *r=nil;
  if(sqlite3_prepare_v2(j.db,"SELECT resource,native,snapshot,pending FROM native_store_resources WHERE account_id=? AND root=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
    int step=sqlite3_step(q);
    if(step==SQLITE_ROW) {
      r=[NSMutableDictionary dictionaryWithDictionary:RCDecode(q,0)];
      [r setObject:RCDecode(q,1) forKey:@"_ids"]; [r setObject:RCDecode(q,2) forKey:@"_snapshot"];
      [r setObject:[NSNumber numberWithBool:sqlite3_column_int(q,3)] forKey:@"_pending"];
    } else if(step!=SQLITE_DONE) RCErrorSet(error,1,"Could not read native ownership");
  } else RCErrorSet(error,1,"Could not read native ownership");
  sqlite3_finalize(q); return r;
}
static void Put(NSMutableDictionary *record,NSString *key,id value)
{
  if(value) [record setObject:value forKey:key]; else [record removeObjectForKey:key];
}
static NSArray *EKWeekdays(void) { return [@"sunday|monday|tuesday|wednesday|thursday|friday|saturday" componentsSeparatedByString:@"|"]; }
static NSArray *EKFrequencies(void) { return [@"daily|weekly|monthly|yearly" componentsSeparatedByString:@"|"]; }
static EKRecurrenceRule *EKRule(NSDictionary *record)
{
  NSUInteger frequency=[EKFrequencies() indexOfObject:[record objectForKey:@"frequency"]];
  NSInteger interval=[[record objectForKey:@"interval"] integerValue];
  if(frequency==NSNotFound || interval<1) return nil;
  NSMutableArray *days=[NSMutableArray array]; NSArray *names=[record objectForKey:@"bydaydays"],*positions=[record objectForKey:@"bydayfreq"]; NSUInteger n;
  for(n=0;n<[names count];n++) {
    NSUInteger day=[EKWeekdays() indexOfObject:[names objectAtIndex:n]];
    if(day==NSNotFound) return nil;
    NSInteger week=n<[positions count] ? [[positions objectAtIndex:n] integerValue] : 0;
    [days addObject:[EKRecurrenceDayOfWeek dayOfWeek:(day+1) weekNumber:week]];
  }
  EKRecurrenceEnd *end=nil;
  if([[record objectForKey:@"count"] integerValue]>0) end=[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:[[record objectForKey:@"count"] unsignedIntegerValue]];
  else if([record objectForKey:@"until"]) end=[EKRecurrenceEnd recurrenceEndWithEndDate:[record objectForKey:@"until"]];
  return [[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:(EKRecurrenceFrequency)frequency interval:interval
      daysOfTheWeek:[days count] ? days : nil daysOfTheMonth:[record objectForKey:@"bymonthday"]
      monthsOfTheYear:[record objectForKey:@"bymonth"] weeksOfTheYear:[record objectForKey:@"byweeknumber"]
      daysOfTheYear:[record objectForKey:@"byyearday"] setPositions:[record objectForKey:@"bysetpos"] end:end] autorelease];
}
static NSDictionary *EKReadRule(id rule,NSString *owner)
{
  NSMutableDictionary *r=[NSMutableDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Recurrence",RCRecordEntityNameKey,[NSArray arrayWithObject:owner],@"owner",nil];
  NSUInteger frequency=[[rule valueForKey:@"frequency"] unsignedIntegerValue];
  if(frequency>3) return nil;
  [r setObject:[EKFrequencies() objectAtIndex:frequency] forKey:@"frequency"];
  Put(r,@"interval",[rule valueForKey:@"interval"]);
  id end=[rule valueForKey:@"recurrenceEnd"];
  if([[end valueForKey:@"occurrenceCount"] integerValue]) Put(r,@"count",[end valueForKey:@"occurrenceCount"]);
  else Put(r,@"until",[end valueForKey:@"endDate"]);
  NSArray *keys=[@"bymonthday|bymonth|byweeknumber|byyearday|bysetpos" componentsSeparatedByString:@"|"];
  NSArray *props=[@"daysOfTheMonth|monthsOfTheYear|weeksOfTheYear|daysOfTheYear|setPositions" componentsSeparatedByString:@"|"]; NSUInteger n;
  for(n=0;n<[keys count];n++) { id value=[rule valueForKey:[props objectAtIndex:n]]; if([value count]) Put(r,[keys objectAtIndex:n],value); }
  NSMutableArray *days=[NSMutableArray array],*positions=[NSMutableArray array];
  NSEnumerator *it=[[rule valueForKey:@"daysOfTheWeek"] objectEnumerator]; id day;
  while((day=[it nextObject])) {
    NSInteger index=[[day valueForKey:@"dayOfTheWeek"] integerValue];
    if(index<1 || index>7) return nil;
    [days addObject:[EKWeekdays() objectAtIndex:index-1]]; [positions addObject:[day valueForKey:@"weekNumber"]];
  }
  if([days count]) { Put(r,@"bydaydays",days); Put(r,@"bydayfreq",positions); }
  NSInteger week=[[rule valueForKey:@"firstDayOfTheWeek"] integerValue];
  if(week>0 && week<=7) Put(r,@"weekstartday",[EKWeekdays() objectAtIndex:week-1]);
  return r;
}
static NSDate *EKDate(NSDate *date,BOOL allDay,BOOL toNative)
{
  if(!date) return nil;
  if(allDay) {
    NSTimeZone *from=toNative ? [NSTimeZone timeZoneForSecondsFromGMT:0] : [NSTimeZone defaultTimeZone];
    NSTimeZone *to=toNative ? [NSTimeZone defaultTimeZone] : [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *s=[date rc_descriptionWithCalendarFormat:@"%Y-%m-%d" timeZone:from locale:nil];
    RCCalendarDate *d=[RCCalendarDate dateWithString:s calendarFormat:@"%Y-%m-%d"];
    return [RCCalendarDate dateWithYear:[d yearOfCommonEra] month:[d monthOfYear] day:[d dayOfMonth] hour:0 minute:0 second:0 timeZone:to];
  }
  return date;
}
/* Only installed system sounds are used. Never fetch a remote attachment or
   open a server-supplied path. The full original attachment stays in the base. */
static NSDictionary *EKSystemSounds(void)
{
#if TARGET_OS_IPHONE
  return [NSDictionary dictionary];
#else
  static NSDictionary *sounds=nil;
  @synchronized([EKAlarm class]) {
    if(!sounds) {
      NSMutableDictionary *found=[NSMutableDictionary dictionary];
      NSString *directory=@"/System/Library/Sounds";
      NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
      for(NSString *file in [files sortedArrayUsingSelector:@selector(compare:)]) {
        if(![[NSArray arrayWithObjects:@"aiff",@"aif",@"wav",@"caf",nil] containsObject:[[file pathExtension] lowercaseString]]) continue;
        [found setObject:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:file]]
            forKey:[file stringByDeletingPathExtension]];
      }
      sounds=[found copy];
    }
  }
  return sounds;
#endif
}
static EKAlarm *EKMakeAlarm(NSDictionary *record,BOOL audio,RCError *error)
{
  EKAlarm *alarm=[record objectForKey:@"triggerdate"] ?
      [EKAlarm alarmWithAbsoluteDate:[record objectForKey:@"triggerdate"]] :
      [EKAlarm alarmWithRelativeOffset:[[record objectForKey:@"triggerduration"] doubleValue]];
  if(audio) {
    BOOL valid; NSURL *url=RCNativeAlarmSound(record,&valid);
    if(!valid) { RCErrorSet(error,1,"Invalid audio alarm sound"); return nil; }
    (void)url;
#if !TARGET_OS_IPHONE
    NSString *name=[[[url path] lastPathComponent] stringByDeletingPathExtension];
    NSDictionary *sounds=EKSystemSounds();
    if(![sounds objectForKey:name ?: @""]) name=[sounds objectForKey:@"Basso"] ? @"Basso" : [[[sounds allKeys] sortedArrayUsingSelector:@selector(compare:)] firstObject];
    if(!name) { RCErrorSet(error,1,"No installed system sound for an audio alarm"); return nil; }
    [alarm setSoundName:name];
#endif
  }
  return alarm;
}
static NSDictionary *EKAlarmRecord(EKAlarm *alarm,NSString *root,RCError *error)
{
#if TARGET_OS_IPHONE
  BOOL audio=NO;
  if([alarm respondsToSelector:@selector(structuredLocation)] && [alarm structuredLocation]) {
#else
  BOOL audio=[alarm type]==EKAlarmTypeAudio;
  if((!audio && [alarm type]!=EKAlarmTypeDisplay) || [alarm structuredLocation]) {
#endif
    RCErrorSet(error,1,"Unsupported native alarm action or location"); return nil;
  }
  NSMutableDictionary *r=[NSMutableDictionary dictionaryWithObjectsAndKeys:
      audio ? @"com.apple.calendars.AudioAlarm" : @"com.apple.calendars.DisplayAlarm",
      RCRecordEntityNameKey,[NSArray arrayWithObject:root],@"owner",nil];
  if([alarm absoluteDate]) Put(r,@"triggerdate",[alarm absoluteDate]);
  else Put(r,@"triggerduration",[NSNumber numberWithInt:(int)[alarm relativeOffset]]);
  if(audio) {
#if !TARGET_OS_IPHONE
    NSURL *sound=[EKSystemSounds() objectForKey:[alarm soundName] ?: @""];
    if(!sound) { RCErrorSet(error,1,"Unknown native alarm sound; preserving the original alarm"); return nil; }
    Put(r,@"com.apple.ical.sound",sound);
#endif
  }
  return r;
}
/* New alarms have no durable key yet. Derive one from their native signature,
   not their current position: EventKit can reorder them between queue and ack.
   Known alarms continue to use their already checkpointed identities. */
static NSString *EKNewAlarmKey(NSDictionary *record,NSString *root,RCError *error)
{
  NSArray *signature=[NSArray arrayWithObjects:[record objectForKey:RCRecordEntityNameKey],
      [record objectForKey:@"triggerdate"] ?: @"", [record objectForKey:@"triggerduration"] ?: @"",
      [[record objectForKey:@"com.apple.ical.sound"] absoluteString] ?: @"",nil];
  NSData *data=[NSPropertyListSerialization dataFromPropertyList:signature format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
  if(!data) { RCErrorSet(error,1,"Could not identify a new native alarm safely"); return nil; }
  unsigned char digest[SHA256_DIGEST_LENGTH]; SHA256([data bytes],[data length],digest);
  char hex[SHA256_DIGEST_LENGTH*2+1]; const char *digits="0123456789abcdef";
  for(NSUInteger n=0;n<sizeof(digest);n++) { hex[n*2]=digits[digest[n]>>4]; hex[n*2+1]=digits[digest[n]&15]; }
  hex[sizeof(hex)-1]=0;
  return [root stringByAppendingFormat:@"/native-alarm/%s",hex];
}
/* Mavericks may expose its default all-day alarm alongside the identical
   explicitly imported alarm. Only this exact one-source/two-equal-local case
   can be repaired during publication; ordinary native edits stay strict. */
static BOOL EKDuplicateDefaultAlarm(id event,NSDictionary *resource,
    RCError *error)
{
#if TARGET_OS_IPHONE
  (void)event; (void)resource; (void)error; return NO;
#else
  NSDictionary *graph=[resource objectForKey:@"graph"];
  NSString *root=[resource objectForKey:@"root"];
  NSDictionary *record=[graph objectForKey:root];
  NSArray *alarms=[event alarms], *audio=[record objectForKey:@"audio alarms"];
  if(![[record objectForKey:@"all day"] boolValue] || [audio count]!=1 ||
      [[record objectForKey:@"display alarms"] count] || [alarms count]!=2)
    return NO;
  EKAlarm *planned=EKMakeAlarm([graph objectForKey:[audio objectAtIndex:0]],YES,error);
  if(!planned) return NO;
  NSDictionary *expected=EKAlarmRecord(planned,root,error);
  for(EKAlarm *alarm in alarms)
    if(!RCNativeRecordsEqual(expected,EKAlarmRecord(alarm,root,error))) return NO;
  return YES;
#endif
}
/* Mavericks can materialize an extra automatic Basso reminder on a later
   read of an all-day series. Omit only that precise extra from the projection,
   after matching every source reminder. Leave native objects and wire data
   intact; two-way series writes/deletions are deferred by the coordinator. */
static NSArray *EKSeriesAlarms(id event,NSDictionary *resource,RCError *error)
{
  NSArray *alarms=[event alarms]; NSString *root=[resource objectForKey:@"root"];
  NSDictionary *graph=[resource objectForKey:@"graph"], *record=[graph objectForKey:root];
  NSUInteger count=[[record objectForKey:@"display alarms"] count]+[[record objectForKey:@"audio alarms"] count];
  if(![[record objectForKey:@"all day"] boolValue] || ![event isAllDay] ||
      ![[record objectForKey:@"recurrences"] count] || ![[event recurrenceRules] count] ||
      [event isDetached] || [alarms count]!=count+1) return alarms;
  NSMutableArray *remaining=[NSMutableArray arrayWithArray:alarms];
  NSString *links[]={@"display alarms",@"audio alarms"};
  for(int kind=0;kind<2;kind++) for(NSString *key in [record objectForKey:links[kind]]) {
    EKAlarm *planned=EKMakeAlarm([graph objectForKey:key],kind==1,error); if(!planned) return nil;
    NSDictionary *wanted=EKAlarmRecord(planned,root,error); if(!wanted) return nil;
    NSUInteger match=NSNotFound;
    for(NSUInteger n=0;n<[remaining count];n++) {
      NSDictionary *actual=EKAlarmRecord([remaining objectAtIndex:n],root,error); if(!actual) return nil;
      if(RCNativeRecordsEqual(wanted,actual)) { match=n; break; }
    }
    if(match==NSNotFound) return alarms;
    [remaining removeObjectAtIndex:match];
  }
  if([remaining count]!=1) return alarms;
  EKAlarm *extra=[remaining objectAtIndex:0]; NSDictionary *r=EKAlarmRecord(extra,root,error); if(!r) return nil;
  if(![[r objectForKey:RCRecordEntityNameKey] isEqual:@"com.apple.calendars.AudioAlarm"] ||
      [r objectForKey:@"triggerdate"] || [[r objectForKey:@"triggerduration"] intValue]!=-54000 ||
      ![[r objectForKey:@"com.apple.ical.sound"] isEqual:[EKSystemSounds() objectForKey:@"Basso"]]) return alarms;
  NSMutableArray *projected=[NSMutableArray arrayWithArray:alarms];
  [projected removeObjectAtIndex:[projected indexOfObjectIdenticalTo:extra]]; return projected;
}
static BOOL EKReadAlarms(id event,NSDictionary *resource,NSMutableDictionary *record,
    NSMutableDictionary *graph,BOOL recovering,RCError *error)
{
  NSString *root=[resource objectForKey:@"root"];
  NSDictionary *base=[resource objectForKey:@"graph"], *snapshot=[resource objectForKey:@"_snapshot"];
  NSMutableDictionary *expected=[NSMutableDictionary dictionary], *matches=[NSMutableDictionary dictionary];
  NSMutableArray *observed=[NSMutableArray array], *unmatched=[NSMutableArray array];
  NSString *links[]={@"display alarms",@"audio alarms"};
  NSDictionary *reference=[snapshot objectForKey:root] ?: [base objectForKey:root];
  /* Include native-only baseline alarms so reorder/restart keeps their stable
     identities too. They remain absent from the retained wire graph. */
  for(int kind=0;kind<2;kind++) for(NSString *key in [reference objectForKey:links[kind]]) {
    NSDictionary *prior=[snapshot objectForKey:key];
    if(!prior) {
      EKAlarm *alarm=EKMakeAlarm([base objectForKey:key],kind==1,error); if(!alarm) return NO;
      prior=EKAlarmRecord(alarm,root,error); if(!prior) return NO;
    }
#if TARGET_OS_IPHONE
    /* iOS exposes timing only. Keep wire audio action/attachment in the base,
       but compare its native projection using the system reminder signature. */
    NSMutableDictionary *timing=[NSMutableDictionary dictionaryWithDictionary:prior];
    [timing setObject:@"com.apple.calendars.DisplayAlarm" forKey:RCRecordEntityNameKey];
    [timing removeObjectForKey:@"com.apple.ical.sound"]; prior=timing;
#endif
    [expected setObject:prior forKey:key];
  }
  NSArray *nativeAlarms=EKSeriesAlarms(event,resource,error); if(!nativeAlarms && error->code) return NO;
  if(recovering && EKDuplicateDefaultAlarm(event,resource,error))
    nativeAlarms=[NSArray arrayWithObject:[nativeAlarms objectAtIndex:0]];
  if(error->code) return NO;
  for(EKAlarm *alarm in nativeAlarms) {
    NSDictionary *r=EKAlarmRecord(alarm,root,error); if(!r) return NO;
    for(NSDictionary *prior in observed) if(RCNativeRecordsEqual(prior,r)) goto ambiguous;
    [observed addObject:r];
  }
  /* Match unchanged alarms first, independent of EventKit ordering. Only one
     remaining edit has an unambiguous identity; never guess among several. */
  for(NSUInteger n=0;n<[observed count];n++) {
    NSNumber *index=[NSNumber numberWithUnsignedInteger:n]; NSString *match=nil;
    for(NSString *key in expected) if(RCNativeRecordsEqual([expected objectForKey:key],[observed objectAtIndex:n])) {
      if(match) goto ambiguous;
      match=key;
    }
    if(match) { [matches setObject:match forKey:index]; [expected removeObjectForKey:match]; }
    else [unmatched addObject:index];
  }
  if([expected count] && [unmatched count]) {
    if([expected count]!=1 || [unmatched count]!=1) goto ambiguous;
    NSString *key=[[expected allKeys] objectAtIndex:0]; NSNumber *index=[unmatched objectAtIndex:0];
    if(![[[expected objectForKey:key] objectForKey:RCRecordEntityNameKey]
        isEqual:[[observed objectAtIndex:[index unsignedIntegerValue]] objectForKey:RCRecordEntityNameKey]]) goto ambiguous;
    [matches setObject:key forKey:index];
  }
  NSMutableArray *display=[NSMutableArray array], *audio=[NSMutableArray array];
  for(NSUInteger n=0;n<[observed count];n++) {
    NSDictionary *r=[observed objectAtIndex:n];
    NSString *key=[matches objectForKey:[NSNumber numberWithUnsignedInteger:n]];
    if(!key) {
      NSString *stem=EKNewAlarmKey(r,root,error); if(!stem) return NO;
      key=stem; NSUInteger suffix=0;
      while([base objectForKey:key] || [snapshot objectForKey:key] || [graph objectForKey:key])
        key=[stem stringByAppendingFormat:@"/%lu",(unsigned long)++suffix];
    }
#if TARGET_OS_IPHONE
    NSDictionary *original=[base objectForKey:key] ?: [snapshot objectForKey:key];
    if([[original objectForKey:RCRecordEntityNameKey] isEqual:@"com.apple.calendars.AudioAlarm"]) {
      NSMutableDictionary *audioRecord=[NSMutableDictionary dictionaryWithDictionary:r];
      [audioRecord setObject:@"com.apple.calendars.AudioAlarm" forKey:RCRecordEntityNameKey];
      Put(audioRecord,@"com.apple.ical.sound",[original objectForKey:@"com.apple.ical.sound"]); r=audioRecord;
    }
#endif
    [graph setObject:r forKey:key];
    [([[r objectForKey:RCRecordEntityNameKey] isEqual:@"com.apple.calendars.AudioAlarm"] ? audio : display) addObject:key];
  }
  for(int kind=0;kind<2;kind++) {
    NSMutableArray *remaining=[NSMutableArray arrayWithArray:kind ? audio : display];
    NSMutableArray *ordered=[NSMutableArray array];
    /* Relationship equality ignores ordering, but the lossless wire encoder
       uses source order. Do not turn a native reorder into a structural edit. */
    for(NSString *key in [[base objectForKey:root] objectForKey:links[kind]])
      if([remaining containsObject:key]) { [ordered addObject:key]; [remaining removeObject:key]; }
    [ordered addObjectsFromArray:remaining]; [record setObject:ordered forKey:links[kind]];
  }
  return YES;
ambiguous:
  RCErrorSet(error,1,"Native alarm identities are ambiguous (%lu expected, %lu native); preserving the original alarms",
      (unsigned long)[expected count],(unsigned long)[[event alarms] count]); return NO;
}
static NSDictionary *EKRead(id event,NSDictionary *resource,BOOL recovering,
    RCError *error)
{
  if(!event) return [NSDictionary dictionary];
  NSString *root=[resource objectForKey:@"root"];
  NSDictionary *base=[[resource objectForKey:@"graph"] objectForKey:root];
  NSMutableDictionary *graph=[NSMutableDictionary dictionary], *record=[NSMutableDictionary dictionaryWithObjectsAndKeys:
      @"com.apple.calendars.Event",RCRecordEntityNameKey,nil];
  NSArray *keys=[@"summary|description|location|url|all day" componentsSeparatedByString:@"|"];
  NSArray *properties=[@"title|notes|location|URL|allDay" componentsSeparatedByString:@"|"]; NSUInteger n;
  for(n=0;n<[keys count];n++) Put(record,[keys objectAtIndex:n],[event valueForKey:[properties objectAtIndex:n]]);
  BOOL allDay=[[record objectForKey:@"all day"] boolValue];
  NSArray *dateKeys=[NSArray arrayWithObjects:@"start date",@"end date",nil], *dateProperties=[NSArray arrayWithObjects:@"startDate",@"endDate",nil];
  for(n=0;n<2;n++) {
    NSDate *date=EKDate([event valueForKey:[dateProperties objectAtIndex:n]],allDay,NO);
    if(!allDay && RCCalendarFloatingDate([base objectForKey:[dateKeys objectAtIndex:n]])) {
      RCCalendarDate *floating=[RCCalendarDate dateWithTimeIntervalSinceReferenceDate:[date timeIntervalSinceReferenceDate]];
      [floating setTimeZone:[NSTimeZone localTimeZone]]; date=floating;
    }
    Put(record,[dateKeys objectAtIndex:n],date);
  }
  Put(record,@"calendar",[base objectForKey:@"calendar"]);
  NSMutableArray *recurrences=[NSMutableArray array]; NSEnumerator *it=[[event valueForKey:@"recurrenceRules"] objectEnumerator]; id rule; n=0;
  while((rule=[it nextObject])) {
    NSArray *existing=[base objectForKey:@"recurrences"];
    NSString *key=n<[existing count] ? [existing objectAtIndex:n] : [root stringByAppendingFormat:@"/recurrence/%lu",(unsigned long)n];
    NSDictionary *r=EKReadRule(rule,root); if(r) { [graph setObject:r forKey:key]; [recurrences addObject:key]; } n++;
  }
  [record setObject:recurrences forKey:@"recurrences"];
  if(!EKReadAlarms(event,resource,record,graph,recovering,error)) return nil;
  /* Attendee/organizer links, children and exception dates deliberately stay
     out of this native snapshot. RCChangedGraph retains them from the full publication base;
     their absence in EventKit is not a user edit or a cloud deletion. */
  /* Capture unsupported local changes too, so they cannot be mistaken for a
     complete deletion or silently accepted by an upload receipt. */
  if([[event valueForKey:@"attendees"] count]) Put(record,@"native attendees",[NSNumber numberWithUnsignedInteger:[[event valueForKey:@"attendees"] count]]);
  [graph setObject:record forKey:root]; return graph;
}
/* Mavericks materializes its implicit alarm at commit, sometimes alongside
   an equal explicit alarm. Reset only that verified pair: committing an empty
   explicit list leaves the default alarm. Verify every native field afterward;
   no ordering or private default-alarm property is used. */
static BOOL EKRepairDefaultAlarm(EKEventStore *store,id event,
    NSDictionary *resource,RCError *error)
{
  if(!EKDuplicateDefaultAlarm(event,resource,error)) return !error->code;
  NSDictionary *expected=EKRead(event,resource,YES,error); if(!expected) return NO;
  [event setAlarms:[NSArray array]];
  if(!EKSave(store,@selector(saveEvent:span:commit:error:),event,YES,error)) return NO;
  NSDictionary *actual=EKRead(event,resource,NO,error);
  if(!actual || !RCNativeGraphsEqual(expected,actual)) {
    if(!error->code) RCErrorSet(error,1,"Default alarm repair did not preserve the intended event; publication remains pending");
    return NO;
  }
  return YES;
}
static BOOL EKCanWrite(NSDictionary *resource,RCError *error)
{
  NSDictionary *graph=[resource objectForKey:@"graph"], *r=[graph objectForKey:[resource objectForKey:@"root"]];
  if (!RCCalendarImportGraphDates(graph,error)) return NO;
  BOOL allDay=[[r objectForKey:@"all day"] boolValue];
  NSMutableDictionary *converted=[NSMutableDictionary dictionaryWithDictionary:r];
  for (NSString *field in [NSArray arrayWithObjects:@"start date",@"end date",nil]) {
    NSDate *date=EKDate([r objectForKey:field],allDay,YES);
    if (date) [converted setObject:date forKey:field];
  }
  NSMutableDictionary *nativeGraph=[NSMutableDictionary dictionaryWithDictionary:graph];
  [nativeGraph setObject:converted forKey:[resource objectForKey:@"root"]];
  if (!RCCalendarImportGraphDates(nativeGraph,error)) return NO;
  /* Project a recurring master without its EXDATE exclusions. The full wire
     base retains them; native two-way series edits/deletions remain deferred.
     Detached components and non-recurring exception structures stay pending. */
  if([[r objectForKey:@"detached events"] count] ||
      ([[r objectForKey:@"exception dates"] count] && ![[r objectForKey:@"recurrences"] count]) || [[r objectForKey:@"main event"] count] ||
      [[r objectForKey:@"mail alarms"] count]) {
    RCErrorSet(error,1,"EventKit publication needs unsupported exception or alarm fields; retained for attention"); return NO;
  }
  NSEnumerator *it=[[r objectForKey:@"recurrences"] objectEnumerator]; NSString *key;
  while((key=[it nextObject])) {
    NSDictionary *rule=[graph objectForKey:key]; NSString *week=[rule objectForKey:@"weekstartday"];
    if((week && ![week isEqual:@"monday"]) || !EKRule(rule)) { RCErrorSet(error,1,"EventKit cannot represent this recurrence rule"); return NO; }
  }
  NSMutableArray *alarms=[NSMutableArray array];
  NSString *links[]={@"display alarms",@"audio alarms"};
  for(int kind=0;kind<2;kind++) for(key in [r objectForKey:links[kind]]) {
    NSDictionary *a=[graph objectForKey:key];
    if([[a objectForKey:@"repeat count"] intValue]) {
      RCErrorSet(error,1,"EventKit cannot represent repeating alarms"); return NO;
    }
    EKAlarm *alarm=EKMakeAlarm(a,kind==1,error); if(!alarm) return NO;
    NSDictionary *projected=EKAlarmRecord(alarm,[resource objectForKey:@"root"],error); if(!projected) return NO;
    for(NSDictionary *prior in alarms) if(RCNativeRecordsEqual(prior,projected)) {
      RCErrorSet(error,1,"Duplicate native alarm projections cannot be identified safely"); return NO;
    }
    [alarms addObject:projected];
  }
  return YES;
}
static BOOL EKWrite(id event,id calendar,NSDictionary *resource,RCError *error)
{
  if(!EKCanWrite(resource,error)) return NO;
  NSDictionary *graph=[resource objectForKey:@"graph"],*r=[graph objectForKey:[resource objectForKey:@"root"]];
  BOOL allDay=[[r objectForKey:@"all day"] boolValue];
  [event setValue:calendar forKey:@"calendar"];
  [event setValue:[r objectForKey:@"summary"] ?: @"" forKey:@"title"];
  [event setValue:[r objectForKey:@"description"] forKey:@"notes"];
  [event setValue:[r objectForKey:@"location"] forKey:@"location"];
  [event setValue:[r objectForKey:@"url"] forKey:@"URL"];
  [event setValue:[NSNumber numberWithBool:allDay] forKey:@"allDay"];
  NSDate *start=[r objectForKey:@"start date"];
  [event setValue:(allDay || RCCalendarFloatingDate(start) ? nil : ([start isKindOfClass:[RCCalendarDate class]] ? [(RCCalendarDate *)start timeZone] : [NSTimeZone timeZoneForSecondsFromGMT:0])) forKey:@"timeZone"];
  [event setValue:EKDate(start,allDay,YES) forKey:@"startDate"];
  [event setValue:EKDate([r objectForKey:@"end date"],allDay,YES) forKey:@"endDate"];
  NSMutableArray *rules=[NSMutableArray array]; NSEnumerator *it=[[r objectForKey:@"recurrences"] objectEnumerator]; NSString *key;
  while((key=[it nextObject])) [rules addObject:EKRule([graph objectForKey:key])];
  [event setValue:rules forKey:@"recurrenceRules"];
  NSMutableArray *alarms=[NSMutableArray array]; NSString *links[]={@"display alarms",@"audio alarms"};
  /* Retain EventKit's identity for unchanged alarms, including the implicit
     all-day default. Replacing that default with an equivalent new object on
     Mavericks leaves both the implicit and explicit alarms enabled. */
  NSArray *existing=[event alarms];
  for(int kind=0;kind<2;kind++) for(key in [r objectForKey:links[kind]]) {
    EKAlarm *alarm=EKMakeAlarm([graph objectForKey:key],kind==1,error);
    if(!alarm) return NO;
    NSDictionary *wanted=EKAlarmRecord(alarm,[resource objectForKey:@"root"],error);
    for(EKAlarm *prior in existing) {
      RCError ignored; RCErrorClear(&ignored);
      if(RCNativeRecordsEqual(wanted,EKAlarmRecord(prior,[resource objectForKey:@"root"],&ignored))) {
        alarm=prior; break;
      }
    }
    [alarms addObject:alarm];
  }
  [event setValue:alarms forKey:@"alarms"]; return YES;
}

@interface RCNativeSystemStore (Implementation)
- (id)container:(NSString *)root create:(BOOL)create error:(RCError *)error;
- (NSDictionary *)rawGraph:(NSDictionary *)saved error:(RCError *)error;
- (NSDictionary *)recoverCalendarResource:(NSDictionary *)saved error:(RCError *)error;
- (NSDictionary *)repairLegacyCalendarSnapshot:(NSDictionary *)saved error:(RCError *)error;
@end
@implementation RCNativeSystemStore
- (id)initWithContext:(RCTwoWayContext *)context error:(RCError *)error
{
  self=[super init]; if(!self) return nil; context_=context;
  contacts_=[context->rootEntity isEqual:@"com.apple.contacts.Contact"];
  if(!RCTwoWaySQL(&context->journal,error,"CREATE TABLE IF NOT EXISTS native_store_resources("
      "account_id INTEGER NOT NULL,root TEXT NOT NULL,resource BLOB NOT NULL,native BLOB NOT NULL,snapshot BLOB NOT NULL,pending INTEGER NOT NULL,PRIMARY KEY(account_id,root));"
      "CREATE TABLE IF NOT EXISTS native_upload_receipts(operation_id INTEGER PRIMARY KEY,"
      "account_id INTEGER NOT NULL,root TEXT NOT NULL,native BLOB NOT NULL,snapshot BLOB NOT NULL)")) goto failed;
  if(contacts_) {
    if(![self openContacts:error]) goto failed;

  } else {
    if(![self calendarAccess:error]) goto failed;
    events_=[[EKEventStore alloc] init];
    if(!events_) { RCErrorSet(error,1,"Could not initialize EventKit"); goto failed; }
    if(![[events_ valueForKey:@"sources"] count]) { RCErrorSet(error,1,"Calendar access or local calendar store is not ready"); goto failed; }
  }
  return self;
failed:
  [self release]; return nil;
}
- (void)dealloc
{
  [events_ release]; [super dealloc];
}
- (BOOL)syncContainers:(RCError *)error
{
  if(contacts_) return YES;
  NSEnumerator *it=[context_->graph keyEnumerator]; NSString *root;
  while((root=[it nextObject])) {
    NSDictionary *record=[context_->graph objectForKey:root];
    if(![[record objectForKey:RCRecordEntityNameKey] isEqual:@"com.apple.calendars.Calendar"]) continue;
    id calendar=[self container:root create:YES error:error]; if(!calendar) return NO;
    NSString *title=[record objectForKey:@"title"] ?: @"rCloud Calendar";
    NSString *key=[@"@" stringByAppendingString:root];
    NSDictionary *saved=RCLoadNative(context_->journal,key,error); if(!saved) return NO;
    NSString *previous=[saved objectForKey:@"title"], *current=[calendar valueForKey:@"title"];
    if(previous && ![current isEqual:previous] && ![current isEqual:title]) {
      RCErrorSet(error,1,"Local calendar rename requires attention; preserving its title"); return NO;
    }
    if(![current isEqual:title]) {
      [calendar setValue:title forKey:@"title"];
      if(!EKSave(events_,NSSelectorFromString(@"saveCalendar:commit:error:"),calendar,NO,error)) return NO;
    }
    NSDictionary *resource=[NSDictionary dictionaryWithObjectsAndKeys:key,@"root",title,@"title",nil];
    if(!RCSaveNative(context_->journal,resource,[saved objectForKey:@"_ids"],nil,NO,error)) return NO;
  }
  return YES;
}
- (NSDictionary *)savedResources:(RCError *)error
{
  sqlite3_stmt *q=NULL; NSMutableDictionary *result=[NSMutableDictionary dictionary]; int step=SQLITE_ERROR;
  NSMutableArray *roots=[NSMutableArray array];
  RCWriteJournal j=context_->journal;
  if(sqlite3_prepare_v2(j.db,"SELECT root FROM native_store_resources WHERE account_id=? AND root NOT LIKE '@%'",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account);
    while((step=sqlite3_step(q))==SQLITE_ROW) {
      [roots addObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)]];
    }
  }
  sqlite3_finalize(q);
  if(step!=SQLITE_DONE) { if(!error->code) RCErrorSet(error,1,"Could not read native resources"); return nil; }
  for(NSString *root in roots) {
    NSDictionary *r=RCLoadNative(j,root,error); if(!r) return nil;
    if([[r objectForKey:@"_pending"] boolValue]) {
      if(contacts_) { RCErrorSet(error,1,"An interrupted native save requires recovery; refusing duplicate creation"); return nil; }
      r=[self recoverCalendarResource:r error:error]; if(!r) return nil;
    } else if(!contacts_) {
      r=[self repairLegacyCalendarSnapshot:r error:error]; if(!r) return nil;
    }
    [result setObject:r forKey:root];
  }
  return result;
}
- (id)container:(NSString *)root create:(BOOL)create error:(RCError *)error
{
  if(!contacts_ && !root) { RCErrorSet(error,1,"Native resource has no calendar identity"); return nil; }
  NSString *key=contacts_ ? @"@contacts" : [@"@" stringByAppendingString:root];
  NSDictionary *saved=RCLoadNative(context_->journal,key,error); if(error->code) return nil;
  NSString *native=[[saved objectForKey:@"_ids"] objectForKey:key];
  id container=native ? (contacts_ ? [self groupForIdentifier:native] : [(EKEventStore *)events_ calendarWithIdentifier:native]) : nil;
  if(container) return container;
  if(saved) { RCErrorSet(error,1,"Managed native container is missing; refusing to infer resource deletions"); return nil; }
  if(!create) return nil;
  NSDictionary *resource=[NSDictionary dictionaryWithObject:key forKey:@"root"];
  if(contacts_) {
    NSString *title=[NSString stringWithFormat:@"rCloud (%@)",[context_->clientIdentifier substringFromIndex:[context_->clientIdentifier length]-8]];
    if(!RCSaveNative(context_->journal,resource,[NSDictionary dictionary],nil,YES,error)) return nil;
    container=[self createGroup:title error:error]; if(!container) return nil;
    native=[self contactIdentifier:container];
  } else {
    id source=nil; NSEnumerator *it=[[events_ valueForKey:@"sources"] objectEnumerator]; id candidate;
    while((candidate=[it nextObject])) if([[candidate valueForKey:@"sourceType"] integerValue]==0) { source=candidate; break; }
    if(!source) { RCErrorSet(error,1,"EventKit has no local source; create a local calendar first"); return nil; }
#if TARGET_OS_IPHONE
    if([EKCalendar respondsToSelector:@selector(calendarForEntityType:eventStore:)])
      container=[EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:events_];
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      container=[EKCalendar calendarWithEventStore:events_];
#pragma clang diagnostic pop
    }
#else
    container=[EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:events_];
#endif
    [container setValue:source forKey:@"source"];
    [container setValue:[[context_->graph objectForKey:root] objectForKey:@"title"] ?: @"rCloud Calendar" forKey:@"title"];
    if(!RCSaveNative(context_->journal,resource,[NSDictionary dictionary],nil,YES,error)) return nil;
    if(!EKSave(events_,NSSelectorFromString(@"saveCalendar:commit:error:"),container,NO,error)) return nil;
    native=[container valueForKey:@"calendarIdentifier"];
  }
  if(!native || !RCSaveNative(context_->journal,resource,[NSDictionary dictionaryWithObject:native forKey:key],nil,NO,error)) return nil;
  return container;
}
- (NSDictionary *)rawGraph:(NSDictionary *)saved error:(RCError *)error
{
  NSString *root=[saved objectForKey:@"root"]; NSDictionary *ids=[saved objectForKey:@"_ids"];
  if(contacts_) {
    if(![self container:nil create:NO error:error]) { if(!error->code) RCErrorSet(error,1,"Managed Contacts group is missing"); return nil; }
    return [self readContact:[self contactForIdentifier:[ids objectForKey:root]] root:root identifiers:ids error:error];
  }
  if(![self calendarAccess:error]) return nil;
  NSString *calendar=[[[saved objectForKey:@"graph"] objectForKey:root] objectForKey:@"calendar"] ?
      [[[[saved objectForKey:@"graph"] objectForKey:root] objectForKey:@"calendar"] objectAtIndex:0] : nil;
  id container=[self container:calendar create:NO error:error];
  if(!container) { if(!error->code) RCErrorSet(error,1,"Managed Calendar is missing"); return nil; }
  id event=[(EKEventStore *)events_ eventWithIdentifier:[ids objectForKey:root]];
  NSString *observedCalendar=calendar;
  if(event && ![[[event valueForKey:@"calendar"] valueForKey:@"calendarIdentifier"] isEqual:[container valueForKey:@"calendarIdentifier"]]) {
    /* Resolve by this account's durable container identities, never by title.
       An unrelated or missing destination cannot authorize a cloud move. */
    observedCalendar=nil;
    for(NSString *candidate in context_->graph) {
      NSDictionary *record=[context_->graph objectForKey:candidate];
      if(![[record objectForKey:RCRecordEntityNameKey]
          isEqual:@"com.apple.calendars.Calendar"] ||
          [[record objectForKey:@"read only"] boolValue]) continue;
      id destination=[self container:candidate create:NO error:error];
      if(error->code) return nil;
      if(destination && [[[event calendar] calendarIdentifier]
          isEqual:[destination calendarIdentifier]] &&
          [destination allowsContentModifications]) {
        if(observedCalendar) {
          RCErrorSet(error,1,"Moved event has an ambiguous managed calendar");
          return nil;
        }
        observedCalendar=candidate;
      }
    }
    if(!observedCalendar) {
      RCErrorSet(error,1,"Moved event is outside writable managed calendars; preserving the event (record=%.120s)",[root UTF8String]); return nil;
    }
  }
  NSDictionary *raw=EKRead(event,saved,NO,error); if(!raw) return nil;
  if(event && observedCalendar && ![observedCalendar isEqual:calendar]) {
    NSMutableDictionary *graph=[NSMutableDictionary dictionaryWithDictionary:raw];
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:
        [raw objectForKey:root]];
    [record setObject:[NSArray arrayWithObject:observedCalendar] forKey:@"calendar"];
    [graph setObject:record forKey:root]; raw=graph;
  }
  NSDictionary *base=[saved objectForKey:@"graph"], *snapshot=[saved objectForKey:@"_snapshot"];
  for(NSString *key in snapshot) {
    NSDictionary *old=[snapshot objectForKey:key], *now=[raw objectForKey:key];
    if(![base objectForKey:key] && now &&
        [[old objectForKey:RCRecordEntityNameKey] hasSuffix:@"Alarm"] &&
        !RCNativeRecordsEqual(old,now)) {
      RCErrorSet(error,1,"A native-only default alarm was edited; preserving the local edit and original wire alarms");
      return nil;
    }
  }
  return raw;
}
- (NSDictionary *)readResource:(NSDictionary *)saved error:(RCError *)error
{
  NSDictionary *raw=[self rawGraph:saved error:error];
  return raw ? RCChangedGraph([saved objectForKey:@"graph"],[saved objectForKey:@"_snapshot"],raw) : nil;
}
/* Read-only audit of the complete supported finite projection. Never use a
   master-only comparison as permission to replace a series. An unchanged
   unbounded master is a quiet capability limit, not a complete series audit.
   Large finite series remain uncertain; no partial scan claims completeness. */
- (NSString *)seriesAttention:(NSDictionary *)saved error:(RCError *)error
{
  if([[saved objectForKey:@"_pending"] boolValue]) return @"native-series-unverified";
  NSDictionary *raw=[self rawGraph:saved error:error];
  if(!raw) return @"native-series-unverified";
  if(![raw count]) return @"native-series-local-delete";
  NSDictionary *snapshot=[saved objectForKey:@"_snapshot"];
  if(!RCTwoWayGraphsEqual(snapshot,raw))
    return RCNativeCalendarRecurrenceOverflow(snapshot,raw,[saved objectForKey:@"root"])
        ? @"native-series-date-overflow" : @"native-series-local-edit";
  NSString *root=[saved objectForKey:@"root"], *identifier=[[saved objectForKey:@"_ids"] objectForKey:root];
  EKEvent *master=[(EKEventStore *)events_ eventWithIdentifier:identifier];
  if(!master || ![master respondsToSelector:@selector(calendarItemIdentifier)]) return @"native-series-unverified";
  NSString *seriesID=[master calendarItemIdentifier];
  if(![seriesID length]) return @"native-series-unverified";
  NSData *body=[saved objectForKey:@"body"];
  NSString *text=[[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease];
  icalcomponent *wire=text ? icalparser_parse_string([text UTF8String]) : NULL;
  if(!wire) return @"native-series-unverified";
  icalrecur_iterator *iterator=NULL;
  NSString *reason=@"native-series-unverified";
  @try {
    icalcomponent *event=icalcomponent_get_first_component(wire,ICAL_VEVENT_COMPONENT);
    if(!event || icalcomponent_get_next_component(wire,ICAL_VEVENT_COMPONENT) ||
        icalcomponent_count_properties(event,ICAL_RRULE_PROPERTY)!=1 ||
        icalcomponent_count_properties(event,ICAL_RDATE_PROPERTY) ||
        icalcomponent_count_properties(event,ICAL_EXRULE_PROPERTY)) return reason;
    struct icalrecurrencetype rule=icalproperty_get_rrule(icalcomponent_get_first_property(event,ICAL_RRULE_PROPERTY));
    if(!rule.count && icaltime_is_null_time(rule.until))
      return @"native-series-open-ended";
    struct icaltimetype start=icalcomponent_get_dtstart(event), occurrence;
    struct icaldurationtype duration=icalcomponent_get_duration(event);
    if(start.year<1900 || start.year>2100) return reason;
    icalproperty *startProperty=icalcomponent_get_first_property(event,ICAL_DTSTART_PROPERTY);
    const char *tzid=RCICalendarTZID(startProperty);
    NSTimeZone *zone=start.is_date || icaltime_is_utc(start) ? [NSTimeZone timeZoneForSecondsFromGMT:0] :
        (tzid ? [NSTimeZone timeZoneWithName:[NSString stringWithUTF8String:tzid]] : [NSTimeZone localTimeZone]);
    if(!zone) return reason;
    iterator=icalrecur_iterator_new(rule,start); if(!iterator) return reason;
    NSMutableDictionary *expected=[NSMutableDictionary dictionary];
    NSDate *first=nil,*last=nil;
    while(!icaltime_is_null_time(occurrence=icalrecur_iterator_next(iterator))) {
      struct icaltimetype finish=icaltime_add(occurrence,duration);
      if([expected count]>=1000 || occurrence.year>2100 || finish.year>2100) return reason;
      NSDate *begin=RCCalendarWallDate(occurrence,zone), *end=RCCalendarWallDate(finish,zone);
      if(!begin || !end || [end compare:begin]==NSOrderedAscending) return reason;
      [expected setObject:end forKey:begin];
      if(!first) first=begin;
      last=end;
    }
    if(!first || !last) return reason;
    /* All-day snapshot dates use UTC wall time; EventKit query dates use local
       midnight. Pad the bounds so DST and zone offsets cannot drop an edge. */
    NSDate *queryStart=[NSDate dateWithTimeIntervalSinceReferenceDate:[first timeIntervalSinceReferenceDate]-172800];
    NSDate *queryEnd=[NSDate dateWithTimeIntervalSinceReferenceDate:[last timeIntervalSinceReferenceDate]+172800];
    NSMutableSet *seen=[NSMutableSet set];
    EKCalendar *calendar=[master calendar]; NSString *calendarID=[calendar calendarIdentifier];
    while([queryStart compare:queryEnd]==NSOrderedAscending) {
      if(RCCheckCancellation(error)) return reason;
      NSDate *end=[queryStart dateByAddingTimeInterval:365*86400.0];
      if([end compare:queryEnd]==NSOrderedDescending) end=queryEnd;
      NSAutoreleasePool *windowPool=[[NSAutoreleasePool alloc] init];
      @try {
      NSPredicate *predicate=[(EKEventStore *)events_ predicateForEventsWithStartDate:queryStart endDate:end calendars:[NSArray arrayWithObject:calendar]];
      NSArray *matches=[(EKEventStore *)events_ eventsMatchingPredicate:predicate];
      if(![[[(EKEventStore *)events_ calendarWithIdentifier:calendarID] calendarIdentifier] isEqual:calendarID]) {
        RCErrorSet(error,1,"Calendar unavailable during recurring-series audit"); return reason;
      }
      for(EKEvent *item in matches) {
        if(![[item calendarItemIdentifier] isEqual:seriesID]) continue;
        if([item isDetached]) return @"native-series-occurrence-edit";
        NSDictionary *observed=EKRead(item,saved,NO,error); if(!observed) return reason;
        NSDictionary *record=[observed objectForKey:root]; NSDate *date=[record objectForKey:@"start date"];
        NSDate *expectedEnd=[expected objectForKey:date];
        if(!expectedEnd) return @"native-series-occurrence-edit";
        NSMutableDictionary *wanted=[NSMutableDictionary dictionaryWithDictionary:snapshot];
        NSMutableDictionary *fields=[NSMutableDictionary dictionaryWithDictionary:[snapshot objectForKey:root]];
        [fields setObject:date forKey:@"start date"]; [fields setObject:expectedEnd forKey:@"end date"];
        [wanted setObject:fields forKey:root];
        if(!RCTwoWayGraphsEqual(wanted,observed)) return @"native-series-occurrence-edit";
        [seen addObject:date];
      }
      } @catch(id exception) { RCDrainPoolPreservingException(&windowPool,exception); @throw; }
      @finally { [windowPool release]; }
      queryStart=end;
    }
    if([seen count]!=[expected count]) return @"native-series-occurrence-missing";
    return nil;
  } @finally { if(iterator) icalrecur_iterator_free(iterator); icalcomponent_free(wire); }
}
/* Before audio support, the ordinal reader could label Mavericks' implicit
   Basso default as display and shift a real reminder to a synthetic key. Only
   migrate the exact unchanged legacy receipt, even without source reminders:
   no native or wire data is saved. */
- (NSDictionary *)repairLegacyCalendarSnapshot:(NSDictionary *)saved error:(RCError *)error
{
  NSString *root=[saved objectForKey:@"root"];
  NSDictionary *base=[saved objectForKey:@"graph"], *snapshot=[saved objectForKey:@"_snapshot"];
  NSDictionary *source=[base objectForKey:root], *old=[snapshot objectForKey:root];
  NSArray *sourceKeys=[source objectForKey:@"display alarms"], *oldKeys=[old objectForKey:@"display alarms"];
  NSUInteger count=[sourceKeys count];
  if(![[source objectForKey:@"all day"] boolValue] ||
      [[source objectForKey:@"audio alarms"] count] || [[source objectForKey:@"recurrences"] count] ||
      [oldKeys count]!=count+1 || [[old objectForKey:@"audio alarms"] count] || [snapshot count]!=count+2)
    return saved;
  NSMutableArray *oldAlarms=[NSMutableArray array];
  for(NSString *key in oldKeys) {
    NSDictionary *alarm=[snapshot objectForKey:key]; if(!alarm) return saved;
    [oldAlarms addObject:alarm];
  }
  NSArray *calendars=[source objectForKey:@"calendar"]; if([calendars count]!=1) goto unsafe;
  id calendar=[self container:[calendars objectAtIndex:0] create:NO error:error]; if(!calendar) goto unsafe;
  NSString *identifier=[[saved objectForKey:@"_ids"] objectForKey:root];
  EKEvent *event=identifier ? [(EKEventStore *)events_ eventWithIdentifier:identifier] : nil;
  if(!event || ![[[event calendar] calendarIdentifier] isEqual:[calendar calendarIdentifier]] ||
      [event isDetached] || [[event recurrenceRules] count]) goto unsafe;
  NSMutableDictionary *resource=[NSMutableDictionary dictionaryWithDictionary:saved];
  [resource removeObjectForKey:@"_snapshot"]; [resource removeObjectForKey:@"_ids"]; [resource removeObjectForKey:@"_pending"];
  NSDictionary *current=EKRead(event,resource,NO,error); if(!current) return nil;
  NSDictionary *now=[current objectForKey:root];
  if([[now objectForKey:@"display alarms"] count]!=count || [[now objectForKey:@"audio alarms"] count]!=1 || [current count]!=count+2) goto unsafe;
  NSMutableDictionary *oldFields=[NSMutableDictionary dictionaryWithDictionary:old], *nowFields=[NSMutableDictionary dictionaryWithDictionary:now];
  for(NSString *link in [NSArray arrayWithObjects:@"display alarms",@"audio alarms",nil]) {
    [oldFields removeObjectForKey:link]; [nowFields removeObjectForKey:link];
  }
  if(!RCNativeRecordsEqual(oldFields,nowFields)) goto unsafe;
  // The real reminders must still equal their source projections. The
  // additional Basso reminder is the precise default the old reader mistyped.
  for(NSString *key in sourceKeys) {
    EKAlarm *planned=EKMakeAlarm([base objectForKey:key],NO,error); if(!planned) return nil;
    if(!RCNativeRecordsEqual(EKAlarmRecord(planned,root,error),[current objectForKey:key])) goto unsafe;
  }
  NSDictionary *defaultAlarm=[current objectForKey:[[now objectForKey:@"audio alarms"] objectAtIndex:0]];
  if([defaultAlarm objectForKey:@"triggerdate"] || [[defaultAlarm objectForKey:@"triggerduration"] intValue]!=-54000 ||
      ![[defaultAlarm objectForKey:@"com.apple.ical.sound"] isEqual:[EKSystemSounds() objectForKey:@"Basso"]]) goto unsafe;
  for(NSString *link in [NSArray arrayWithObjects:@"display alarms",@"audio alarms",nil]) for(NSString *key in [now objectForKey:link]) {
    NSMutableDictionary *alarm=[NSMutableDictionary dictionaryWithDictionary:[current objectForKey:key]];
    if([link isEqual:@"audio alarms"]) {
      [alarm setObject:@"com.apple.calendars.DisplayAlarm" forKey:RCRecordEntityNameKey];
      [alarm removeObjectForKey:@"com.apple.ical.sound"];
    }
    NSUInteger index=NSNotFound;
    for(NSUInteger n=0;n<[oldAlarms count];n++) if(RCNativeRecordsEqual(alarm,[oldAlarms objectAtIndex:n])) { index=n; break; }
    if(index==NSNotFound) goto unsafe;
    [oldAlarms removeObjectAtIndex:index];
  }
  if([oldAlarms count]) goto unsafe;
  if(!RCSaveNative(context_->journal,resource,[saved objectForKey:@"_ids"],current,NO,error)) return nil;
  RCLogger(RCLogInfo,NULL,"Recovery",@"Repaired verified legacy calendar alarm snapshot (record=%@)",root);
  return RCLoadNative(context_->journal,root,error);
unsafe:
  if(!error->code) RCErrorSet(error,1,"Legacy calendar alarm snapshot no longer matches the native event; preserving local edits");
  return nil;
}
- (NSDictionary *)recoverCalendarResource:(NSDictionary *)saved error:(RCError *)error
{
  NSString *root=[saved objectForKey:@"root"];
  NSDictionary *record=[[saved objectForKey:@"graph"] objectForKey:root];
  NSArray *calendars=[record objectForKey:@"calendar"];
  if([calendars count]!=1 || [[record objectForKey:@"recurrences"] count]) goto unsafe;
  id calendar=[self container:[calendars objectAtIndex:0] create:NO error:error];
  if(!calendar) goto unsafe;
  EKEvent *planned=[EKEvent eventWithEventStore:events_];
  if(!EKWrite(planned,calendar,saved,error)) return nil;
  NSDictionary *expected=EKRead(planned,saved,YES,error); if(!expected) return nil;
  NSString *identifier=[[saved objectForKey:@"_ids"] objectForKey:root];
  NSArray *candidates=nil;
  if(identifier) {
    EKEvent *event=[(EKEventStore *)events_ eventWithIdentifier:identifier];
    candidates=event ? [NSArray arrayWithObject:event] : [NSArray array];
  } else {
#if TARGET_OS_IPHONE
    goto unsafe; /* No legacy Mac identifier recovery applies to iOS. */
#endif
    /* Old releases lost the new identifier when all-day readback failed.
       Search only this narrowly identified failure in its owned calendar.
       Never create a replacement or guess between equal candidates. */
    if(![[record objectForKey:@"all day"] boolValue] ||
        [[record objectForKey:@"audio alarms"] count]!=1 ||
        [[record objectForKey:@"display alarms"] count]) goto unsafe;
    /* Mavericks all-day queries need whole-day bounds, not seconds around
       midnight. Full native-field comparison below still verifies the date. */
    NSDate *start=[planned startDate];
    NSPredicate *predicate=[(EKEventStore *)events_ predicateForEventsWithStartDate:
        [start dateByAddingTimeInterval:-86400] endDate:[start dateByAddingTimeInterval:86400]
        calendars:[NSArray arrayWithObject:calendar]];
    candidates=[(EKEventStore *)events_ eventsMatchingPredicate:predicate];
  }
  NSMutableSet *owned=[NSMutableSet set]; sqlite3_stmt *q=NULL;
  RCWriteJournal j=context_->journal; int step=SQLITE_ERROR;
  if(sqlite3_prepare_v2(j.db,"SELECT root,native FROM native_store_resources WHERE account_id=? AND root<>?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account); sqlite3_bind_text(q,2,[root UTF8String],-1,SQLITE_TRANSIENT);
    while((step=sqlite3_step(q))==SQLITE_ROW) {
      NSString *other=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
      NSString *native=[RCDecode(q,1) objectForKey:other]; if(native) [owned addObject:native];
    }
  }
  sqlite3_finalize(q);
  if(step!=SQLITE_DONE) { RCErrorSet(error,1,"Could not verify recovery ownership"); return nil; }
  EKEvent *match=nil;
  for(EKEvent *event in candidates) {
    if([owned containsObject:[event eventIdentifier]] ||
        ![[[event calendar] calendarIdentifier] isEqual:[calendar calendarIdentifier]] ||
        [event isDetached] || [[event recurrenceRules] count]) continue;
    RCError candidateError; RCErrorClear(&candidateError);
    NSDictionary *current=EKRead(event,saved,YES,&candidateError);
    if(current && RCNativeGraphsEqual(current,expected)) {
      if(match) goto unsafe;
      match=event;
    }
  }
  if(!match) goto unsafe;
  NSMutableDictionary *resource=[NSMutableDictionary dictionaryWithDictionary:saved];
  [resource removeObjectForKey:@"_ids"]; [resource removeObjectForKey:@"_snapshot"];
  [resource removeObjectForKey:@"_pending"];
  NSDictionary *ids=[NSDictionary dictionaryWithObject:[match eventIdentifier] forKey:root];
  /* Checkpoint the verified identity before repairing the old duplicate. A
     crash at any later point retries this event, never creates another one. */
  if(!RCSaveNative(j,resource,ids,expected,YES,error)) return nil;
  if(!EKRepairDefaultAlarm(events_,match,resource,error)) return nil;
  NSDictionary *snapshot=EKRead(match,resource,NO,error);
  if(!snapshot || !RCNativeGraphsEqual(snapshot,expected)) goto unsafe;
  if(!RCTwoWaySQL(&j,error,"SAVEPOINT native_calendar_recovery")) return nil;
  if(!RCSaveNative(j,resource,ids,snapshot,NO,error) ||
      !RCTwoWaySQL(&j,error,"DELETE FROM two_way_attention WHERE account_id=%lld AND record_id=%Q AND reason='native-publication-pending'",j.account,[root UTF8String]) ||
      !RCTwoWaySQL(&j,error,"RELEASE native_calendar_recovery")) {
    RCTwoWaySQL(&j,NULL,"ROLLBACK TO native_calendar_recovery; RELEASE native_calendar_recovery");
    return nil;
  }
  RCLogger(RCLogInfo,NULL,"Recovery",@"Recovered verified native calendar publication (record=%@)",root);
  return RCLoadNative(j,root,error);
unsafe:
  if(!error->code) RCErrorSet(error,1,"Pending calendar save has no unique unchanged native match; refusing duplicate creation");
  return nil;
}
- (BOOL)canPublishResource:(NSDictionary *)resource error:(RCError *)error
{
  return contacts_ || EKCanWrite(resource,error);
}
- (BOOL)publishResource:(NSDictionary *)resource error:(RCError *)error
{
  if(RCCheckCancellation(error)) return NO;
  NSString *root=[resource objectForKey:@"root"];
  NSDictionary *saved=RCLoadNative(context_->journal,root,error); if(error->code) return NO;
  if([[saved objectForKey:@"_pending"] boolValue]) { RCErrorSet(error,1,"Native publication requires recovery from interrupted save"); return NO; }
  NSMutableDictionary *ids=[NSMutableDictionary dictionaryWithDictionary:[saved objectForKey:@"_ids"] ?: [NSDictionary dictionary]];
  id item=nil,container=nil;
  if(contacts_) {
    container=[self container:nil create:YES error:error]; if(!container) return NO;
    item=[ids objectForKey:root] ? [self contactForIdentifier:[ids objectForKey:root]] : nil;
    if(!item) { item=[self makeContact:error]; if(!item) return NO; }
    if(![self writeContact:item resource:resource identifiers:ids error:error]) return NO;
    if(![self addContact:item toGroup:container error:error]) return NO;
  } else {
    if(!EKCanWrite(resource,error)) return NO;
    NSArray *calendars=[[[resource objectForKey:@"graph"] objectForKey:root] objectForKey:@"calendar"];
    if([calendars count]!=1) { RCErrorSet(error,1,"Event has no unambiguous calendar"); return NO; }
    container=[self container:[calendars objectAtIndex:0] create:YES error:error]; if(!container) return NO;
    item=[ids objectForKey:root] ? [(EKEventStore *)events_ eventWithIdentifier:[ids objectForKey:root]] : nil;
    if(!item) item=[EKEvent eventWithEventStore:events_];
    if(!item || !EKWrite(item,container,resource,error)) return NO;
  }
  NSDictionary *expectedDates=contacts_ ? nil : EKRead(item,resource,NO,error);
  if(!contacts_ && !expectedDates) return NO;
  /* Reservation precedes native commit. An ambiguous crash blocks replay rather
     than manufacturing a duplicate record. Completed saves are idempotent. */
  if(!RCSaveNative(context_->journal,resource,ids,[saved objectForKey:@"_snapshot"],YES,error)) return NO;
  if(contacts_) {
    if(![self saveContacts:error]) return NO;
    NSString *native=[self contactIdentifier:item]; if(!native) goto failed;
    [ids setObject:native forKey:root];
    if(!RCSaveNative(context_->journal,resource,ids,nil,YES,error)) return NO;
  }
  else {
    if(!EKSave(events_,NSSelectorFromString(@"saveEvent:span:commit:error:"),item,YES,error)) return NO;
    NSString *native=[item valueForKey:@"eventIdentifier"]; if(!native) goto failed; [ids setObject:native forKey:root];
    if(!RCSaveNative(context_->journal,resource,ids,nil,YES,error)) return NO;
    if(!EKRepairDefaultAlarm(events_,item,resource,error)) return NO;
    /* A saved EKEvent may still expose its unsaved-width date values. Reload
       from EventKit's persistent store before accepting the publication. */
    [(EKEventStore *)events_ reset];
    item=[(EKEventStore *)events_ eventWithIdentifier:native];
    NSDictionary *persisted=item ? EKRead(item,resource,NO,error) : nil;
    if(!persisted || !RCNativeCalendarDatesEqual(expectedDates,persisted,root)) {
      if(!error->code) RCErrorSet(error,1,"EventKit changed persisted calendar dates; publication retained for recovery");
      return NO;
    }
  }
  NSDictionary *snapshot=contacts_ ? [self readContact:item root:root identifiers:ids error:error] : EKRead(item,resource,NO,error);
  if(!snapshot) return NO;
  return RCSaveNative(context_->journal,resource,ids,snapshot,NO,error);
failed:
  RCErrorSet(error,1,"Native store rejected publication; check access and local store availability"); return NO;
}
- (BOOL)removeResource:(NSDictionary *)saved error:(RCError *)error
{
  if(RCCheckCancellation(error)) return NO;
  NSString *root=[saved objectForKey:@"root"],*native=[[saved objectForKey:@"_ids"] objectForKey:root];
  if(![self rawGraph:saved error:error]) return NO;
  id item=contacts_ ? [self contactForIdentifier:native] : [(EKEventStore *)events_ eventWithIdentifier:native];
  if(item) {
    if(contacts_) { if(![self removeContact:item error:error]) return NO; }
    else if(!EKSave(events_,NSSelectorFromString(@"removeEvent:span:commit:error:"),item,YES,error)) return NO;
  }
  return RCTwoWaySQL(&context_->journal,error,"DELETE FROM native_store_resources WHERE account_id=%lld AND root=%Q",context_->journal.account,[root UTF8String]);
}
- (BOOL)rememberResource:(NSDictionary *)resource native:(NSDictionary *)saved error:(RCError *)error
{
  return RCSaveNative(context_->journal,resource,[saved objectForKey:@"_ids"],[saved objectForKey:@"_snapshot"],NO,error);
}
- (BOOL)untrackedCalendarDeleted:(NSString *)root error:(RCError *)error;
{
  NSString *prefix=@"native-event-";
  if(contacts_ || ![root hasPrefix:prefix] ||
      [root length]==[prefix length]) return NO;
  if(![self calendarAccess:error]) return NO;
  /* An empty/unavailable store must never prove deletion. The successful
     discovery pass also verified every managed calendar before this lookup. */
  BOOL managed=NO;
  for(NSDictionary *record in [context_->graph allValues])
    if([[record objectForKey:RCRecordEntityNameKey]
        isEqual:@"com.apple.calendars.Calendar"]) managed=YES;
  if(!managed || ![[events_ valueForKey:@"sources"] count]) {
    RCErrorSet(error,1,"Calendar store unavailable during attention review");
    return NO;
  }
  id event=[(EKEventStore *)events_ eventWithIdentifier:
      [root substringFromIndex:[prefix length]]];
  if(![self calendarAccess:error]) return NO;
  return event==nil;
}
- (NSArray *)untrackedResources:(RCError *)error
{
  NSDictionary *saved=[self savedResources:error]; if(!saved) return nil;
  NSMutableSet *known=[NSMutableSet set]; NSEnumerator *it=[saved objectEnumerator]; NSDictionary *r;
  while((r=[it nextObject])) { NSString *native=[[r objectForKey:@"_ids"] objectForKey:[r objectForKey:@"root"]]; if(native) [known addObject:native]; }
  NSMutableArray *result=[NSMutableArray array];
  if(contacts_) {
    id group=[self container:nil create:NO error:error]; if(error->code) return nil;
    NSArray *members=[self groupMembers:group error:error]; if(error->code) return nil;
    it=[members objectEnumerator]; id person;
    while((person=[it nextObject])) if(![known containsObject:[self contactIdentifier:person]]) {
      NSString *root=[@"native-contact-" stringByAppendingString:[self contactIdentifier:person]];
      NSDictionary *ids=[NSDictionary dictionaryWithObject:[self contactIdentifier:person] forKey:root], *graph=[self readContact:person root:root identifiers:ids error:error];
      if(!graph) return nil;
      [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",graph,@"graph",ids,@"_ids",graph,@"_snapshot",nil]];
    }
  } else {
    /* Search only managed calendars, in bounded four-year windows (EventKit's
       predicate limit). Existing resource lookups never depend on this window. */
    NSEnumerator *calendars=[context_->graph keyEnumerator]; NSString *calendar;
    while((calendar=[calendars nextObject])) if([[[context_->graph objectForKey:calendar] objectForKey:RCRecordEntityNameKey] isEqual:@"com.apple.calendars.Calendar"]) {
      id container=[self container:calendar create:NO error:error]; if(error->code) return nil;
      if(!container) { RCErrorSet(error,1,"Managed Calendar is missing during discovery"); return nil; }
      NSString *calendarID=[container calendarIdentifier];
      if(![calendarID length]) { RCErrorSet(error,1,"Managed calendar identity is unavailable; local inventory is incomplete"); return nil; }
      int year; for(year=1970;year<2100;year+=4) {
        NSAutoreleasePool *windowPool=[[NSAutoreleasePool alloc] init];
        @try {
        if(RCCheckCancellation(error)) return nil;
        NSDate *start=[RCCalendarDate dateWithYear:year month:1 day:1 hour:0 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        NSDate *end=[RCCalendarDate dateWithYear:year+4 month:1 day:1 hour:0 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        /* EventKit sends predicate dates to calaccessd. RCCalendarDate archives
           its application-only class, which the service cannot decode. Keep
           that class in our journal, but send Foundation dates across IPC. */
        start=[NSDate dateWithTimeIntervalSinceReferenceDate:[start timeIntervalSinceReferenceDate]];
        end=[NSDate dateWithTimeIntervalSinceReferenceDate:[end timeIntervalSinceReferenceDate]];
        NSPredicate *predicate=[(EKEventStore *)events_ predicateForEventsWithStartDate:start endDate:end calendars:[NSArray arrayWithObject:container]];
        RCLogger(RCLogDebug,"Calendars","LocalScan",@"Querying managed calendar window %d-%d",year,year+4);
        NSArray *matches=[(EKEventStore *)events_ eventsMatchingPredicate:predicate];
        /* Older EventKit returns nil for an empty date window too. Verify
           the owned calendar is still available before accepting that result. */
        EKCalendar *available=[(EKEventStore *)events_ calendarWithIdentifier:calendarID];
        if(![[available calendarIdentifier] isEqual:calendarID]) {
          RCErrorSet(error,1,"EventKit local event query failed for %d-%d; inventory is incomplete",year,year+4);
          return nil;
        }
        RCLogger(RCLogDebug,"Calendars","LocalScan",@"Completed managed calendar window %d-%d (%lu events)",year,year+4,(unsigned long)[matches count]);
        NSEnumerator *items=[matches objectEnumerator]; id event;
        while((event=[items nextObject])) {
          NSString *native=[event valueForKey:@"eventIdentifier"]; if(!native || [known containsObject:native]) continue; [known addObject:native];
          NSString *root=[@"native-event-" stringByAppendingString:native];
          NSDictionary *record=[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:calendar] forKey:@"calendar"];
          NSDictionary *stub=[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",[NSDictionary dictionaryWithObject:record forKey:root],@"graph",nil];
          NSDictionary *graph=EKRead(event,stub,NO,error), *ids=[NSDictionary dictionaryWithObject:native forKey:root];
          if(!graph) return nil;
          if(!graph) return nil;
      [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",graph,@"graph",ids,@"_ids",graph,@"_snapshot",[NSNumber numberWithBool:[event isDetached]],@"detached",nil]];
        }
        } @catch(id exception) { RCDrainPoolPreservingException(&windowPool,exception); @throw; }
        @finally { [windowPool release]; }
      }
    }
  }
  return result;
}
- (BOOL)captureReceipt:(NSDictionary *)receipt operation:(long long)operation
    scopes:(NSDictionary *)scopes resource:(NSDictionary *)resource
    error:(RCError *)error;
{
  NSDictionary *raw=[self rawGraph:resource error:error];
  if(!raw) return NO;
  NSDictionary *truth=RCChangedGraph([resource objectForKey:@"graph"],
      [resource objectForKey:@"_snapshot"],raw);
  if(!RCNativeScopeMatches(truth,receipt,scopes)) {
    RCErrorSet(error,1,"Native edit changed while preparing its upload");
    return NO;
  }
  sqlite3_stmt *q=NULL; RCWriteJournal j=context_->journal;
  BOOL ok=sqlite3_prepare_v2(j.db,
      "INSERT INTO native_upload_receipts VALUES(?,?,?,?,?)",-1,&q,NULL)==SQLITE_OK;
  if(ok) {
    NSData *ids=[NSKeyedArchiver archivedDataWithRootObject:[resource objectForKey:@"_ids"]];
    NSData *snapshot=[NSKeyedArchiver archivedDataWithRootObject:raw];
    sqlite3_bind_int64(q,1,operation); sqlite3_bind_int64(q,2,j.account);
    sqlite3_bind_text(q,3,[[resource objectForKey:@"root"] UTF8String],-1,SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,4,[ids bytes],(int)[ids length],SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,5,[snapshot bytes],(int)[snapshot length],SQLITE_TRANSIENT);
    ok=sqlite3_step(q)==SQLITE_DONE;
  }
  sqlite3_finalize(q);
  if(!ok) RCErrorSet(error,1,"Could not save native upload receipt");
  return ok;
}
- (BOOL)acceptReceipt:(NSDictionary *)receipt operation:(long long)operation
    scopes:(NSDictionary *)scopes newerTruth:(NSDictionary **)newer
    error:(RCError *)error;
{
  /* Never read unrelated native objects while acknowledging this operation.
     The captured readback is immutable, just like the GET-verified wire result.
     Advancing to it leaves subsequent edits visible on the next exchange. */
  RCWriteJournal j=context_->journal; sqlite3_stmt *q=NULL;
  NSDictionary *captured=nil,*capturedIDs=nil; NSString *capturedRoot=nil;
  if(sqlite3_prepare_v2(j.db,"SELECT root,native,snapshot FROM native_upload_receipts WHERE operation_id=? AND account_id=?",-1,&q,NULL)!=SQLITE_OK) {
    RCErrorSet(error,1,"Could not read native upload receipt"); return NO;
  }
  sqlite3_bind_int64(q,1,operation); sqlite3_bind_int64(q,2,j.account);
  int step=sqlite3_step(q);
  if(step==SQLITE_ROW) {
    capturedRoot=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
    capturedIDs=RCDecode(q,1); captured=RCDecode(q,2);
  }
  sqlite3_finalize(q);
  if(step!=SQLITE_ROW && step!=SQLITE_DONE) {
    RCErrorSet(error,1,"Could not read native upload receipt"); return NO;
  }
  if(step==SQLITE_ROW && (!capturedRoot ||
      ![capturedIDs isKindOfClass:[NSDictionary class]] ||
      ![captured isKindOfClass:[NSDictionary class]])) {
    RCErrorSet(error,1,"Invalid native upload receipt"); return NO;
  }
  NSMutableDictionary *saved=[NSMutableDictionary dictionary];
  for(NSString *key in (capturedRoot ? [NSArray arrayWithObject:capturedRoot] : [receipt allKeys])) {
    NSDictionary *r=RCLoadNative(j,key,error); if(error->code) return NO;
    if([[r objectForKey:@"_pending"] boolValue]) {
      RCErrorSet(error,1,"An interrupted native save requires reconciliation");
      return NO;
    }
    if(r) [saved setObject:r forKey:key];
  }
  if(captured && ![capturedIDs isEqual:[[saved objectForKey:capturedRoot] objectForKey:@"_ids"]]) {
    RCErrorSet(error,1,"Native upload ownership changed; reconciliation required"); return NO;
  }
  NSMutableDictionary *truth=[NSMutableDictionary dictionary];
  NSEnumerator *it=[saved objectEnumerator]; NSDictionary *r;
  if(!captured) {
    /* Upgrade path: a queued creation already checkpointed its exact observed
       graph. A later edit cannot invalidate that historical receipt. Older
       updates still need a scoped read because no raw receipt was persisted. */
    while((r=[it nextObject])) [truth addEntriesFromDictionary:[r objectForKey:@"graph"]];
    if(RCNativeScopeMatches(truth,receipt,scopes) && [saved count]==1) {
      captured=[[[saved allValues] objectAtIndex:0] objectForKey:@"_snapshot"];
    }
    if(!captured) {
      [truth removeAllObjects]; it=[saved objectEnumerator];
      while((r=[it nextObject])) {
        NSDictionary *graph=[self readResource:r error:error]; if(!graph) return NO;
        [truth addEntriesFromDictionary:graph];
      }
    }
  }
  if(newer) *newer=captured ? nil : truth;
  if(!captured && !RCNativeScopeMatches(truth,receipt,scopes)) { RCErrorSet(error,1,"Newer native edits remain pending"); return NO; }
  /* Advance only the acknowledged fields in the native baseline. Otherwise a
     successful upload would be detected again as a fresh local edit next poll. */
  it=[saved objectEnumerator];
  while((r=[it nextObject])) {
    NSMutableDictionary *base=[NSMutableDictionary dictionaryWithDictionary:[r objectForKey:@"graph"]];
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionaryWithDictionary:[r objectForKey:@"_snapshot"]];
    NSDictionary *raw=captured ?: [self rawGraph:r error:error]; if(!raw) return NO;
    BOOL touched=NO; NSEnumerator *ids=[receipt keyEnumerator]; NSString *key;
    while((key=[ids nextObject])) {
      id value=[receipt objectForKey:key];
      /* A newly acknowledged alarm belongs to this resource too. Omitting it
         from the baseline would rediscover the same addition on every read. */
      BOOL newAlarm=!contacts_ && [raw objectForKey:key] && [value isKindOfClass:[NSDictionary class]] &&
          [[value objectForKey:RCRecordEntityNameKey] hasSuffix:@"Alarm"] &&
          [[value objectForKey:@"owner"] containsObject:[r objectForKey:@"root"]];
      if(![base objectForKey:key] && ![[r objectForKey:@"root"] isEqual:key] && !newAlarm && !(captured && [raw objectForKey:key])) continue;
      touched=YES;
      if(value==[NSNull null]) { [base removeObjectForKey:key]; [snapshot removeObjectForKey:key]; }
      else {
        NSArray *fields=[scopes objectForKey:key];
        if(fields) {
          NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:[base objectForKey:key] ?: [NSDictionary dictionary]];
          NSMutableDictionary *observed=[NSMutableDictionary dictionaryWithDictionary:[snapshot objectForKey:key] ?: [NSDictionary dictionary]];
          NSEnumerator *f=[fields objectEnumerator]; NSString *field;
          while((field=[f nextObject])) { Put(record,field,[value objectForKey:field]); Put(observed,field,[[raw objectForKey:key] objectForKey:field]); }
          [base setObject:record forKey:key];
          /* Wire-only children (notably invitation participants) have no native
             snapshot. An empty placeholder would look like a deleted native
             record on the next read and remove it from the full wire graph. */
          Put(snapshot,key,[raw objectForKey:key] ? observed : nil);
        } else { [base setObject:value forKey:key]; Put(snapshot,key,[raw objectForKey:key]); }
      }
    }
    if(touched) {
      NSMutableDictionary *updated=[NSMutableDictionary dictionaryWithDictionary:r];
      [updated removeObjectForKey:@"_ids"]; [updated removeObjectForKey:@"_snapshot"]; [updated removeObjectForKey:@"_pending"];
      [updated setObject:base forKey:@"graph"];
      /* Subsequent edits must use the verified version, never the pre-upload
         ETag/body. A concurrent cloud edit still gets an If-Match conflict. */
      RCWriteOperation verified;
      if(!RCWriteJournalGet(&j,operation,&verified,error)) return NO;
      if(verified.resultBody && verified.resultETag) {
        [updated setObject:[NSData dataWithBytes:verified.resultBody
            length:verified.resultLength] forKey:@"body"];
        [updated setObject:[NSString stringWithUTF8String:verified.resultETag] forKey:@"etag"];
      }
      RCWriteOperationClear(&verified);
      sqlite3_stmt *paths=NULL;
      if(sqlite3_prepare_v2(j.db,"SELECT paths FROM two_way_intents WHERE operation_id=?",-1,&paths,NULL)!=SQLITE_OK) {
        RCErrorSet(error,1,"Could not read uploaded native paths"); return NO;
      }
      sqlite3_bind_int64(paths,1,operation);
      int pathStep=sqlite3_step(paths);
      if(pathStep==SQLITE_ROW) [updated setObject:RCDecode(paths,0) forKey:@"paths"];
      sqlite3_finalize(paths);
      if(pathStep!=SQLITE_ROW) { RCErrorSet(error,1,"Missing uploaded native paths"); return NO; }
      if(!RCSaveNative(context_->journal,updated,[r objectForKey:@"_ids"],snapshot,NO,error)) return NO;
    }
  }
  return YES;
}
@end

#endif
