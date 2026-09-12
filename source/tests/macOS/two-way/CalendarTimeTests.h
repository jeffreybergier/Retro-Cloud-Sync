/* Included after the mapper fixture helpers. No network or Sync Services. */
#import "../../../macOS-daemon/RCCalendarTime.h"
static NSString *TimeFixture(NSString *zone, NSString *start, NSString *rule)
{
  return [NSString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n%@BEGIN:VEVENT\r\nUID:time-fixture\r\nSUMMARY:Time fixture\r\nDTSTART%@:20260301T090000\r\nDTEND%@:20260301T100000\r\n%@X-PRIVATE:keep\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",zone,start,start,rule];
}
static NSString *ChangedZone(void)
{
  return @"BEGIN:VTIMEZONE\r\nTZID:Europe/London\r\nBEGIN:STANDARD\r\nDTSTART:19701025T020000\r\nTZOFFSETFROM:+0230\r\nTZOFFSETTO:+0130\r\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\nBEGIN:DAYLIGHT\r\nDTSTART:19700329T020000\r\nTZOFFSETFROM:+0130\r\nTZOFFSETTO:+0230\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE\r\n";
}
static void CalendarTimeMapperTests(RCCalendarStore *store)
{
  NSArray *fixtures=[NSArray arrayWithObjects:TimeFixture(@"",@"",@"RRULE:FREQ=DAILY;UNTIL=20260304T090000\r\n"),
      TimeFixture(ChangedZone(),@";TZID=Europe/London",@"RRULE:FREQ=WEEKLY;COUNT=40\r\n"),nil];
  int index;
  for(index=0;index<2;index++) {
    NSString *text=[fixtures objectAtIndex:index]; NSData *body=[text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *resource=CalendarResource(store,201+index,body,@"https://fixture.invalid/calendar/time.ics",@"\"time-base\"");
    NSString *root=[resource objectForKey:@"root"]; NSDictionary *graph=[resource objectForKey:@"graph"];
    NSCalendarDate *start=[[graph objectForKey:root] objectForKey:@"start date"];
    CHECK(RCCalendarFloatingDate(start)==(index==0));
    NSDictionary *archived=[NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:graph]];
    CHECK(RCTwoWayGraphsEqual(graph,archived));
    if(index) {
      CHECK([[start timeZone] secondsFromGMTForDate:start]==0 && [start hourOfDay]==7 && [start minuteOfHour]==30);
      NSArray *detached=[[graph objectForKey:root] objectForKey:@"detached events"]; CHECK([detached count]>0);
      NSEnumerator *it=[detached objectEnumerator]; NSString *identifier;
      while((identifier=[it nextObject])) {
        NSDictionary *instance=[graph objectForKey:identifier];
        CHECK([[instance objectForKey:@"start date"] timeIntervalSinceDate:[instance objectForKey:@"original date"]]==-3600);
        CHECK([[instance objectForKey:@"start date"] hourOfDay]==6);
      }
    } else {
      NSMutableDictionary *wrong=[NSMutableDictionary dictionaryWithDictionary:[graph objectForKey:root]];
      [wrong setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[start timeIntervalSinceReferenceDate]] forKey:@"start date"];
      CHECK(!RCTwoWayRecordsEqual([graph objectForKey:root],wrong));
    }
    NSDictionary *unchanged=RCCalendarEncodeLocal(store,resource,graph,root,&error); if(!unchanged) fprintf(stderr,"Unchanged time mapper: %s\n",error.message); CHECK(unchanged);
    CHECK([[unchanged objectForKey:@"body"] isEqual:body]);
    NSMutableDictionary *truth=[NSMutableDictionary dictionaryWithDictionary:graph];
    NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]];
    if(index) {
      NSEnumerator *it=[graph keyEnumerator]; NSString *identifier;
      while((identifier=[it nextObject])) if([[[graph objectForKey:identifier] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Event"]) {
        NSMutableDictionary *edited=[NSMutableDictionary dictionaryWithDictionary:[graph objectForKey:identifier]];
        [edited setObject:@"Whole-series note" forKey:@"description"]; [truth setObject:edited forKey:identifier];
      }
      NSDictionary *desired=RCCalendarEncodeLocal(store,resource,truth,root,&error);
      if(!desired) fprintf(stderr,"Projected zone mapper: %s\n",error.message); CHECK(desired);
      NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
      CHECK([wire rangeOfString:ChangedZone()].location!=NSNotFound && [wire rangeOfString:@"DESCRIPTION:Whole-series note"].location!=NSNotFound);
      CHECK(RCCalendarEncodeLocal(store,desired,truth,root,&error));
      event=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:root]];
      [event setObject:[NSDate dateWithTimeIntervalSinceReferenceDate:[start timeIntervalSinceReferenceDate]+3600] forKey:@"start date"];
      [truth setObject:event forKey:root]; CHECK(!RCCalendarEncodeLocal(store,resource,truth,root,&error));
      continue;
    }
    NSCalendarDate *moved=[NSCalendarDate dateWithYear:2026 month:7 day:1 hour:9 minute:0 second:0 timeZone:[start timeZone]];
    NSCalendarDate *end=[NSCalendarDate dateWithYear:2026 month:7 day:1 hour:10 minute:0 second:0 timeZone:[start timeZone]];
    [event setObject:moved forKey:@"start date"]; [event setObject:end forKey:@"end date"];
    /* A floating UNTIL before the edited start would make an empty series. */
    NSString *ruleID=[[event objectForKey:@"recurrences"] objectAtIndex:0];
    NSMutableDictionary *rule=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:ruleID]];
    [rule removeObjectForKey:@"until"]; [rule setObject:[NSNumber numberWithInt:4] forKey:@"count"]; [truth setObject:rule forKey:ruleID];
    [truth setObject:event forKey:root];
    NSDictionary *desired=RCCalendarEncodeLocal(store,resource,truth,root,&error);
    if(!desired) fprintf(stderr,"Time mapper: %s\n",error.message); CHECK(desired);
    NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
    CHECK([wire rangeOfString:index ? @"DTSTART;TZID=Europe/London:20260701T090000" : @"DTSTART:20260701T090000\r\n"].location!=NSNotFound);
    CHECK([wire rangeOfString:@"X-PRIVATE:keep"].location!=NSNotFound);
    if(index) CHECK([wire rangeOfString:ChangedZone()].location!=NSNotFound);
    desired=RCCalendarEncodeLocal(store,desired,truth,root,&error); CHECK(desired);
    CHECK([[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease] isEqual:wire]);
  }
  NSString *unbounded=TimeFixture(ChangedZone(),@";TZID=Europe/London",@"RRULE:FREQ=WEEKLY\r\n");
  NSData *body=[unbounded dataUsingEncoding:NSUTF8StringEncoding];
  CHECK(!RCCalendarNativeGraph(store,209,@"calendar-fixture",body,&error) && strstr(error.message,"finite series"));
  body=[Replace(TimeFixture(ChangedZone(),@";TZID=Europe/London",@"RRULE:FREQ=WEEKLY;COUNT=4\r\n"),@"20260301",@"20380301") dataUsingEncoding:NSUTF8StringEncoding];
  CHECK(!RCCalendarNativeGraph(store,220,@"calendar-fixture",body,&error));
  body=[TimeFixture(Replace(ChangedZone(),@"TZOFFSETFROM:+0230\r\n",@""),@";TZID=Europe/London",@"RRULE:FREQ=WEEKLY;COUNT=4\r\n") dataUsingEncoding:NSUTF8StringEncoding];
  CHECK(!RCCalendarNativeGraph(store,221,@"calendar-fixture",body,&error));
  body=[Replace(TimeFixture(ChangedZone(),@";TZID=Europe/London",@"RRULE:FREQ=WEEKLY;COUNT=4\r\n"),@"20260301",@"19300301") dataUsingEncoding:NSUTF8StringEncoding];
  CHECK(RCCalendarNativeGraph(store,223,@"calendar-fixture",body,&error));
  NSTimeZone *savedZone=[[NSTimeZone defaultTimeZone] retain];
  @try {
    [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"America/New_York"]];
    NSString *gap=Replace(Replace(TimeFixture(@"",@"",@""),@"20260301T090000",@"20060402T023000"),@"20260301T100000",@"20060402T033000");
    CHECK(!RCCalendarNativeGraph(store,222,@"calendar-fixture",[gap dataUsingEncoding:NSUTF8StringEncoding],&error));
  } @finally { [NSTimeZone setDefaultTimeZone:savedZone]; [savedZone release]; }
  body=[Replace(TimeFixture(@"",@"",@""),@"DTEND:20260301T100000\r\n",@"") dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *instant=CalendarResource(store,224,body,@"https://fixture.invalid/calendar/instant.ics",@"\"instant\"");
  NSString *instantRoot=[instant objectForKey:@"root"];
  NSMutableDictionary *instantTruth=[NSMutableDictionary dictionaryWithDictionary:[instant objectForKey:@"graph"]];
  NSMutableDictionary *instantEvent=[NSMutableDictionary dictionaryWithDictionary:[instantTruth objectForKey:instantRoot]];
  [instantEvent setObject:[NSCalendarDate dateWithYear:2026 month:3 day:1 hour:10 minute:0 second:0 timeZone:[NSTimeZone localTimeZone]] forKey:@"end date"];
  [instantTruth setObject:instantEvent forKey:instantRoot];
  NSDictionary *extended=RCCalendarEncodeLocal(store,instant,instantTruth,instantRoot,&error); CHECK(extended);
  NSString *extendedWire=[[[NSString alloc] initWithData:[extended objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
  CHECK([extendedWire rangeOfString:@"DTEND:20260301T100000\r\n"].location!=NSNotFound);
  NSString *invalidAlarm=Replace(TimeFixture(@"",@"",@""),@"END:VEVENT",@"BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER;VALUE=DATE-TIME:20260301T080000\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nEND:VEVENT");
  CHECK(!RCCalendarNativeGraph(store,225,@"calendar-fixture",[invalidAlarm dataUsingEncoding:NSUTF8StringEncoding],&error));
  NSArray *sets=[NSArray arrayWithObjects:
      @"RDATE:20260303T090000,20260306T090000\r\n",
      @"RRULE:FREQ=DAILY;COUNT=6\r\nEXRULE:FREQ=DAILY;INTERVAL=2\r\n",nil];
  for(index=0;index<2;index++) {
    body=[TimeFixture(@"",@"",[sets objectAtIndex:index]) dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *resource=CalendarResource(store,210+index,body,@"https://fixture.invalid/calendar/dates.ics",@"\"dates\"");
    NSString *root=[resource objectForKey:@"root"]; NSDictionary *graph=[resource objectForKey:@"graph"], *old=[graph objectForKey:root];
    CHECK([[old objectForKey:@"exception dates"] count]==3);
    NSDictionary *rule=[graph objectForKey:[[old objectForKey:@"recurrences"] objectAtIndex:0]];
    CHECK([[rule objectForKey:@"count"] intValue]==6);
    NSMutableDictionary *truth=[NSMutableDictionary dictionaryWithDictionary:graph];
    NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:old];
    [event setObject:@"Edited finite set" forKey:@"summary"]; [truth setObject:event forKey:root];
    NSDictionary *desired=RCCalendarEncodeLocal(store,resource,truth,root,&error); CHECK(desired);
    NSString *wire=[[[NSString alloc] initWithData:[desired objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
    CHECK([wire rangeOfString:[sets objectAtIndex:index]].location!=NSNotFound);
    CHECK(RCCalendarEncodeLocal(store,desired,truth,root,&error));
    [event setObject:[NSArray array] forKey:@"exception dates"];
    CHECK(!RCCalendarEncodeLocal(store,resource,truth,root,&error));
  }
  body=[TimeFixture(@"",@"",@"RDATE:20260303T100000\r\n") dataUsingEncoding:NSUTF8StringEncoding];
  CHECK(!RCCalendarNativeGraph(store,219,@"calendar-fixture",body,&error));
  puts("PASS: Finite RDATE/EXRULE sets project exactly; text edits retain source rules, structural edits and mixed wall times stay protected");
  puts("PASS: Floating markers and custom DST rules survive archives, edits, exact wire preservation and replay; unbounded custom DST remains protected");
}
