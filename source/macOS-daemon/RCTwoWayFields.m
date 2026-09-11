#import "RCTwoWaySync.h"
#import "RCSyncFieldScope.h"

static NSArray *Fields(NSString *names)
{
  return [names length] ? [names componentsSeparatedByString:@"|"] : [NSArray array];
}
static BOOL FieldEqual(NSDictionary *a, NSDictionary *b, NSString *key)
{
  /* Compare coupled sound representations together, including default and
     unordered relationship semantics used by the mappers and receipts. */
  NSArray *keys=([key isEqual:@"sound"] || [key isEqual:@"com.apple.ical.sound"]) ?
      Fields(@"sound|com.apple.ical.sound") : [NSArray arrayWithObject:key];
  return RCNativeRecordsEqual(RCNativeScopedRecord(a,keys),RCNativeScopedRecord(b,keys));
}
static BOOL ChangedFields(NSDictionary *a, NSDictionary *b, NSString *names)
{
  NSEnumerator *it=[Fields(names) objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) if (!FieldEqual(a,b,key)) return YES;
  return NO;
}
static BOOL RemovedOwner(NSDictionary *old, NSDictionary *base, NSDictionary *truth)
{
  NSArray *owners=[old objectForKey:@"owner"];
  if ([owners count]!=1) return NO;
  NSString *owner=[owners objectAtIndex:0];
  return [[[base objectForKey:owner] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.calendars.Event"] && ![truth objectForKey:owner];
}
/* These are encoder capabilities, not a catalogue of every schema property.
   Unknown fields stay in native truth; unknown wire data stays in the raw body.
   Identity/ownership fields remain strict so projections cannot move a child
   into another contact, calendar or recurring series. */
static NSArray *Writable(NSDictionary *old, NSDictionary *record)
{
  NSString *entity=[record objectForKey:ISyncRecordEntityNameKey] ?: [old objectForKey:ISyncRecordEntityNameKey];
  NSString *names=nil;
  if ([entity isEqual:@"com.apple.contacts.Contact"])
    names=@"first name|last name|middle name|title|suffix|nickname|company name|department|job title|birthday|notes|image|first name yomi|middle name yomi|last name yomi|company name yomi|dates|related names|IMs|primary phone number|primary email address|primary street address|primary URL|display as company|phone numbers|email addresses|street addresses|URLs";
  else if ([entity hasPrefix:@"com.apple.contacts."]) {
    if ([entity isEqual:@"com.apple.contacts.Street Address"])
      names= @"contact|street|city|state|postal code|country|country code|type|label";
    else if ([entity isEqual:@"com.apple.contacts.Phone Number"] || [entity isEqual:@"com.apple.contacts.Email Address"] || [entity isEqual:@"com.apple.contacts.URL"])
      names= @"contact|value|type|label";
    else if ([entity isEqual:@"com.apple.contacts.Date"] || [entity isEqual:@"com.apple.contacts.Related Name"]) names=@"contact|value|type|label";
    else if ([entity isEqual:@"com.apple.contacts.IM"]) names=@"contact|user|service|type|label";
  } else if ([entity isEqual:@"com.apple.calendars.Event"]) {
    names=@"summary|description|location|url|status|classification|calendar|main event|original date|start date|end date|all day|exception dates|detached events|recurrences|attendees|organizer|display alarms|audio alarms";
  } else if ([entity isEqual:@"com.apple.calendars.Recurrence"])
    names=@"owner|frequency|interval|count|until|bymonth|bymonthday|byyearday|byweeknumber|bysetpos|bydaydays|bydayfreq|weekstartday";
  else if ([entity isEqual:@"com.apple.calendars.Attendee"] || [entity isEqual:@"com.apple.calendars.Organizer"])
    names=@"owner|email|common name|role|status|user type|rsvp";
  else if ([entity isEqual:@"com.apple.calendars.AudioAlarm"] || [entity isEqual:@"com.apple.calendars.DisplayAlarm"])
    names=@"owner|description|triggerdate|triggerduration|repeat count|repeat interval|sound|com.apple.ical.sound";
  NSMutableArray *result=[NSMutableArray arrayWithArray:Fields(names)];
  if (names) [result addObject:ISyncRecordEntityNameKey];
  return result;
}

/* Forward-mapped optional properties are distinguishable from opaque fields:
   reverting a label or an optional recurrence limit can clear attention even
   when its canonical representation omits the property altogether. */
static NSArray *KnownFields(NSDictionary *record)
{
  NSString *entity=[record objectForKey:ISyncRecordEntityNameKey];
  NSMutableSet *fields=[NSMutableSet setWithArray:Writable(nil,record)];
  [fields addObjectsFromArray:[record allKeys]];
  if ([entity isEqual:@"com.apple.calendars.Recurrence"])
    [fields addObjectsFromArray:Fields(@"owner|frequency|interval|count|until|bymonth|bymonthday|byyearday|byweeknumber|bysetpos|bydaydays|bydayfreq|weekstartday")];
  if ([entity isEqual:@"com.apple.calendars.Attendee"] || [entity isEqual:@"com.apple.calendars.Organizer"])
    [fields addObjectsFromArray:Fields(@"owner|email|common name|role|status|user type|rsvp")];
  return [[fields allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

static NSArray *IndependentGroups(NSDictionary *record)
{
  NSString *entity=[record objectForKey:ISyncRecordEntityNameKey];
  if ([entity isEqual:@"com.apple.contacts.Contact"])
    return [NSArray arrayWithObjects:Fields(@"first name|last name|middle name|title|suffix"),Fields(@"company name|department"),
        Fields(@"first name yomi"),Fields(@"middle name yomi"),Fields(@"last name yomi"),Fields(@"company name yomi"),Fields(@"notes"),Fields(@"image"),Fields(@"job title"),Fields(@"nickname"),Fields(@"birthday"),Fields(@"display as company"),nil];
  if ([entity isEqual:@"com.apple.contacts.Street Address"])
    return [NSArray arrayWithObject:Fields(@"street|city|state|postal code|country")];
  if ([entity isEqual:@"com.apple.contacts.Phone Number"] || [entity isEqual:@"com.apple.contacts.Email Address"] || [entity isEqual:@"com.apple.contacts.URL"])
    return [NSArray arrayWithObject:Fields(@"value")];
  if ([entity isEqual:@"com.apple.calendars.Event"])
    return [NSArray arrayWithObjects:Fields(@"summary"),Fields(@"description"),Fields(@"location"),Fields(@"url"),Fields(@"status"),Fields(@"classification"),nil];
  if ([entity isEqual:@"com.apple.calendars.AudioAlarm"])
    return [NSArray arrayWithObject:Fields(@"sound|com.apple.ical.sound")];
  return [NSArray array];
}
static NSMutableArray *IntersectFields(NSArray *fields, NSArray *scope)
{
  NSMutableArray *result=[NSMutableArray array]; NSEnumerator *it=[fields objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) if ([scope containsObject:key]) [result addObject:key];
  return result;
}
static void CopyFields(NSMutableDictionary *graph, NSDictionary *source, NSString *identifier, NSArray *fields)
{
  NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:[graph objectForKey:identifier]];
  NSEnumerator *it=[fields objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) {
    id value=[[source objectForKey:identifier] objectForKey:key];
    if (value) [record setObject:value forKey:key]; else [record removeObjectForKey:key];
  }
  [graph setObject:record forKey:identifier];
}
/* A field can be supported in general but uneditable in a particular raw
   representation (legacy CHARSET, DURATION dates, ambiguous repetitions).
   Retry independent atomic groups against the SAME original resource, keeping
   only groups that pass the strict forward/reverse validation. No writes or
   native acknowledgements occur while planning. Structural edits stay together. */
static NSMutableDictionary *EncodeIndependent(RCTwoWayEncoder encoder, void *context,
    NSDictionary *resource, NSDictionary *projected, NSDictionary *base, NSSet *ids,
    NSMutableDictionary *scopes, NSString *root, RCError *error)
{
  NSMutableDictionary *working=[NSMutableDictionary dictionaryWithDictionary:projected];
  NSMutableArray *groups=[NSMutableArray array];
  NSEnumerator *records=[[[base allKeys] sortedArrayUsingSelector:@selector(compare:)] objectEnumerator]; NSString *identifier;
  while ((identifier=[records nextObject])) {
    NSDictionary *old=[base objectForKey:identifier], *record=[projected objectForKey:identifier];
    if (!record) continue;
    /* Ownership is not a scalar edit that a fallback can reinterpret. */
    if (ChangedFields(old,record,@"com.apple.syncservices.RecordEntityName|contact|owner|calendar|main event|original date")) return nil;
    NSEnumerator *sets=[IndependentGroups(old) objectEnumerator]; NSArray *fields;
    while ((fields=[sets nextObject])) {
      NSMutableArray *allowed=IntersectFields(fields,[scopes objectForKey:identifier]);
      if (![allowed count]) continue;
      [groups addObject:[NSArray arrayWithObjects:identifier,allowed,nil]];
      CopyFields(working,base,identifier,allowed);
    }
  }
  RCErrorClear(error);
  NSMutableDictionary *result=encoder(context,resource,working,root,error);
  if (!result) {
    /* The structural group failed. Restore it intact, including the children
       of a removed occurrence. Only independent fields remain in the receipt. */
    records=[ids objectEnumerator];
    while ((identifier=[records nextObject])) {
      NSDictionary *old=[base objectForKey:identifier];
      if (old) [working setObject:old forKey:identifier]; else [working removeObjectForKey:identifier];
      NSArray *prior=[scopes objectForKey:identifier];
      NSMutableArray *allowed=[NSMutableArray array];
      if (old && [projected objectForKey:identifier]) {
        NSEnumerator *sets=[IndependentGroups(old) objectEnumerator]; NSArray *fields;
        while ((fields=[sets nextObject])) [allowed addObjectsFromArray:fields];
        [allowed addObjectsFromArray:Fields(@"com.apple.syncservices.RecordEntityName|contact|owner|calendar|main event|original date")];
        allowed=IntersectFields(allowed,prior);
      }
      [scopes setObject:allowed forKey:identifier];
    }
    RCErrorClear(error); result=encoder(context,resource,working,root,error);
    if (!result) return nil;
  }
  NSEnumerator *sets=[groups objectEnumerator]; NSArray *group;
  while ((group=[sets nextObject])) {
    identifier=[group objectAtIndex:0]; NSArray *fields=[group objectAtIndex:1];
    if (![working objectForKey:identifier] || ![projected objectForKey:identifier]) continue;
    BOOL changed=NO; NSEnumerator *names=[fields objectEnumerator]; NSString *name;
    while ((name=[names nextObject])) if (!FieldEqual([working objectForKey:identifier],[projected objectForKey:identifier],name)) changed=YES;
    if (!changed) continue;
    NSMutableDictionary *candidate=[NSMutableDictionary dictionaryWithDictionary:working];
    CopyFields(candidate,projected,identifier,fields); RCErrorClear(error);
    NSMutableDictionary *encoded=encoder(context,resource,candidate,root,error);
    if (encoded) { working=candidate; result=encoded; }
    else {
      NSMutableArray *allowed=[NSMutableArray arrayWithArray:[scopes objectForKey:identifier]];
      [allowed removeObjectsInArray:fields]; [scopes setObject:allowed forKey:identifier];
    }
  }
  RCErrorClear(error); return result;
}

NSMutableDictionary *RCTwoWayEncodeFields(RCTwoWayEncoder encoder, void *context,
    NSDictionary *resource, NSDictionary *truth, NSString *root, RCError *error)
{
  NSDictionary *base=[resource objectForKey:@"graph"];
  NSMutableSet *ids=[NSMutableSet setWithArray:[base allKeys] ?: [NSArray array]];
  [ids addObject:root];
  /* Follow child relationships, including unfamiliar child entity types, to
     report pending fields without capturing unrelated contacts or containers. */
  NSMutableArray *queue=[NSMutableArray arrayWithArray:[ids allObjects]]; NSUInteger n;
  for (n=0;n<[queue count];n++) {
    NSDictionary *record=[truth objectForKey:[queue objectAtIndex:n]];
    NSEnumerator *keys=[record keyEnumerator]; NSString *key;
    while ((key=[keys nextObject])) {
      if ([Fields(@"contact|owner|calendar|main event|parent groups") containsObject:key]) continue;
      id value=[record objectForKey:key];
      if (![value isKindOfClass:[NSArray class]]) continue;
      NSEnumerator *items=[value objectEnumerator]; id child;
      while ((child=[items nextObject])) if ([child isKindOfClass:[NSString class]] && [truth objectForKey:child] && ![ids containsObject:child]) {
        NSString *entity=[[truth objectForKey:child] objectForKey:ISyncRecordEntityNameKey];
        if ([entity isEqual:@"com.apple.calendars.Calendar"] || [entity isEqual:@"com.apple.contacts.Contact"]) continue;
        [ids addObject:child]; [queue addObject:child];
      }
    }
  }
  NSEnumerator *it; NSString *identifier;
  NSMutableDictionary *projected=[NSMutableDictionary dictionaryWithDictionary:truth];
  NSMutableDictionary *scopes=[NSMutableDictionary dictionary];
  it=[ids objectEnumerator];
  while ((identifier=[it nextObject])) {
    NSDictionary *old=[base objectForKey:identifier], *record=[truth objectForKey:identifier];
    NSMutableArray *fields=[NSMutableArray arrayWithArray:Writable(old,record)];
    /* Deletion must still pass the strict mapper and relationship validation. */
    if (!record && ([fields count] || !old || RemovedOwner(old,base,truth))) { [scopes setObject:fields forKey:identifier]; continue; }
    NSMutableDictionary *selected=[NSMutableDictionary dictionaryWithDictionary:old ?: [NSDictionary dictionary]];
    NSEnumerator *keys=[fields objectEnumerator]; NSString *key;
    while ((key=[keys nextObject])) {
      if ([record objectForKey:key]) [selected setObject:[record objectForKey:key] forKey:key];
      else [selected removeObjectForKey:key];
    }
    if (!old && [fields containsObject:@"type"]) {
      NSString *entity=[record objectForKey:ISyncRecordEntityNameKey];
      id type=[record objectForKey:@"type"];
      NSMutableArray *types=[NSMutableArray arrayWithArray:Fields(@"home|work|other")];
      if ([entity isEqual:@"com.apple.contacts.Phone Number"]) [types addObjectsFromArray:Fields(@"mobile|pager|home fax|work fax")];
      if ([entity isEqual:@"com.apple.contacts.URL"]) [types addObject:@"home page"];
      if ([entity isEqual:@"com.apple.contacts.Date"]) [types addObject:@"anniversary"];
      if ([entity isEqual:@"com.apple.contacts.Related Name"]) [types addObjectsFromArray:Fields(@"father|mother|parent|child|brother|sister|friend|spouse|partner|assistant|manager")];
      if ([type isKindOfClass:[NSString class]] && [type length] && ![types containsObject:type]) {
        /* An unfamiliar schema type is not a custom label whose meaning we
           can invent. Create the supported value as 'other'; keep type pending. */
        [selected setObject:@"other" forKey:@"type"]; [fields removeObject:@"type"];
      }
    }
    if ([selected count]) [projected setObject:selected forKey:identifier];
    else [projected removeObjectForKey:identifier];
    [scopes setObject:fields forKey:identifier];
  }
  if (!resource && [[[projected objectForKey:root] objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.contacts.Contact"]) {
    NSDictionary *record=[projected objectForKey:root]; BOOL content=NO;
    NSEnumerator *keys=[record keyEnumerator]; NSString *key;
    while ((key=[keys nextObject])) if (![key isEqual:ISyncRecordEntityNameKey] &&
        !([key isEqual:@"display as company"] && [[record objectForKey:key] isEqual:@"person"]) && !RCNativeEmptyValue([record objectForKey:key])) content=YES;
    if (!content) { RCErrorSet(error,1,"New contact has no supported content to upload"); return nil; }
  }
  NSMutableDictionary *desired=encoder(context,resource,projected,root,error);
  if (!desired && resource) desired=EncodeIndependent(encoder,context,resource,projected,base,ids,scopes,root,error);
  if (!desired) return nil;
  NSMutableDictionary *pending=[NSMutableDictionary dictionary], *usedScopes=[NSMutableDictionary dictionary], *knownFields=[NSMutableDictionary dictionary];
  NSDictionary *graph=[desired objectForKey:@"graph"];
  it=[ids objectEnumerator];
  while ((identifier=[it nextObject])) {
    NSDictionary *record=[truth objectForKey:identifier], *represented=[graph objectForKey:identifier];
    if (represented) {
      [usedScopes setObject:[scopes objectForKey:identifier] ?: [NSArray array] forKey:identifier];
      [knownFields setObject:KnownFields(represented) forKey:identifier];
    }
    NSMutableSet *keys=[NSMutableSet setWithArray:[record allKeys] ?: [NSArray array]];
    [keys addObjectsFromArray:[represented allKeys] ?: [NSArray array]];
    NSMutableArray *different=[NSMutableArray array];
    if (represented && !record) [different addObject:@"record deletion"];
    else {
      NSEnumerator *fields=[[[keys allObjects] sortedArrayUsingSelector:@selector(compare:)] objectEnumerator]; NSString *key;
      while ((key=[fields nextObject])) if (!FieldEqual(record,represented,key)) [different addObject:key];
    }
    if ([different count]) [pending setObject:different forKey:identifier];
  }
  [desired setObject:usedScopes forKey:@"fieldScopes"];
  [desired setObject:pending forKey:@"pendingFields"];
  [desired setObject:knownFields forKey:@"knownFields"];
  return desired;
}
