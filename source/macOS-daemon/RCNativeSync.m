#import "RCNativeSync.h"
#import "RCAutorelease.h"
#import "RCLogger.h"
#import "RCSyncFieldScope.h"
#import "RCCalendarTime.h"
#if defined(__LP64__)
#import <EventKit/EventKit.h>
#import <AddressBook/AddressBook.h>
#import <CoreServices/CoreServices.h>

BOOL RCUsesNativeStoresForVersion(int major,int minor)
{
  return major>10 || (major==10 && minor>=9);
}
BOOL RCUsesNativeStores(void)
{
  SInt32 major=0,minor=0;
  return Gestalt(gestaltSystemVersionMajor,&major)==noErr &&
      Gestalt(gestaltSystemVersionMinor,&minor)==noErr && RCUsesNativeStoresForVersion(major,minor);
}
/* Only modern slices use EventKit. Ask once while permission is pending;
   repeated store initialization with the deprecated 10.8 initializer queues
   repeated dialogs on Mavericks. Never inspect an unauthorized empty store. */
static EKEventStore *eventRequester=nil;
static BOOL eventRequested=NO;
static BOOL RCEventAccess(RCError *error)
{
  EKAuthorizationStatus status=[EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
  if(status==EKAuthorizationStatusAuthorized) return YES;
  if(status==EKAuthorizationStatusNotDetermined) {
    @synchronized([EKEventStore class]) {
      if(!eventRequested) {
        eventRequested=YES;
        eventRequester=[[EKEventStore alloc] init];
        @try {
          [eventRequester requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted,NSError *failure) {
            (void)granted; (void)failure;
            @synchronized([EKEventStore class]) { [eventRequester release]; eventRequester=nil; }
          }];
        } @catch(NSException *exception) {
          [eventRequester release]; eventRequester=nil; @throw;
        }
      }
    }
  }
  RCErrorSet(error,1,"Calendar access is pending or denied; allow rCloud in Privacy > Calendars");
  return NO;
}
BOOL RCNativeWaitForAccess(BOOL contacts,RCError *error)
{
  RCErrorClear(error);
  if(RCCheckCancellation(error)) return NO;
  if(!RCUsesNativeStores()) return YES;
  @try {
    if(contacts) {
      if([ABAddressBook addressBook]) return !RCCheckCancellation(error);
      RCErrorSet(error,1,"Contacts access is unavailable; allow rCloud in Privacy > Contacts");
      return NO;
    }
    for(;;) {
      if(RCCheckCancellation(error)) return NO;
      RCErrorClear(error);
      if(RCEventAccess(error)) return YES;
      BOOL pending;
      @synchronized([EKEventStore class]) { pending=eventRequester!=nil; }
      // A completed denial or failed request is not retried in a tight loop.
      if(!pending) {
        // Approval may have arrived between the status read and callback check.
        if([EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent]==EKAuthorizationStatusAuthorized) {
          RCErrorClear(error); return YES;
        }
        return NO;
      }
      // This runs on the account worker; the daemon's main run loop stays live.
      [NSThread sleepForTimeInterval:0.1];
    }
  } @catch(NSException *exception) {
    (void)exception; RCErrorSet(error,1,"Could not request native privacy access"); return NO;
  }
}
void RCNativeRequestAccess(BOOL contacts,BOOL calendars)
{
  if(!RCUsesNativeStores() || RCStopRequested) return;
  RCError error; RCErrorClear(&error);
  @try {
    if(calendars) {
      RCLogger(RCLogInfo,"Calendars","Access",@"Checking Calendar access at startup");
      RCEventAccess(&error);
    }
    if(contacts && !RCStopRequested) {
      RCLogger(RCLogInfo,"Contacts","Access",@"Checking Contacts access at startup");
      if(!RCNativeWaitForAccess(YES,&error) && !RCStopRequested)
        RCLogger(RCLogWarning,"Contacts","Access",@"%s",error.message);
    }
  } @catch(NSException *exception) {
    (void)exception;
    RCLogger(RCLogWarning,"Account","Access",@"Native permission request failed; each service will check access before downloading");
  }
}
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
static NSDictionary *RCChangedGraph(NSDictionary *base,NSDictionary *snapshot,NSDictionary *current)
{
  /* Native stores normalize images, default labels, timezones and empty values.
     Compare against their readback, then apply only real edits to the wire graph. */
  NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:base];
  NSMutableSet *ids=[NSMutableSet setWithArray:[snapshot allKeys]]; [ids addObjectsFromArray:[current allKeys]];
  NSEnumerator *it=[ids objectEnumerator]; NSString *key;
  while((key=[it nextObject])) {
    NSDictionary *old=[snapshot objectForKey:key], *now=[current objectForKey:key];
    if(!now) { [result removeObjectForKey:key]; continue; }
    if(!old) { [result setObject:now forKey:key]; continue; }
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:[base objectForKey:key] ?: old];
    NSMutableSet *fields=[NSMutableSet setWithArray:[old allKeys]]; [fields addObjectsFromArray:[now allKeys]];
    NSEnumerator *f=[fields objectEnumerator]; NSString *field;
    while((field=[f nextObject])) {
      id a=[old objectForKey:field],b=[now objectForKey:field];
      if(a==b || [a isEqual:b]) continue;
      Put(record,field,b);
    }
    [result setObject:record forKey:key];
  }
  return result;
}
static NSString *ABLabel(NSDictionary *record)
{
  if([[record objectForKey:@"label"] length]) return [record objectForKey:@"label"];
  NSString *type=[record objectForKey:@"type"] ?: @"other";
  NSDictionary *labels=[NSDictionary dictionaryWithObjectsAndKeys:kABHomeLabel,@"home",kABWorkLabel,@"work",
      kABOtherLabel,@"other",kABPhoneMobileLabel,@"mobile",kABPhoneHomeFAXLabel,@"home fax",
      kABPhoneWorkFAXLabel,@"work fax",kABPhonePagerLabel,@"pager",kABHomePageLabel,@"home page",nil];
  return [labels objectForKey:type] ?: [NSString stringWithFormat:@"_$!<%@>!$_",[type capitalizedString]];
}
static void ABReadLabel(NSMutableDictionary *record,NSString *label)
{
  NSDictionary *types=[NSDictionary dictionaryWithObjectsAndKeys:@"home",kABHomeLabel,@"work",kABWorkLabel,
      @"other",kABOtherLabel,@"mobile",kABPhoneMobileLabel,@"home fax",kABPhoneHomeFAXLabel,
      @"work fax",kABPhoneWorkFAXLabel,@"pager",kABPhonePagerLabel,@"home page",kABHomePageLabel,nil];
  NSString *type=[types objectForKey:label ?: @""];
  if(!type && [label hasPrefix:@"_$!<"] && [label hasSuffix:@">!$_"])
    type=[[label substringWithRange:NSMakeRange(4,[label length]-8)] lowercaseString];
  [record setObject:type ?: @"other" forKey:@"type"];
  if(!type && [label length]) [record setObject:label forKey:@"label"];
}
static NSArray *ABFields(void)
{
  return [@"first name|last name|middle name|title|suffix|nickname|company name|department|job title|notes|birthday|first name yomi|last name yomi|middle name yomi" componentsSeparatedByString:@"|"];
}
static NSArray *ABProperties(void)
{
  return [NSArray arrayWithObjects:kABFirstNameProperty,kABLastNameProperty,kABMiddleNameProperty,kABTitleProperty,
      kABSuffixProperty,kABNicknameProperty,kABOrganizationProperty,kABDepartmentProperty,kABJobTitleProperty,
      kABNoteProperty,kABBirthdayProperty,kABFirstNamePhoneticProperty,kABLastNamePhoneticProperty,kABMiddleNamePhoneticProperty,nil];
}
static NSArray *ABRelations(void) { return [@"phone numbers|email addresses|street addresses|URLs|dates|related names|IMs|IMs|IMs|IMs|IMs" componentsSeparatedByString:@"|"]; }
static NSArray *ABMultiProperties(void)
{
  return [NSArray arrayWithObjects:kABPhoneProperty,kABEmailProperty,kABAddressProperty,kABURLsProperty,kABOtherDatesProperty,
      kABRelatedNamesProperty,kABAIMInstantProperty,kABJabberInstantProperty,kABMSNInstantProperty,kABYahooInstantProperty,kABICQInstantProperty,nil];
}
static NSArray *ABEntities(void) { return [@"Phone Number|Email Address|Street Address|URL|Date|Related Name|IM|IM|IM|IM|IM" componentsSeparatedByString:@"|"]; }
static NSArray *ABServices(void) { return [@"aim|jabber|msn|yahoo|icq" componentsSeparatedByString:@"|"]; }
static NSArray *ABAddressKeys(void) { return [@"street|city|state|postal code|country|country code" componentsSeparatedByString:@"|"]; }
static NSArray *ABAddressProperties(void) { return [NSArray arrayWithObjects:kABAddressStreetKey,kABAddressCityKey,kABAddressStateKey,kABAddressZIPKey,kABAddressCountryKey,kABAddressCountryCodeKey,nil]; }
static NSDictionary *ABRead(ABPerson *person,NSString *root,NSDictionary *ids)
{
  if(!person) return [NSDictionary dictionary];
  NSMutableDictionary *graph=[NSMutableDictionary dictionary], *record=[NSMutableDictionary dictionaryWithObject:@"com.apple.contacts.Contact" forKey:ISyncRecordEntityNameKey];
  NSArray *keys=ABFields(),*properties=ABProperties(); NSUInteger i,k;
  for(i=0;i<[keys count];i++) Put(record,[keys objectAtIndex:i],[person valueForProperty:[properties objectAtIndex:i]]);
  [record setObject:([[person valueForProperty:kABPersonFlags] intValue]&kABShowAsMask)==kABShowAsCompany ? @"company" : @"person" forKey:@"display as company"];
  Put(record,@"image",[person imageData]);
  for(k=0;k<[ABMultiProperties() count];k++) {
    NSString *property=[ABMultiProperties() objectAtIndex:k],*relation=[ABRelations() objectAtIndex:k];
    ABMultiValue *values=[person valueForProperty:property];
    NSMutableArray *children=[NSMutableArray arrayWithArray:[record objectForKey:relation] ?: [NSArray array]];
    for(i=0;i<[values count];i++) {
      NSString *native=[NSString stringWithFormat:@"%@/%@",property,[values identifierAtIndex:i]],*childID=nil;
      NSEnumerator *it=[ids keyEnumerator]; NSString *key;
      while((key=[it nextObject])) if([[ids objectForKey:key] isEqual:native]) { childID=key; break; }
      if(!childID) childID=[NSString stringWithFormat:@"%@/%@",root,native];
      NSMutableDictionary *child=[NSMutableDictionary dictionaryWithObjectsAndKeys:
          [@"com.apple.contacts." stringByAppendingString:[ABEntities() objectAtIndex:k]],ISyncRecordEntityNameKey,
          [NSArray arrayWithObject:root],@"contact",nil];
      ABReadLabel(child,[values labelAtIndex:i]);
      id value=[values valueAtIndex:i];
      if(k==2) { NSUInteger n; for(n=0;n<[ABAddressKeys() count];n++) Put(child,[ABAddressKeys() objectAtIndex:n],[value objectForKey:[ABAddressProperties() objectAtIndex:n]]); }
      else if(k>=6) { Put(child,@"user",value); Put(child,@"service",[ABServices() objectAtIndex:k-6]); }
      else Put(child,@"value",k==3 ? [NSURL URLWithString:value] : value);
      [children addObject:childID]; [graph setObject:child forKey:childID];
      if(k<4 && [[values primaryIdentifier] isEqual:[values identifierAtIndex:i]])
        [record setObject:[NSArray arrayWithObject:childID] forKey:[[@"primary phone number|primary email address|primary street address|primary URL" componentsSeparatedByString:@"|"] objectAtIndex:k]];
    }
    if([children count]) [record setObject:children forKey:relation];
  }
  [graph setObject:record forKey:root]; return graph;
}
static BOOL ABWrite(ABPerson *person,NSDictionary *resource,NSMutableDictionary *ids,RCError *error)
{
  NSString *root=[resource objectForKey:@"root"]; NSDictionary *graph=[resource objectForKey:@"graph"], *record=[graph objectForKey:root];
  NSArray *keys=ABFields(),*properties=ABProperties(); NSUInteger i,k; BOOL ok=YES;
  for(i=0;i<[keys count];i++) {
    id value=[record objectForKey:[keys objectAtIndex:i]];
    if(value) ok=[person setValue:value forProperty:[properties objectAtIndex:i]] && ok;
    else if([person valueForProperty:[properties objectAtIndex:i]]) ok=[person removeValueForProperty:[properties objectAtIndex:i]] && ok;
  }
  int flags=[[person valueForProperty:kABPersonFlags] intValue];
  flags=(flags&~kABShowAsMask)|([[record objectForKey:@"display as company"] isEqual:@"company"] ? kABShowAsCompany : kABShowAsPerson);
  ok=[person setValue:[NSNumber numberWithInt:flags] forProperty:kABPersonFlags] && ok;
  if([record objectForKey:@"image"] || [person imageData]) ok=[person setImageData:[record objectForKey:@"image"]] && ok;
  [ids removeAllObjects]; [ids setObject:[person uniqueId] forKey:root];
  for(k=0;k<[ABMultiProperties() count];k++) {
    NSString *property=[ABMultiProperties() objectAtIndex:k];
    ABMutableMultiValue *values=[[[ABMutableMultiValue alloc] init] autorelease];
    NSMutableArray *childIDs=[NSMutableArray array];
    NSEnumerator *it=[[record objectForKey:[ABRelations() objectAtIndex:k]] objectEnumerator]; NSString *key;
    while((key=[it nextObject])) {
      NSDictionary *child=[graph objectForKey:key]; id value=[child objectForKey:@"value"];
      if(k==2) { NSMutableDictionary *address=[NSMutableDictionary dictionary]; NSUInteger n;
        for(n=0;n<[ABAddressKeys() count];n++) Put(address,[ABAddressProperties() objectAtIndex:n],[child objectForKey:[ABAddressKeys() objectAtIndex:n]]); value=address; }
      if(k==3) value=RCTwoWayString(value);
      if(k>=6) { if(![[child objectForKey:@"service"] isEqual:[ABServices() objectAtIndex:k-6]]) continue; value=[child objectForKey:@"user"]; }
      if(!value) { ok=NO; continue; }
      NSString *native=[values addValue:value withLabel:ABLabel(child)];
      if(!native) { ok=NO; continue; }
      [childIDs addObject:key];
      [ids setObject:[NSString stringWithFormat:@"%@/%@",property,native] forKey:key];
      if(k<4 && [[record objectForKey:[[@"primary phone number|primary email address|primary street address|primary URL" componentsSeparatedByString:@"|"] objectAtIndex:k]] containsObject:key]) [values setPrimaryIdentifier:native];
    }
    // Preserve native multivalue identities when only another field changed.
    // Replacing unchanged child rows makes older AddressBook instances fault.
    ABMultiValue *existing=[person valueForProperty:property];
    BOOL same=[existing count]==[values count];
    for(i=0;same && i<[values count];i++) {
      same=[[existing valueAtIndex:i] isEqual:[values valueAtIndex:i]] &&
          [[existing labelAtIndex:i] isEqual:[values labelAtIndex:i]];
    }
    if(same && [values primaryIdentifier])
      same=[existing indexForIdentifier:[existing primaryIdentifier]]==[values indexForIdentifier:[values primaryIdentifier]];
    if(same) {
      for(i=0;i<[values count];i++) [ids setObject:[NSString stringWithFormat:@"%@/%@",property,[existing identifierAtIndex:i]] forKey:[childIDs objectAtIndex:i]];
      continue;
    }
    if([values count]) ok=[person setValue:values forProperty:property] && ok;
    else if([person valueForProperty:property]) ok=[person removeValueForProperty:property] && ok;
  }
  if(!ok) RCErrorSet(error,1,"AddressBook rejected a mapped contact field");
  return ok;
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
    [days addObject:[EKRecurrenceDayOfWeek dayOfWeek:(EKWeekday)(day+1) weekNumber:week]];
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
  NSMutableDictionary *r=[NSMutableDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Recurrence",ISyncRecordEntityNameKey,[NSArray arrayWithObject:owner],@"owner",nil];
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
    NSString *s=[date descriptionWithCalendarFormat:@"%Y-%m-%d" timeZone:from locale:nil];
    NSCalendarDate *d=[NSCalendarDate dateWithString:s calendarFormat:@"%Y-%m-%d"];
    return [NSCalendarDate dateWithYear:[d yearOfCommonEra] month:[d monthOfYear] day:[d dayOfMonth] hour:0 minute:0 second:0 timeZone:to];
  }
  return date;
}
/* Only installed system sounds are used. Never fetch a remote attachment or
   open a server-supplied path. The full original attachment stays in the base. */
static NSDictionary *EKSystemSounds(void)
{
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
}
static EKAlarm *EKMakeAlarm(NSDictionary *record,BOOL audio,RCError *error)
{
  EKAlarm *alarm=[record objectForKey:@"triggerdate"] ?
      [EKAlarm alarmWithAbsoluteDate:[record objectForKey:@"triggerdate"]] :
      [EKAlarm alarmWithRelativeOffset:[[record objectForKey:@"triggerduration"] doubleValue]];
  if(audio) {
    BOOL valid; NSURL *url=RCNativeAlarmSound(record,&valid);
    if(!valid) { RCErrorSet(error,1,"Invalid audio alarm sound"); return nil; }
    NSString *name=[[[url path] lastPathComponent] stringByDeletingPathExtension];
    NSDictionary *sounds=EKSystemSounds();
    if(![sounds objectForKey:name ?: @""]) name=[sounds objectForKey:@"Basso"] ? @"Basso" : [[[sounds allKeys] sortedArrayUsingSelector:@selector(compare:)] firstObject];
    if(!name) { RCErrorSet(error,1,"No installed system sound for an audio alarm"); return nil; }
    [alarm setSoundName:name];
  }
  return alarm;
}
static NSDictionary *EKAlarmRecord(EKAlarm *alarm,NSString *root,RCError *error)
{
  BOOL audio=[alarm type]==EKAlarmTypeAudio;
  if((!audio && [alarm type]!=EKAlarmTypeDisplay) || [alarm structuredLocation]) {
    RCErrorSet(error,1,"Unsupported native alarm action or location"); return nil;
  }
  NSMutableDictionary *r=[NSMutableDictionary dictionaryWithObjectsAndKeys:
      audio ? @"com.apple.calendars.AudioAlarm" : @"com.apple.calendars.DisplayAlarm",
      ISyncRecordEntityNameKey,[NSArray arrayWithObject:root],@"owner",nil];
  if([alarm absoluteDate]) Put(r,@"triggerdate",[alarm absoluteDate]);
  else Put(r,@"triggerduration",[NSNumber numberWithInt:(int)[alarm relativeOffset]]);
  if(audio) {
    NSURL *sound=[EKSystemSounds() objectForKey:[alarm soundName] ?: @""];
    if(!sound) { RCErrorSet(error,1,"Unknown native alarm sound; preserving the original alarm"); return nil; }
    Put(r,@"com.apple.ical.sound",sound);
  }
  return r;
}
static BOOL EKReadAlarms(id event,NSDictionary *resource,NSMutableDictionary *record,
    NSMutableDictionary *graph,RCError *error)
{
  NSString *root=[resource objectForKey:@"root"];
  NSDictionary *base=[resource objectForKey:@"graph"], *snapshot=[resource objectForKey:@"_snapshot"];
  NSMutableDictionary *expected=[NSMutableDictionary dictionary], *matches=[NSMutableDictionary dictionary];
  NSMutableArray *observed=[NSMutableArray array], *unmatched=[NSMutableArray array];
  NSString *links[]={@"display alarms",@"audio alarms"};
  for(int kind=0;kind<2;kind++) for(NSString *key in [[base objectForKey:root] objectForKey:links[kind]]) {
    NSDictionary *prior=[snapshot objectForKey:key];
    if(!prior) {
      EKAlarm *alarm=EKMakeAlarm([base objectForKey:key],kind==1,error); if(!alarm) return NO;
      prior=EKAlarmRecord(alarm,root,error); if(!prior) return NO;
    }
    [expected setObject:prior forKey:key];
  }
  for(EKAlarm *alarm in [event alarms]) {
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
    if(![[[expected objectForKey:key] objectForKey:ISyncRecordEntityNameKey]
        isEqual:[[observed objectAtIndex:[index unsignedIntegerValue]] objectForKey:ISyncRecordEntityNameKey]]) goto ambiguous;
    [matches setObject:key forKey:index];
  }
  NSMutableArray *display=[NSMutableArray array], *audio=[NSMutableArray array];
  for(NSUInteger n=0;n<[observed count];n++) {
    NSDictionary *r=[observed objectAtIndex:n];
    NSString *key=[matches objectForKey:[NSNumber numberWithUnsignedInteger:n]];
    if(!key) {
      NSUInteger suffix=n;
      do { key=[root stringByAppendingFormat:@"/alarm/%lu",(unsigned long)suffix++]; }
      while([base objectForKey:key] || [graph objectForKey:key]);
    }
    [graph setObject:r forKey:key];
    [([[r objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.AudioAlarm"] ? audio : display) addObject:key];
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
  RCErrorSet(error,1,"Native alarm identities are ambiguous; preserving the original alarms"); return NO;
}
static NSDictionary *EKRead(id event,NSDictionary *resource,RCError *error)
{
  if(!event) return [NSDictionary dictionary];
  NSString *root=[resource objectForKey:@"root"];
  NSDictionary *base=[[resource objectForKey:@"graph"] objectForKey:root];
  NSMutableDictionary *graph=[NSMutableDictionary dictionary], *record=[NSMutableDictionary dictionaryWithObjectsAndKeys:
      @"com.apple.calendars.Event",ISyncRecordEntityNameKey,nil];
  NSArray *keys=[@"summary|description|location|url|all day" componentsSeparatedByString:@"|"];
  NSArray *properties=[@"title|notes|location|URL|allDay" componentsSeparatedByString:@"|"]; NSUInteger n;
  for(n=0;n<[keys count];n++) Put(record,[keys objectAtIndex:n],[event valueForKey:[properties objectAtIndex:n]]);
  BOOL allDay=[[record objectForKey:@"all day"] boolValue];
  NSArray *dateKeys=[NSArray arrayWithObjects:@"start date",@"end date",nil], *dateProperties=[NSArray arrayWithObjects:@"startDate",@"endDate",nil];
  for(n=0;n<2;n++) {
    NSDate *date=EKDate([event valueForKey:[dateProperties objectAtIndex:n]],allDay,NO);
    if(!allDay && RCCalendarFloatingDate([base objectForKey:[dateKeys objectAtIndex:n]])) {
      NSCalendarDate *floating=[NSCalendarDate dateWithTimeIntervalSinceReferenceDate:[date timeIntervalSinceReferenceDate]];
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
  if(!EKReadAlarms(event,resource,record,graph,error)) return nil;
  /* Attendee/organizer links and children deliberately stay out of this native
     snapshot. RCChangedGraph retains them from the full publication base;
     their absence in EventKit is not a user edit or a participant deletion. */
  /* Capture unsupported local changes too, so they cannot be mistaken for a
     complete deletion or silently accepted by an upload receipt. */
  if([[event valueForKey:@"attendees"] count]) Put(record,@"native attendees",[NSNumber numberWithUnsignedInteger:[[event valueForKey:@"attendees"] count]]);
  [graph setObject:record forKey:root]; return graph;
}
static BOOL EKCanWrite(NSDictionary *resource,RCError *error)
{
  NSDictionary *graph=[resource objectForKey:@"graph"], *r=[graph objectForKey:[resource objectForKey:@"root"]];
  if([[r objectForKey:@"detached events"] count] || [[r objectForKey:@"exception dates"] count] || [[r objectForKey:@"main event"] count] ||
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
  [event setValue:(allDay || RCCalendarFloatingDate(start) ? nil : ([start isKindOfClass:[NSCalendarDate class]] ? [(NSCalendarDate *)start timeZone] : [NSTimeZone timeZoneForSecondsFromGMT:0])) forKey:@"timeZone"];
  [event setValue:EKDate(start,allDay,YES) forKey:@"startDate"];
  [event setValue:EKDate([r objectForKey:@"end date"],allDay,YES) forKey:@"endDate"];
  NSMutableArray *rules=[NSMutableArray array]; NSEnumerator *it=[[r objectForKey:@"recurrences"] objectEnumerator]; NSString *key;
  while((key=[it nextObject])) [rules addObject:EKRule([graph objectForKey:key])];
  [event setValue:rules forKey:@"recurrenceRules"];
  NSMutableArray *alarms=[NSMutableArray array]; NSString *links[]={@"display alarms",@"audio alarms"};
  for(int kind=0;kind<2;kind++) for(key in [r objectForKey:links[kind]]) {
    EKAlarm *alarm=EKMakeAlarm([graph objectForKey:key],kind==1,error);
    if(!alarm) return NO; [alarms addObject:alarm];
  }
  [event setValue:alarms forKey:@"alarms"]; return YES;
}

@interface RCNativeStore (Implementation)
- (id)container:(NSString *)root create:(BOOL)create error:(RCError *)error;
- (NSDictionary *)rawGraph:(NSDictionary *)saved error:(RCError *)error;
@end
@implementation RCNativeStore
- (id)initWithContext:(RCTwoWayContext *)context error:(RCError *)error;
{
  self=[super init]; if(!self) return nil; context_=context;
  contacts_=[context->rootEntity isEqual:@"com.apple.contacts.Contact"];
  if(!RCTwoWaySQL(&context->journal,error,"CREATE TABLE IF NOT EXISTS native_store_resources("
      "account_id INTEGER NOT NULL,root TEXT NOT NULL,resource BLOB NOT NULL,native BLOB NOT NULL,snapshot BLOB NOT NULL,pending INTEGER NOT NULL,PRIMARY KEY(account_id,root))")) goto failed;
  if(contacts_) {
    book_=[[ABAddressBook addressBook] retain];
    if(!book_) { RCErrorSet(error,1,"Contacts access is unavailable; allow rCloud in Privacy > Contacts"); goto failed; }
  } else {
    if(!RCUsesNativeStores()) { RCErrorSet(error,1,"Native stores require macOS 10.9 or later"); goto failed; }
    if(!RCEventAccess(error)) goto failed;
    events_=[[EKEventStore alloc] init];
    if(!events_) { RCErrorSet(error,1,"Could not initialize EventKit"); goto failed; }
    if(![[events_ valueForKey:@"sources"] count]) { RCErrorSet(error,1,"Calendar access or local calendar store is not ready"); goto failed; }
  }
  return self;
failed:
  [self release]; return nil;
}
- (void)dealloc;
{
  [book_ release]; [events_ release]; [super dealloc];
}
- (BOOL)syncContainers:(RCError *)error;
{
  if(contacts_) return YES;
  NSEnumerator *it=[context_->graph keyEnumerator]; NSString *root;
  while((root=[it nextObject])) {
    NSDictionary *record=[context_->graph objectForKey:root];
    if(![[record objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Calendar"]) continue;
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
- (NSDictionary *)savedResources:(RCError *)error;
{
  sqlite3_stmt *q=NULL; NSMutableDictionary *result=[NSMutableDictionary dictionary]; int step=SQLITE_ERROR;
  RCWriteJournal j=context_->journal;
  if(sqlite3_prepare_v2(j.db,"SELECT root FROM native_store_resources WHERE account_id=? AND root NOT LIKE '@%'",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account);
    while((step=sqlite3_step(q))==SQLITE_ROW) {
      NSString *root=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
      NSDictionary *r=RCLoadNative(j,root,error); if(!r) break;
      if([[r objectForKey:@"_pending"] boolValue]) { RCErrorSet(error,1,"An interrupted native save requires recovery; refusing duplicate creation"); break; }
      [result setObject:r forKey:root];
    }
  }
  sqlite3_finalize(q);
  if(step!=SQLITE_DONE) { if(!error->code) RCErrorSet(error,1,"Could not read native resources"); return nil; }
  return result;
}
- (id)container:(NSString *)root create:(BOOL)create error:(RCError *)error;
{
  if(!contacts_ && !root) { RCErrorSet(error,1,"Native resource has no calendar identity"); return nil; }
  NSString *key=contacts_ ? @"@contacts" : [@"@" stringByAppendingString:root];
  NSDictionary *saved=RCLoadNative(context_->journal,key,error); if(error->code) return nil;
  NSString *native=[[saved objectForKey:@"_ids"] objectForKey:key];
  id container=native ? (contacts_ ? [book_ recordForUniqueId:native] : [(EKEventStore *)events_ calendarWithIdentifier:native]) : nil;
  if(container) return container;
  if(saved) { RCErrorSet(error,1,"Managed native container is missing; refusing to infer resource deletions"); return nil; }
  if(!create) return nil;
  NSDictionary *resource=[NSDictionary dictionaryWithObject:key forKey:@"root"];
  if(contacts_) {
    container=[[[ABGroup alloc] init] autorelease];
    NSString *title=[NSString stringWithFormat:@"rCloud (%@)",[context_->clientIdentifier substringFromIndex:[context_->clientIdentifier length]-8]];
    if(!RCSaveNative(context_->journal,resource,[NSDictionary dictionary],nil,YES,error)) return nil;
    if(![container setValue:title forProperty:kABGroupNameProperty] || ![book_ addRecord:container] || ![book_ save]) goto failed;
    native=[container uniqueId];
  } else {
    id source=nil; NSEnumerator *it=[[events_ valueForKey:@"sources"] objectEnumerator]; id candidate;
    while((candidate=[it nextObject])) if([[candidate valueForKey:@"sourceType"] integerValue]==0) { source=candidate; break; }
    if(!source) { RCErrorSet(error,1,"EventKit has no local On My Mac source; create a local calendar first"); return nil; }
    container=[EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:events_];
    [container setValue:source forKey:@"source"];
    [container setValue:[[context_->graph objectForKey:root] objectForKey:@"title"] ?: @"rCloud Calendar" forKey:@"title"];
    if(!RCSaveNative(context_->journal,resource,[NSDictionary dictionary],nil,YES,error)) return nil;
    if(!EKSave(events_,NSSelectorFromString(@"saveCalendar:commit:error:"),container,NO,error)) return nil;
    native=[container valueForKey:@"calendarIdentifier"];
  }
  if(!native || !RCSaveNative(context_->journal,resource,[NSDictionary dictionaryWithObject:native forKey:key],nil,NO,error)) return nil;
  return container;
failed:
  RCErrorSet(error,1,"Could not create managed Contacts group; check Contacts access"); return nil;
}
- (NSDictionary *)rawGraph:(NSDictionary *)saved error:(RCError *)error;
{
  NSString *root=[saved objectForKey:@"root"]; NSDictionary *ids=[saved objectForKey:@"_ids"];
  if(contacts_) {
    if(![self container:nil create:NO error:error]) { if(!error->code) RCErrorSet(error,1,"Managed Contacts group is missing"); return nil; }
    return ABRead((ABPerson *)[book_ recordForUniqueId:[ids objectForKey:root]],root,ids);
  }
  NSString *calendar=[[[saved objectForKey:@"graph"] objectForKey:root] objectForKey:@"calendar"] ?
      [[[[saved objectForKey:@"graph"] objectForKey:root] objectForKey:@"calendar"] objectAtIndex:0] : nil;
  id container=[self container:calendar create:NO error:error];
  if(!container) { if(!error->code) RCErrorSet(error,1,"Managed Calendar is missing"); return nil; }
  id event=[(EKEventStore *)events_ eventWithIdentifier:[ids objectForKey:root]];
  if(event && ![[[event valueForKey:@"calendar"] valueForKey:@"calendarIdentifier"] isEqual:[container valueForKey:@"calendarIdentifier"]]) {
    RCErrorSet(error,1,"Local calendar move requires attention; preserving the event"); return nil;
  }
  return EKRead(event,saved,error);
}
- (NSDictionary *)readResource:(NSDictionary *)saved error:(RCError *)error;
{
  NSDictionary *raw=[self rawGraph:saved error:error];
  return raw ? RCChangedGraph([saved objectForKey:@"graph"],[saved objectForKey:@"_snapshot"],raw) : nil;
}
- (BOOL)canPublishResource:(NSDictionary *)resource error:(RCError *)error;
{
  return contacts_ || EKCanWrite(resource,error);
}
- (BOOL)publishResource:(NSDictionary *)resource error:(RCError *)error;
{
  if(RCCheckCancellation(error)) return NO;
  NSString *root=[resource objectForKey:@"root"];
  NSDictionary *saved=RCLoadNative(context_->journal,root,error); if(error->code) return NO;
  if([[saved objectForKey:@"_pending"] boolValue]) { RCErrorSet(error,1,"Native publication requires recovery from interrupted save"); return NO; }
  NSMutableDictionary *ids=[NSMutableDictionary dictionaryWithDictionary:[saved objectForKey:@"_ids"] ?: [NSDictionary dictionary]];
  id item=nil,container=nil;
  if(contacts_) {
    container=[self container:nil create:YES error:error]; if(!container) return NO;
    item=[ids objectForKey:root] ? [book_ recordForUniqueId:[ids objectForKey:root]] : nil;
    if(!item) { item=[[[ABPerson alloc] init] autorelease]; if(![book_ addRecord:item]) goto failed; }
    if(!ABWrite(item,resource,ids,error)) return NO;
    if(![[container members] containsObject:item] && ![container addMember:item]) goto failed;
  } else {
    if(!EKCanWrite(resource,error)) return NO;
    NSArray *calendars=[[[resource objectForKey:@"graph"] objectForKey:root] objectForKey:@"calendar"];
    if([calendars count]!=1) { RCErrorSet(error,1,"Event has no unambiguous calendar"); return NO; }
    container=[self container:[calendars objectAtIndex:0] create:YES error:error]; if(!container) return NO;
    item=[ids objectForKey:root] ? [(EKEventStore *)events_ eventWithIdentifier:[ids objectForKey:root]] : nil;
    if(!item) item=[EKEvent eventWithEventStore:events_];
    if(!item || !EKWrite(item,container,resource,error)) return NO;
  }
  /* Reservation precedes native commit. An ambiguous crash blocks replay rather
     than manufacturing a duplicate record. Completed saves are idempotent. */
  if(!RCSaveNative(context_->journal,resource,ids,[saved objectForKey:@"_snapshot"],YES,error)) return NO;
  if(contacts_) { if(![book_ save]) goto failed; }
  else {
    if(!EKSave(events_,NSSelectorFromString(@"saveEvent:span:commit:error:"),item,YES,error)) return NO;
    NSString *native=[item valueForKey:@"eventIdentifier"]; if(!native) goto failed; [ids setObject:native forKey:root];
  }
  NSDictionary *snapshot=contacts_ ? ABRead(item,root,ids) : EKRead(item,resource,error);
  if(!snapshot) return NO;
  return RCSaveNative(context_->journal,resource,ids,snapshot,NO,error);
failed:
  RCErrorSet(error,1,"Native store rejected publication; check access and local store availability"); return NO;
}
- (BOOL)removeResource:(NSDictionary *)saved error:(RCError *)error;
{
  if(RCCheckCancellation(error)) return NO;
  NSString *root=[saved objectForKey:@"root"],*native=[[saved objectForKey:@"_ids"] objectForKey:root];
  if(![self rawGraph:saved error:error]) return NO;
  id item=contacts_ ? [book_ recordForUniqueId:native] : [(EKEventStore *)events_ eventWithIdentifier:native];
  if(item) {
    if(contacts_) { if(![book_ removeRecord:item] || ![book_ save]) { RCErrorSet(error,1,"Could not remove managed contact"); return NO; } }
    else if(!EKSave(events_,NSSelectorFromString(@"removeEvent:span:commit:error:"),item,YES,error)) return NO;
  }
  return RCTwoWaySQL(&context_->journal,error,"DELETE FROM native_store_resources WHERE account_id=%lld AND root=%Q",context_->journal.account,[root UTF8String]);
}
- (BOOL)rememberResource:(NSDictionary *)resource native:(NSDictionary *)saved error:(RCError *)error;
{
  return RCSaveNative(context_->journal,resource,[saved objectForKey:@"_ids"],[saved objectForKey:@"_snapshot"],NO,error);
}
- (NSArray *)untrackedResources:(RCError *)error;
{
  NSDictionary *saved=[self savedResources:error]; if(!saved) return nil;
  NSMutableSet *known=[NSMutableSet set]; NSEnumerator *it=[saved objectEnumerator]; NSDictionary *r;
  while((r=[it nextObject])) { NSString *native=[[r objectForKey:@"_ids"] objectForKey:[r objectForKey:@"root"]]; if(native) [known addObject:native]; }
  NSMutableArray *result=[NSMutableArray array];
  if(contacts_) {
    id group=[self container:nil create:NO error:error]; if(error->code) return nil;
    it=[[group members] objectEnumerator]; ABPerson *person;
    while((person=[it nextObject])) if(![known containsObject:[person uniqueId]]) {
      NSString *root=[@"native-contact-" stringByAppendingString:[person uniqueId]];
      NSDictionary *ids=[NSDictionary dictionaryWithObject:[person uniqueId] forKey:root], *graph=ABRead(person,root,ids);
      [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",graph,@"graph",ids,@"_ids",graph,@"_snapshot",nil]];
    }
  } else {
    /* Search only managed calendars, in bounded four-year windows (EventKit's
       predicate limit). Existing resource lookups never depend on this window. */
    NSEnumerator *calendars=[context_->graph keyEnumerator]; NSString *calendar;
    while((calendar=[calendars nextObject])) if([[[context_->graph objectForKey:calendar] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Calendar"]) {
      id container=[self container:calendar create:NO error:error]; if(error->code) return nil; if(!container) continue;
      int year; for(year=1970;year<2100;year+=4) {
        NSAutoreleasePool *windowPool=[[NSAutoreleasePool alloc] init];
        @try {
        if(RCCheckCancellation(error)) return nil;
        NSDate *start=[NSCalendarDate dateWithYear:year month:1 day:1 hour:0 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        NSDate *end=[NSCalendarDate dateWithYear:year+4 month:1 day:1 hour:0 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        NSPredicate *predicate=[(EKEventStore *)events_ predicateForEventsWithStartDate:start endDate:end calendars:[NSArray arrayWithObject:container]];
        NSEnumerator *items=[[(EKEventStore *)events_ eventsMatchingPredicate:predicate] objectEnumerator]; id event;
        while((event=[items nextObject])) {
          NSString *native=[event valueForKey:@"eventIdentifier"]; if(!native || [known containsObject:native]) continue; [known addObject:native];
          NSString *root=[@"native-event-" stringByAppendingString:native];
          NSDictionary *record=[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:calendar] forKey:@"calendar"];
          NSDictionary *stub=[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",[NSDictionary dictionaryWithObject:record forKey:root],@"graph",nil];
          NSDictionary *graph=EKRead(event,stub,error), *ids=[NSDictionary dictionaryWithObject:native forKey:root];
          if(!graph) return nil;
          [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:root,@"root",graph,@"graph",ids,@"_ids",graph,@"_snapshot",nil]];
        }
        } @catch(id exception) { RCDrainPoolPreservingException(&windowPool,exception); @throw; }
        @finally { [windowPool release]; }
      }
    }
  }
  return result;
}
- (BOOL)acceptReceipt:(NSDictionary *)receipt scopes:(NSDictionary *)scopes newerTruth:(NSDictionary **)newer error:(RCError *)error;
{
  NSDictionary *saved=[self savedResources:error]; if(!saved) return NO;
  NSMutableDictionary *truth=[NSMutableDictionary dictionary]; NSEnumerator *it=[saved objectEnumerator]; NSDictionary *r;
  while((r=[it nextObject])) {
    NSDictionary *graph=[self readResource:r error:error]; if(!graph) return NO; [truth addEntriesFromDictionary:graph];
  }
  if(newer) *newer=truth;
  if(!RCNativeScopeMatches(truth,receipt,scopes)) { RCErrorSet(error,1,"Newer native edits remain pending"); return NO; }
  /* Advance only the acknowledged fields in the native baseline. Otherwise a
     successful upload would be detected again as a fresh local edit next poll. */
  it=[saved objectEnumerator];
  while((r=[it nextObject])) {
    NSMutableDictionary *base=[NSMutableDictionary dictionaryWithDictionary:[r objectForKey:@"graph"]];
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionaryWithDictionary:[r objectForKey:@"_snapshot"]];
    NSDictionary *raw=[self rawGraph:r error:error]; if(!raw) return NO;
    BOOL touched=NO; NSEnumerator *ids=[receipt keyEnumerator]; NSString *key;
    while((key=[ids nextObject])) if([base objectForKey:key] || [[r objectForKey:@"root"] isEqual:key]) {
      touched=YES; id value=[receipt objectForKey:key];
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
      if(!RCSaveNative(context_->journal,updated,[r objectForKey:@"_ids"],snapshot,NO,error)) return NO;
    }
  }
  return YES;
}
@end

#else
BOOL RCUsesNativeStoresForVersion(int major,int minor) { return major>10 || (major==10 && minor>=9); }
BOOL RCUsesNativeStores(void) { return NO; }
void RCNativeRequestAccess(BOOL contacts,BOOL calendars) { (void)contacts; (void)calendars; }
BOOL RCNativeWaitForAccess(BOOL contacts,RCError *error) { (void)contacts; RCErrorClear(error); return !RCCheckCancellation(error); }
#endif
