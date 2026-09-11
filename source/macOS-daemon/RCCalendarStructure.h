/* Structural edits are validated by the production forward mapper before any
   outbox write. Clone existing components to retain unrepresented extensions. */
static void RemoveProperties(icalcomponent *c,icalproperty_kind kind)
{
  icalproperty *p; while((p=icalcomponent_get_first_property(c,kind))) { icalcomponent_remove_property(c,p); icalproperty_free(p); }
}
static BOOL ReplaceLine(icalcomponent *c,NSString *name,NSString *value,RCError *error)
{
  NSString *line=[NSString stringWithFormat:@"%@:%@",name,value ?: @""];
  icalproperty *p=value ? icalproperty_new_from_string([line UTF8String]) : NULL;
  if(value && (!p || icalproperty_isa(p)==ICAL_XLICERROR_PROPERTY)) {
    if(p) icalproperty_free(p); RCErrorSet(error,1,"Invalid calendar property %s",[name UTF8String]); return NO;
  }
  NSString *bare=[[name componentsSeparatedByString:@";"] objectAtIndex:0];
  icalproperty_kind kind=icalproperty_string_to_kind([bare UTF8String]);
  icalproperty *prior=icalcomponent_get_first_property(c,kind);
  if(icalcomponent_count_properties(c,kind)>1) { if(p) icalproperty_free(p); RCErrorSet(error,1,"Ambiguous repeated calendar property"); return NO; }
  if(prior && p) {
    icalparameter *parameter;
    for(parameter=icalproperty_get_first_parameter(prior,ICAL_ANY_PARAMETER);parameter;parameter=icalproperty_get_next_parameter(prior,ICAL_ANY_PARAMETER)) {
      icalparameter_kind pk=icalparameter_isa(parameter);
      if(pk!=ICAL_VALUE_PARAMETER && pk!=ICAL_TZID_PARAMETER && pk!=ICAL_RELATED_PARAMETER)
        icalproperty_add_parameter(p,icalparameter_new_clone(parameter));
    }
  }
  RemoveProperties(c,kind);
  if(p) icalcomponent_add_property(c,p); return YES;
}
static NSString *WeekdayToken(NSString *day)
{
  NSDictionary *days=[NSDictionary dictionaryWithObjectsAndKeys:@"SU",@"sunday",@"MO",@"monday",@"TU",@"tuesday",@"WE",@"wednesday",@"TH",@"thursday",@"FR",@"friday",@"SA",@"saturday",nil];
  return [days objectForKey:[day lowercaseString]];
}
static NSString *RuleValue(NSDictionary *rule,BOOL allDay,RCError *error)
{
  NSString *frequency=[[rule objectForKey:@"frequency"] uppercaseString];
  if(![[@"DAILY|WEEKLY|MONTHLY|YEARLY" componentsSeparatedByString:@"|"] containsObject:frequency]) goto invalid;
  NSMutableArray *parts=[NSMutableArray arrayWithObject:[@"FREQ=" stringByAppendingString:frequency]];
  NSString *keys[]={@"interval",@"count"}; int k;
  for(k=0;k<2;k++) if([rule objectForKey:keys[k]]) {
    int value=[[rule objectForKey:keys[k]] intValue]; if(k==1 && value==0) continue; if(value<1) goto invalid;
    [parts addObject:[NSString stringWithFormat:@"%@=%d",[keys[k] uppercaseString],value]];
  }
  if([rule objectForKey:@"until"]) {
    if([[rule objectForKey:@"count"] intValue]>0) goto invalid;
    NSString *date=DateValue([rule objectForKey:@"until"],allDay,nil); if(!date) goto invalid;
    [parts addObject:[@"UNTIL=" stringByAppendingString:date]];
  }
  NSString *arrays[]={@"bymonth",@"bymonthday",@"byyearday",@"byweeknumber",@"bysetpos"};
  NSString *names[]={@"BYMONTH",@"BYMONTHDAY",@"BYYEARDAY",@"BYWEEKNO",@"BYSETPOS"};
  for(k=0;k<5;k++) if([[rule objectForKey:arrays[k]] count]) {
    NSMutableArray *values=[NSMutableArray array]; NSEnumerator *it=[[rule objectForKey:arrays[k]] objectEnumerator]; id value;
    while((value=[it nextObject])) [values addObject:[NSString stringWithFormat:@"%d",[value intValue]]];
    [parts addObject:[NSString stringWithFormat:@"%@=%@",names[k],[values componentsJoinedByString:@","]]];
  }
  NSArray *days=[rule objectForKey:@"bydaydays"], *positions=[rule objectForKey:@"bydayfreq"];
  if([days count]!=[positions count]) goto invalid;
  if([days count]) {
    NSMutableArray *values=[NSMutableArray array]; NSUInteger n;
    for(n=0;n<[days count];n++) {
      NSString *day=WeekdayToken([days objectAtIndex:n]); int pos=[[positions objectAtIndex:n] intValue];
      if(!day || pos < -53 || pos > 53) goto invalid;
      [values addObject:pos ? [NSString stringWithFormat:@"%d%@",pos,day] : day];
    }
    [parts addObject:[@"BYDAY=" stringByAppendingString:[values componentsJoinedByString:@","]]];
  }
  if([rule objectForKey:@"weekstartday"]) {
    NSString *day=WeekdayToken([rule objectForKey:@"weekstartday"]); if(!day) goto invalid;
    [parts addObject:[@"WKST=" stringByAppendingString:day]];
  }
  return [parts componentsJoinedByString:@";"];
invalid:
  RCErrorSet(error,1,"Invalid native recurrence rule"); return nil;
}
static BOOL ChildChanges(NSDictionary *old,NSDictionary *record,NSString *link,NSDictionary *base,NSDictionary *truth)
{
  if(!RCNativePropertyValuesEqual(eventEntity,link,[old objectForKey:link],[record objectForKey:link])) return YES;
  NSEnumerator *it=[[record objectForKey:link] objectEnumerator]; NSString *identifier;
  while((identifier=[it nextObject])) if(!RCTwoWayRecordsEqual([base objectForKey:identifier],[truth objectForKey:identifier])) return YES;
  return NO;
}
static BOOL StructuralFieldChanged(NSDictionary *old,NSDictionary *record,NSString *key)
{
  return !old || !RCNativePropertyValuesEqual([record objectForKey:ISyncRecordEntityNameKey],key,[old objectForKey:key],[record objectForKey:key]);
}
static BOOL UpdateAlarm(icalcomponent *alarm,NSDictionary *old,NSDictionary *record,BOOL audio,RCError *error)
{
  NSDate *date=[record objectForKey:@"triggerdate"]; NSNumber *duration=[record objectForKey:@"triggerduration"];
  if(RCNativeEmptyValue(date)) date=nil;
  if(RCNativeEmptyValue(duration)) duration=nil;
  if((date!=nil)==(duration!=nil)) { RCErrorSet(error,1,"Alarm needs exactly one trigger"); return NO; }
  if(!old && !ReplaceLine(alarm,@"ACTION",audio ? @"AUDIO" : @"DISPLAY",error)) return NO;
  if(StructuralFieldChanged(old,record,@"triggerdate") || StructuralFieldChanged(old,record,@"triggerduration")) {
    NSString *value=nil;
    if(date) value=DateValue(date,NO,nil);
    else { char *text=icaldurationtype_as_ical_string_r(icaldurationtype_from_int([duration intValue])); value=S(text); free(text); }
    if(!value || !ReplaceLine(alarm,date ? @"TRIGGER;VALUE=DATE-TIME" : @"TRIGGER",value,error)) return NO;
  }
  if(StructuralFieldChanged(old,record,@"description") &&
      !ReplaceLine(alarm,@"DESCRIPTION",!RCNativeEmptyValue([record objectForKey:@"description"]) ? RCTwoWayEscape([record objectForKey:@"description"]) : nil,error)) return NO;
  NSNumber *repeat=[record objectForKey:@"repeat count"], *interval=[record objectForKey:@"repeat interval"];
  if((repeat!=nil)!=(interval!=nil) || (repeat && ([repeat intValue]<1 || [interval intValue]<1))) { RCErrorSet(error,1,"Alarm repeat requires positive count and interval"); return NO; }
  if(StructuralFieldChanged(old,record,@"repeat count") && !ReplaceLine(alarm,@"REPEAT",repeat ? [repeat stringValue] : nil,error)) return NO;
  if(StructuralFieldChanged(old,record,@"repeat interval")) {
    char *text=interval ? icaldurationtype_as_ical_string_r(icaldurationtype_from_int([interval intValue])) : NULL;
    BOOL ok=ReplaceLine(alarm,@"DURATION",text ? S(text) : nil,error); free(text); if(!ok) return NO;
  }
  if(audio) {
    BOOL valid,oldValid; NSURL *sound=RCNativeAlarmSound(record,&valid), *prior=RCNativeAlarmSound(old,&oldValid);
    if(!valid || (old && !oldValid)) { RCErrorSet(error,1,"Invalid alarm sound"); return NO; }
    if(!old || !((!sound && !prior) || [sound isEqual:prior])) {
      if(!prior && icalcomponent_count_properties(alarm,ICAL_ATTACH_PROPERTY)) { RCErrorSet(error,1,"Opaque alarm attachments must be preserved"); return NO; }
      if(!ReplaceLine(alarm,@"ATTACH",SoundValue(sound),error)) return NO;
    }
  }
  return YES;
}
static NSString *ParticipantToken(NSString *value)
{
  NSDictionary *tokens=[NSDictionary dictionaryWithObjectsAndKeys:@"REQ-PARTICIPANT",@"requiredparticipant",@"OPT-PARTICIPANT",@"optionalparticipant",@"NON-PARTICIPANT",@"nonparticipant",@"NEEDS-ACTION",@"needsaction",@"IN-PROCESS",@"inprocess",nil];
  return [tokens objectForKey:value] ?: [value uppercaseString];
}
static BOOL UpdatePerson(icalproperty *p,NSDictionary *record,BOOL organizer,RCError *error)
{
  NSString *email=[record objectForKey:@"email"];
  if(![email length] || [email rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location!=NSNotFound) { RCErrorSet(error,1,"Invalid participant email"); return NO; }
  NSString *uri=[@"mailto:" stringByAppendingString:email];
  if(organizer) icalproperty_set_organizer(p,[uri UTF8String]); else icalproperty_set_attendee(p,[uri UTF8String]);
  icalproperty_remove_parameter_by_kind(p,ICAL_CN_PARAMETER);
  if([[record objectForKey:@"common name"] length]) icalproperty_add_parameter(p,icalparameter_new_cn([[record objectForKey:@"common name"] UTF8String]));
  if(!organizer) {
    NSString *keys[]={@"role",@"status",@"user type"};
    const char *names[]={"ROLE","PARTSTAT","CUTYPE"};
    icalparameter_kind kinds[]={ICAL_ROLE_PARAMETER,ICAL_PARTSTAT_PARAMETER,ICAL_CUTYPE_PARAMETER}; int k;
    for(k=0;k<3;k++) {
      icalproperty_remove_parameter_by_kind(p,kinds[k]);
      NSString *value=[record objectForKey:keys[k]];
      if([value length]) {
        NSString *line=[NSString stringWithFormat:@"%s=%@",names[k],ParticipantToken(value)];
        icalparameter *param=icalparameter_new_from_string([line UTF8String]);
        if(!param) { RCErrorSet(error,1,"Invalid participant parameter"); return NO; }
        icalproperty_add_parameter(p,param);
      }
    }
    icalproperty_remove_parameter_by_kind(p,ICAL_RSVP_PARAMETER);
    icalproperty_add_parameter(p,icalparameter_new_rsvp([[record objectForKey:@"rsvp"] boolValue] ? ICAL_RSVP_TRUE : ICAL_RSVP_FALSE));
  }
  return YES;
}
static BOOL ApplyStructure(icalcomponent *event,NSDictionary *old,NSDictionary *record,
    NSDictionary *base,NSDictionary *truth,NSString *path,NSMutableDictionary *paths,RCError *error)
{
  int k;
  if(!old || !RCNativePropertyValuesEqual(eventEntity,@"all day",[old objectForKey:@"all day"],[record objectForKey:@"all day"])) {
    BOOL allDay=[[record objectForKey:@"all day"] boolValue];
    if(!ReplaceLine(event,allDay ? @"DTSTART;VALUE=DATE" : @"DTSTART",DateValue([record objectForKey:@"start date"],allDay,nil),error) ||
        !ReplaceLine(event,allDay ? @"DTEND;VALUE=DATE" : @"DTEND",DateValue([record objectForKey:@"end date"],allDay,nil),error)) return NO;
    RemoveProperties(event,ICAL_DURATION_PROPERTY);
  }
  for(k=0;k<5;k++) if(!old || ChildChanges(old,record,childLinks[k],base,truth)) {
    NSArray *ids=[record objectForKey:childLinks[k]] ?: [NSArray array], *oldIDs=[old objectForKey:childLinks[k]];
    NSString *prefix=[NSString stringWithFormat:@"%@/%@:",path,childLinks[k]];
    NSEnumerator *it=[[[[paths allKeys] copy] autorelease] objectEnumerator]; NSString *key;
    while((key=[it nextObject])) if([key hasPrefix:prefix]) [paths removeObjectForKey:key];
    if(k==0) {
      if([ids count]>1 || icalcomponent_count_properties(event,ICAL_RDATE_PROPERTY) || icalcomponent_count_properties(event,ICAL_EXRULE_PROPERTY)) { RCErrorSet(error,1,"Unsupported compound recurrence"); return NO; }
      NSString *value=[ids count] ? RuleValue([truth objectForKey:[ids objectAtIndex:0]],[[record objectForKey:@"all day"] boolValue],error) : nil;
      if(([ids count] && !value) || !ReplaceLine(event,@"RRULE",value,error)) return NO;
    } else if(k==1 || k==2) {
      NSMutableArray *original=[NSMutableArray array]; icalcomponent *alarm;
      for(alarm=icalcomponent_get_first_component(event,ICAL_VALARM_COMPONENT);alarm;alarm=icalcomponent_get_next_component(event,ICAL_VALARM_COMPONENT)) {
        const char *action=RCICalendarValue(alarm,ICAL_ACTION_PROPERTY);
        if(action && !strcmp(action,k==1 ? "DISPLAY" : "AUDIO")) [original addObject:[NSValue valueWithPointer:alarm]];
      }
      if([original count]!=[oldIDs count] && old) { RCErrorSet(error,1,"Ambiguous alarm mapping"); return NO; }
      NSUInteger n;
      for(n=0;n<[ids count];n++) {
        NSString *identifier=[ids objectAtIndex:n]; NSUInteger index=[oldIDs indexOfObject:identifier];
        icalcomponent *copy=oldIDs && index!=NSNotFound ? icalcomponent_new_clone([[original objectAtIndex:index] pointerValue]) : icalcomponent_new_valarm();
        if(!UpdateAlarm(copy,[base objectForKey:identifier],[truth objectForKey:identifier],k==2,error)) { icalcomponent_free(copy); return NO; }
        icalcomponent_add_component(event,copy);
      }
      for(n=0;n<[original count];n++) { alarm=[[original objectAtIndex:n] pointerValue]; icalcomponent_remove_component(event,alarm); icalcomponent_free(alarm); }
    } else {
      icalproperty_kind kind=k==4 ? ICAL_ORGANIZER_PROPERTY : ICAL_ATTENDEE_PROPERTY;
      if(k==4 && [ids count]>1) { RCErrorSet(error,1,"Multiple organizers"); return NO; }
      NSMutableArray *original=[NSMutableArray array]; icalproperty *p;
      for(p=icalcomponent_get_first_property(event,kind);p;p=icalcomponent_get_next_property(event,kind)) {
        const char *value=icalproperty_get_value_as_string(p);
        if(value && !strncasecmp(value,"mailto:",7)) [original addObject:[NSValue valueWithPointer:p]];
      }
      NSUInteger n;
      for(n=0;n<[ids count];n++) {
        NSString *identifier=[ids objectAtIndex:n]; NSUInteger index=[oldIDs indexOfObject:identifier];
        icalproperty *copy=oldIDs && index!=NSNotFound && index<[original count] ? icalproperty_new_clone([[original objectAtIndex:index] pointerValue]) : (k==4 ? icalproperty_new_organizer("") : icalproperty_new_attendee(""));
        if(!UpdatePerson(copy,[truth objectForKey:identifier],k==4,error)) { icalproperty_free(copy); return NO; }
        icalcomponent_add_property(event,copy);
      }
      for(n=0;n<[original count];n++) { p=[[original objectAtIndex:n] pointerValue]; icalcomponent_remove_property(event,p); icalproperty_free(p); }
    }
    NSUInteger n; for(n=0;n<[ids count];n++) [paths setObject:[ids objectAtIndex:n] forKey:[prefix stringByAppendingFormat:@"%lu",(unsigned long)n]];
  }
  return YES;
}
static NSDictionary *PrepareStructure(NSDictionary *resource,NSDictionary *truth,RCError *error)
{
  NSData *raw=[resource objectForKey:@"body"]; NSDictionary *base=[resource objectForKey:@"graph"];
  NSArray *sources=SourceEvents(raw,error); if(!sources) return nil;
  NSMutableData *body=[NSMutableData dataWithData:raw];
  NSMutableDictionary *paths=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"paths"]];
  NSMutableDictionary *graph=[NSMutableDictionary dictionaryWithDictionary:base];
  icalcomponent *calendar=RCICalendarParse([raw bytes],[raw length],error); if(!calendar) return nil;
  NSEnumerator *it=[sources reverseObjectEnumerator]; NSDictionary *source; BOOL ok=YES;
  while((source=[it nextObject])) {
    NSString *path=[source objectForKey:@"path"], *identifier=[paths objectForKey:path];
    NSDictionary *old=[base objectForKey:identifier], *record=[truth objectForKey:identifier];
    if(!old || !record) continue;
    BOOL changed=!RCNativePropertyValuesEqual(eventEntity,@"all day",[old objectForKey:@"all day"],[record objectForKey:@"all day"]); int k;
    for(k=0;k<5;k++) if(ChildChanges(old,record,childLinks[k],base,truth)) {
      BOOL onlySound=k==2 && RCNativePropertyValuesEqual(eventEntity,childLinks[k],[old objectForKey:childLinks[k]],[record objectForKey:childLinks[k]]);
      NSEnumerator *sounds=[[record objectForKey:childLinks[k]] objectEnumerator]; NSString *soundID;
      while(onlySound && (soundID=[sounds nextObject])) {
        NSMutableDictionary *a=[NSMutableDictionary dictionaryWithDictionary:[base objectForKey:soundID] ?: [NSDictionary dictionary]];
        NSMutableDictionary *b=[NSMutableDictionary dictionaryWithDictionary:[truth objectForKey:soundID] ?: [NSDictionary dictionary]];
        [a removeObjectForKey:@"sound"]; [a removeObjectForKey:@"com.apple.ical.sound"];
        [b removeObjectForKey:@"sound"]; [b removeObjectForKey:@"com.apple.ical.sound"];
        onlySound=RCTwoWayRecordsEqual(a,b);
      }
      if(!onlySound) changed=YES;
    }
    if(!changed) continue;
    icalcomponent *event;
    for(event=icalcomponent_get_first_component(calendar,ICAL_VEVENT_COMPONENT);event;event=icalcomponent_get_next_component(calendar,ICAL_VEVENT_COMPONENT))
      if([SourceEvent(sources,event) isEqual:source]) break;
    if(!event || !ApplyStructure(event,old,record,base,truth,path,paths,error)) { ok=NO; break; }
    NSMutableDictionary *updated=[NSMutableDictionary dictionaryWithDictionary:old];
    NSString *dateKeys[]={@"all day",@"start date",@"end date"};
    if(!RCNativePropertyValuesEqual(eventEntity,@"all day",[old objectForKey:@"all day"],[record objectForKey:@"all day"]))
      for(k=0;k<3;k++) { if([record objectForKey:dateKeys[k]]) [updated setObject:[record objectForKey:dateKeys[k]] forKey:dateKeys[k]]; else [updated removeObjectForKey:dateKeys[k]]; }
    for(k=0;k<5;k++) {
      NSEnumerator *children=[[old objectForKey:childLinks[k]] objectEnumerator]; NSString *child;
      while((child=[children nextObject])) [graph removeObjectForKey:child];
      children=[[record objectForKey:childLinks[k]] objectEnumerator];
      while((child=[children nextObject])) if([truth objectForKey:child]) [graph setObject:[truth objectForKey:child] forKey:child];
      [updated setObject:[record objectForKey:childLinks[k]] ?: [NSArray array] forKey:childLinks[k]];
    }
    [graph setObject:updated forKey:identifier];
    char *text=icalcomponent_as_ical_string_r(event); if(!text) { ok=NO; break; }
    [body replaceBytesInRange:[[source objectForKey:@"range"] rangeValue] withBytes:text length:strlen(text)]; free(text);
  }
  icalcomponent_free(calendar); if(!ok) return nil;
  NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:resource];
  [result setObject:body forKey:@"body"]; [result setObject:paths forKey:@"paths"]; [result setObject:graph forKey:@"graph"]; return result;
}
