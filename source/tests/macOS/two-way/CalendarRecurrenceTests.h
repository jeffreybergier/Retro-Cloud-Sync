/* Exercise the real iCal consumer as well as the Sync Services truth. */
static NSString *ReadICalRule(BOOL bounded)
{
  NSString *script=[NSString stringWithFormat:
      @"tell application \"iCal\"\n"
       "repeat 30 times\n"
       "repeat with c in calendars\n"
       "set es to every event of c whose summary is \"%@\"\n"
       "if (count es) is 1 then\n"
       "set e to item 1 of es\n"
       "set r to recurrence of e\n"
       "if (r contains \"FREQ=YEARLY\") and ((r contains \"UNTIL=\") is %@) then return uid of e\n"
       "end if\nend repeat\ndelay 1\nend repeat\n"
       "error \"iCal recurrence differs from cloud rule\"\nend tell",
      marker,bounded ? @"true" : @"false"];
  NSAppleScript *apple=[[[NSAppleScript alloc] initWithSource:script] autorelease];
  NSDictionary *failure=nil;
  NSAppleEventDescriptor *result=[apple executeAndReturnError:&failure];
  if(!result) NSLog(@"iCal recurrence verification failed: %@",failure);
  CHECK(result);
  return [result stringValue];
}
static void CalendarRecurrenceIntegration(RCTwoWayContext *c,
    RCCalendarStore *store, BOOL initiallyBounded)
{
  NSString *href=@"https://fixture.invalid/calendar/rule-update.ics";
  NSString *text=[NSString stringWithFormat:
      @"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n"
       "UID:rule-update\r\nDTSTART;VALUE=DATE:20301116\r\n"
       "DTEND;VALUE=DATE:20301117\r\nSUMMARY:%@\r\n"
       "RRULE:FREQ=YEARLY;UNTIL=20351116\r\n"
       "END:VEVENT\r\nEND:VCALENDAR\r\n",marker];
  if (!initiallyBounded) text=Replace(text,@";UNTIL=20351116",@"");
  NSString *originalID=nil, *oldRuleID=nil, *oldGlobalRuleID=nil;
  int phase;
  for(phase=0;phase<2;phase++) {
    NSData *body=[text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *resource=CalendarResource(store,301,body,href,
        phase ? @"\"unbounded\"" : @"\"bounded\"");
    /* Seed an old release's projection, before the date-range guard existed. */
    if (!phase) {
      NSMutableDictionary *legacy=[NSMutableDictionary dictionaryWithDictionary:resource];
      NSMutableDictionary *graph=[NSMutableDictionary dictionaryWithDictionary:
          [resource objectForKey:@"graph"]];
      NSString *identifier=[[[graph objectForKey:[resource objectForKey:@"root"]]
          objectForKey:@"recurrences"] objectAtIndex:0];
      NSMutableDictionary *rule=[NSMutableDictionary dictionaryWithDictionary:
          [graph objectForKey:identifier]];
      if (initiallyBounded) [rule setObject:[NSCalendarDate dateWithYear:2099 month:11 day:17
          hour:12 minute:0 second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]]
          forKey:@"until"];
      [graph setObject:rule forKey:identifier];
      [legacy setObject:graph forKey:@"graph"];
      [legacy setObject:[Replace(text,@"20351116",@"20991117")
          dataUsingEncoding:NSUTF8StringEncoding] forKey:@"body"];
      char *stable=RCCalendarStoreIdentity(store,
          [[resource objectForKey:@"root"] UTF8String],"recurrence",&error);
      CHECK(stable);
      oldRuleID=[@"cal-" stringByAppendingString:
          [NSString stringWithUTF8String:stable]];
      free(stable);
      resource=RCTwoWayMapResource(legacy,
          [NSDictionary dictionaryWithObject:oldRuleID forKey:identifier]);
    }
    c->resources=[NSArray arrayWithObject:resource];
    c->graph=CalendarGraph(c->resources);
    if (!phase) LegacyClient(c->clientIdentifier,c->descriptionPath,c->graph);
    else {
      CHECK(RCSyncServicesExchange(c,&error));
      CHECK(c->didPublishAll);
    }
    ISyncClient *server=[[ISyncManager sharedManager]
        clientWithIdentifier:c->clientIdentifier];
    NSString *ruleID=[[[[resource objectForKey:@"graph"]
        objectForKey:[resource objectForKey:@"root"]]
        objectForKey:@"recurrences"] objectAtIndex:0];
    ISyncRecordSnapshot *snapshot=[[ISyncManager sharedManager]
        snapshotOfRecordsInTruthWithEntityNames:[server enabledEntityNames]
        usingIdentifiersForClient:server];
    NSDictionary *rule=[[snapshot recordsWithIdentifiers:
        [NSArray arrayWithObject:ruleID]] objectForKey:ruleID];
    CHECK(rule && [[rule objectForKey:@"frequency"] isEqual:@"yearly"] &&
        (([rule objectForKey:@"until"]!=nil)==(!phase && initiallyBounded)));
    if (phase) {
      CHECK(![ruleID isEqual:oldRuleID]);
      CHECK(![[snapshot recordsWithIdentifiers:
          [NSArray arrayWithObject:oldRuleID]] objectForKey:oldRuleID]);
      CHECK(RCSyncServicesExchange(c,&error));
      CHECK(c->didPublishAll);
      NSDictionary *replayed=CalendarResource(store,301,body,href,@"\"unbounded\"");
      CHECK([[[replayed objectForKey:@"graph"] allKeys]
          containsObject:ruleID]);
    }
    ISyncRecordSnapshot *global=[[ISyncManager sharedManager]
        snapshotOfRecordsInTruthWithEntityNames:[server enabledEntityNames]
        usingIdentifiersForClient:nil];
    NSDictionary *events=[global recordsWithMatchingAttributes:
        [NSDictionary dictionaryWithObjectsAndKeys:
        @"com.apple.calendars.Event",ISyncRecordEntityNameKey,marker,@"summary",nil]];
    CHECK([events count]==1);
    NSString *globalRuleID=[[[[events allValues] objectAtIndex:0]
        objectForKey:@"recurrences"] objectAtIndex:0];
    if (!phase) oldGlobalRuleID=globalRuleID;
    else CHECK(![oldGlobalRuleID isEqual:globalRuleID]);
    NSString *nativeID=ReadICalRule(!phase && initiallyBounded);
    if(!phase) originalID=nativeID;
    else CHECK([originalID isEqual:nativeID]);
    CHECK(Scalar(&c->journal,"SELECT count(*) FROM write_operations")==0);
    NSAppleScript *restart=[[[NSAppleScript alloc] initWithSource:
        @"tell application \"iCal\" to quit\n"
         "delay 2\ntell application \"iCal\" to launch"] autorelease];
    NSDictionary *restartError=nil;
    CHECK([restart executeAndReturnError:&restartError]);
    CHECK([nativeID isEqual:ReadICalRule(!phase && initiallyBounded)]);
    text=Replace(text,@";UNTIL=20351116",@"");
  }
  puts("PASS: Two-way cloud recurrence end removal reaches iCal without replacing the event");
}
