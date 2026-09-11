#import "RCLogger.h"
#import "RCTwoWayNative.h"
#import "RCCalendarSyncClient.h"
#import "RCSyncRecordEquality.h"
#include "RCResourcePatch.h"
#include <stdlib.h>
#include <errno.h>
#include <string.h>

static NSString *S(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }
static NSString *eventEntity=@"com.apple.calendars.Event";
static NSString *childLinks[]={@"recurrences",@"display alarms",@"audio alarms",@"attendees",@"organizer"};
/* Report field names only; never log event text, participant addresses or URLs.
   Use the same semantic comparison as upload validation so iCal bookkeeping
   and omitted default values are not reported as meaningful differences. */
static NSString *DifferentField(NSDictionary *a, NSDictionary *b)
{
  if (!a || !b) return @"record presence";
  NSMutableSet *keys=[NSMutableSet setWithArray:[a allKeys]];
  [keys addObjectsFromArray:[b allKeys]];
  NSEnumerator *it=[[[keys allObjects] sortedArrayUsingSelector:@selector(compare:)] objectEnumerator];
  NSString *key;
  while ((key=[it nextObject])) {
    NSMutableDictionary *left=[NSMutableDictionary dictionary], *right=[NSMutableDictionary dictionary];
    if ([a objectForKey:ISyncRecordEntityNameKey]) [left setObject:[a objectForKey:ISyncRecordEntityNameKey] forKey:ISyncRecordEntityNameKey];
    if ([b objectForKey:ISyncRecordEntityNameKey]) [right setObject:[b objectForKey:ISyncRecordEntityNameKey] forKey:ISyncRecordEntityNameKey];
    if ([a objectForKey:key]) [left setObject:[a objectForKey:key] forKey:key];
    if ([b objectForKey:key]) [right setObject:[b objectForKey:key] forKey:key];
    if (!RCTwoWayRecordsEqual(left,right)) return key;
  }
  return @"record structure";
}
static NSString *DateValue(NSDate *date, BOOL allDay, NSTimeZone *zone)
{
  if (![date isKindOfClass:[NSDate class]]) return nil;
  return [date descriptionWithCalendarFormat:allDay ? @"%Y%m%d" : zone ? @"%Y%m%dT%H%M%S" : @"%Y%m%dT%H%M%SZ"
      timeZone:zone ?: [NSTimeZone timeZoneForSecondsFromGMT:0] locale:nil];
}
static NSString *SoundValue(id sound)
{
  if (![sound isKindOfClass:[NSURL class]]) return nil;
  NSString *value=[sound absoluteString];
  return [value length] && [value rangeOfString:@"\r"].location==NSNotFound && [value rangeOfString:@"\n"].location==NSNotFound ? value : nil;
}
/* libical puts VTIMEZONE first. Select events in the immutable wire body,
   not by their position in the parsed tree. Ranges and indices share the
   patcher's unfolded-line/source-order convention. */
static NSArray *SourceEvents(NSData *body, RCError *error)
{
  const unsigned char *bytes=[body bytes]; NSUInteger length=[body length],pos=0,start=0;
  int depth=0,component=0,eventComponent=0;
  NSMutableArray *result=[NSMutableArray array];
  while (pos<length) {
    NSUInteger begin=pos;
    NSMutableData *line=[NSMutableData data];
    do {
      NSUInteger part=pos;
      while(pos<length && bytes[pos]!='\r' && bytes[pos]!='\n') pos++;
      [line appendBytes:bytes+part length:pos-part];
      if(pos<length && bytes[pos]=='\r') pos++;
      if(pos<length && bytes[pos]=='\n') pos++;
      if(pos==length || (bytes[pos]!=' ' && bytes[pos]!='\t')) break;
      pos++;
    } while(pos<length);
    NSString *text=[[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] autorelease];
    text=[text uppercaseString];
    if([text hasPrefix:@"BEGIN:"]) {
      if(depth==1 && [text isEqual:@"BEGIN:VEVENT"]) { start=begin; eventComponent=component; }
      depth++; component++;
    } else if([text hasPrefix:@"END:"]) {
      if(depth==2 && [text isEqual:@"END:VEVENT"]) {
        NSMutableData *wrapped=[NSMutableData dataWithData:[@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [wrapped appendBytes:bytes+start length:pos-start];
        [wrapped appendData:[@"END:VCALENDAR\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        icalcomponent *parsed=RCICalendarParse([wrapped bytes],[wrapped length],error);
        if(!parsed) return nil;
        icalcomponent *event=icalcomponent_get_first_component(parsed,ICAL_VEVENT_COMPONENT);
        char *key=event ? RCICalendarRecurrenceKey(event) : NULL;
        const char *uid=event ? RCICalendarValue(event,ICAL_UID_PROPERTY) : NULL;
        if(!key || !uid) { free(key); icalcomponent_free(parsed); RCErrorSet(error,1,"Event has no source identity"); return nil; }
        NSString *path=[@"event:" stringByAppendingString:S(key)];
        NSEnumerator *it=[result objectEnumerator]; NSDictionary *previous;
        while((previous=[it nextObject])) if([[previous objectForKey:@"path"] isEqual:path]) {
          free(key); icalcomponent_free(parsed); RCErrorSet(error,1,"Ambiguous source recurrence identity"); return nil;
        }
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:path,@"path",S(uid),@"uid",
            [NSNumber numberWithInt:eventComponent],@"component",[NSValue valueWithRange:NSMakeRange(start,pos-start)],@"range",nil]];
        free(key); icalcomponent_free(parsed);
      }
      depth--;
    }
  }
  return result;
}
static NSDictionary *SourceEvent(NSArray *events,icalcomponent *event)
{
  char *key=RCICalendarRecurrenceKey(event);
  NSString *path=[@"event:" stringByAppendingString:S(key)]; free(key);
  NSEnumerator *it=[events objectEnumerator]; NSDictionary *entry;
  while((entry=[it nextObject])) if([[entry objectForKey:@"path"] isEqual:path] &&
      [[entry objectForKey:@"uid"] isEqual:S(RCICalendarValue(event,ICAL_UID_PROPERTY))]) return entry;
  return nil;
}
static NSDictionary *Paths(RCCalendarStore *store,long long resource,NSData *body,
                           NSDictionary *graph,NSString **rootID,RCError *error)
{
  icalcomponent *calendar=RCICalendarParse([body bytes],[body length],error), *event;
  NSMutableDictionary *paths=[NSMutableDictionary dictionary];
  if (!calendar) return nil;
  for(event=icalcomponent_get_first_component(calendar,ICAL_VEVENT_COMPONENT);event;
      event=icalcomponent_get_next_component(calendar,ICAL_VEVENT_COMPONENT)) {
    char *key=RCICalendarRecurrenceKey(event);
    NSString *owner=[NSString stringWithFormat:@"resource-%lld",resource];
    NSString *objectKey=[NSString stringWithFormat:@"%s:%s",RCICalendarValue(event,ICAL_UID_PROPERTY),key ?: ""];
    char *identifier=RCCalendarStoreIdentity(store,[owner UTF8String],[objectKey UTF8String],error);
    NSString *id=identifier ? [@"cal-" stringByAppendingString:S(identifier)] : nil;
    NSString *path=[@"event:" stringByAppendingString:S(key)];
    free(identifier); free(key);
    if (!id) { icalcomponent_free(calendar); return nil; }
    NSDictionary *record=[graph objectForKey:id];
    if (!record) continue; /* cancelled detached instance retained in raw data */
    [paths setObject:id forKey:path];
    if ([path isEqual:@"event:"]) *rootID=id;
    int k; for(k=0;k<5;k++) {
      NSArray *ids=[record objectForKey:childLinks[k]]; NSUInteger n;
      for(n=0;n<[ids count];n++) [paths setObject:[ids objectAtIndex:n]
          forKey:[NSString stringWithFormat:@"%@/%@:%lu",path,childLinks[k],(unsigned long)n]];
    }
  }
  icalcomponent_free(calendar);
  return paths;
}
static BOOL Validate(RCCalendarStore *, NSData *, NSDictionary *, NSDictionary *, NSString *, RCError *);
NSDictionary *RCCalendarProjectVerified(void *opaque,NSDictionary *current,NSData *body,RCError *error)
{
  RCCalendarStore *store=opaque;
  if ([[current objectForKey:@"detachedReceipt"] boolValue])
    return Validate(store,body,[current objectForKey:@"paths"],[current objectForKey:@"graph"],
        [current objectForKey:@"root"],error) ? current : nil;
  NSString *key=[current objectForKey:@"key"], *root=[current objectForKey:@"root"];
  if (![key hasPrefix:@"resource-"]) return nil;
  const char *number=[[key substringFromIndex:9] UTF8String]; char *end=NULL;
  errno=0; long long identifier=strtoll(number,&end,10);
  if (errno || end==number || !end || *end) return nil;
  NSArray *calendars=[[[current objectForKey:@"graph"] objectForKey:root] objectForKey:@"calendar"];
  if (identifier<=0 || [calendars count]!=1) return nil;
  NSDictionary *graph=RCCalendarNativeGraph(store,identifier,[calendars objectAtIndex:0],body,error);
  NSString *verifiedRoot=nil;
  NSDictionary *paths=graph ? Paths(store,identifier,body,graph,&verifiedRoot,error) : nil;
  /* Stable UID/recurrence identities must agree, even when the current body or
     ETag is newer. A deleted/recreated resource at the same href is not proof. */
  if (!paths || ![verifiedRoot isEqual:root]) return nil;
  NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:current];
  [result setObject:body forKey:@"body"]; [result setObject:graph forKey:@"graph"]; [result setObject:paths forKey:@"paths"];
  return result;
}
static NSString *CalendarURL(RCCalendarStore *store,NSString *nativeID,RCError *error)
{
  RCWriteJournal j=RCCalendarStoreWriteJournal(store); sqlite3_stmt *q=NULL; NSString *url=nil;
  if(!RCTwoWayInitialize(&j,error)) return nil;
  if (sqlite3_prepare_v2(j.db,"SELECT c.url FROM calendars c LEFT JOIN two_way_aliases a ON a.account_id=c.account_id AND a.imported_id='calendar-'||c.sync_id WHERE c.account_id=? AND c.remote_missing=0 AND COALESCE(a.native_id,'calendar-'||c.sync_id)=?",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account); sqlite3_bind_text(q,2,[nativeID UTF8String],-1,SQLITE_TRANSIENT);
    if (sqlite3_step(q)==SQLITE_ROW) url=S((const char *)sqlite3_column_text(q,0));
  }
  sqlite3_finalize(q);
  if (!url) RCErrorSet(error,1,"Create events inside an imported iCloud calendar");
  return url;
}
static BOOL Validate(RCCalendarStore *store, NSData *body, NSDictionary *paths,
                     NSDictionary *truth, NSString *root, RCError *error)
{
  NSArray *calendars=[[truth objectForKey:root] objectForKey:@"calendar"];
  if ([calendars count]!=1) return NO;
  RCWriteJournal j=RCCalendarStoreWriteJournal(store);
  if (!RCTwoWaySQL(&j,error,"SAVEPOINT validate_calendar")) return NO;
  NSDictionary *mapped=RCCalendarNativeGraph(store,-1,[calendars objectAtIndex:0],body,error);
  NSString *unused=nil;
  NSDictionary *generated=mapped ? Paths(store,-1,body,mapped,&unused,error) : nil;
  NSMutableDictionary *aliases=[NSMutableDictionary dictionary];
  NSEnumerator *it=[generated keyEnumerator]; NSString *path;
  while ((path=[it nextObject])) if ([paths objectForKey:path])
    [aliases setObject:[paths objectForKey:path] forKey:[generated objectForKey:path]];
  NSDictionary *projected=mapped ? RCTwoWayRemap(mapped,aliases) : nil;
  NSDictionary *wanted=RCTwoWaySubgraph(truth,[paths allValues]);
  BOOL ok=projected && RCTwoWayGraphsEqual(projected,wanted);
  if (!RCTwoWaySQL(&j,error,"ROLLBACK TO validate_calendar;RELEASE validate_calendar")) return NO;
  if (!ok && projected) {
    NSMutableSet *ids=[NSMutableSet setWithArray:[projected allKeys]];
    [ids addObjectsFromArray:[wanted allKeys]];
    NSEnumerator *records=[[[ids allObjects] sortedArrayUsingSelector:@selector(compare:)] objectEnumerator];
    NSString *identifier;
    while ((identifier=[records nextObject])) if (!RCTwoWayRecordsEqual([projected objectForKey:identifier],[wanted objectForKey:identifier])) {
      RCErrorSet(error,1,"Calendar round-trip differs at record %s field '%s'",[identifier UTF8String],
          [DifferentField([projected objectForKey:identifier],[wanted objectForKey:identifier]) UTF8String]); break;
    }
  } else if (!ok && (!error || !error->code)) RCErrorSet(error,1,"Calendar edit could not be projected into the native schema");
  return ok;
}
#import "RCCalendarStructure.h"
static NSMutableDictionary *Create(RCCalendarStore *store,NSDictionary *truth,NSString *root,RCError *error)
{
  NSDictionary *record=[truth objectForKey:root]; NSArray *calendars=[record objectForKey:@"calendar"];
  if ([calendars count]!=1) { RCErrorSet(error,1,"New event has no unique calendar"); return nil; }
  NSString *collection=CalendarURL(store,[calendars objectAtIndex:0],error);
  if (!collection) return nil;
  /* Scheduling and recurrence structure need their own verified reverse mapper.
     Never silently create a simplified event from a richer native graph. */
  NSString *unsupported[]={@"main event",@"detached events",@"exception dates",@"mail alarms"};
  int k; for(k=0;k<4;k++) if ([[record objectForKey:unsupported[k]] count]) {
    RCErrorSet(error,1,"New event field '%s' requires a richer mapper",[unsupported[k] UTF8String]); return nil;
  }
  BOOL allDay=[[record objectForKey:@"all day"] boolValue];
  NSString *start=DateValue([record objectForKey:@"start date"],allDay,nil), *end=DateValue([record objectForKey:@"end date"],allDay,nil);
  if (!start || !end || [[record objectForKey:@"end date"] compare:[record objectForKey:@"start date"]]==NSOrderedAscending) {
    RCErrorSet(error,1,"New event has invalid dates"); return nil;
  }
  NSString *uid=RCTwoWayNewIdentifier();
  if (!uid) { RCErrorSet(error,1,"Could not allocate remote resource identity"); return nil; }
  NSMutableString *body=[NSMutableString stringWithFormat:@"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Retro Cloud Sync//EN\r\nBEGIN:VEVENT\r\nUID:%@\r\nDTSTAMP:%@\r\nDTSTART%@:%@\r\nDTEND%@:%@\r\n",
      uid,DateValue([NSDate date],NO,nil),allDay ? @";VALUE=DATE" : @"",start,allDay ? @";VALUE=DATE" : @"",end];
  NSString *keys[]={@"summary",@"description",@"location",@"url"}, *names[]={@"SUMMARY",@"DESCRIPTION",@"LOCATION",@"URL"};
  for(k=0;k<4;k++) if ([RCTwoWayString([record objectForKey:keys[k]]) length])
    [body appendFormat:@"%@:%@\r\n",names[k],RCTwoWayEscape([record objectForKey:keys[k]])];
  NSString *status=[record objectForKey:@"status"];
  if ([status length] && ![status isEqual:@"none"]) [body appendFormat:@"STATUS:%@\r\n",[status uppercaseString]];
  if ([[record objectForKey:@"classification"] length]) [body appendFormat:@"CLASS:%@\r\n",[[record objectForKey:@"classification"] uppercaseString]];
  NSMutableDictionary *paths=[NSMutableDictionary dictionaryWithObject:root forKey:@"event:"];
  [body appendString:@"END:VEVENT\r\nEND:VCALENDAR\r\n"];
  NSData *data=[body dataUsingEncoding:NSUTF8StringEncoding];
  icalcomponent *check=RCICalendarParse([data bytes],[data length],error);
  if (!check) return nil;
  icalcomponent *newEvent=icalcomponent_get_first_component(check,ICAL_VEVENT_COMPONENT);
  if(!ApplyStructure(newEvent,nil,record,nil,truth,@"event:",paths,error)) { icalcomponent_free(check); return nil; }
  char *encoded=icalcomponent_as_ical_string_r(check);
  data=encoded ? [NSData dataWithBytes:encoded length:strlen(encoded)] : nil; free(encoded);
  icalcomponent_free(check);
  if (!data || !Validate(store,data,paths,truth,root,error)) return nil;
  return [NSMutableDictionary dictionaryWithObjectsAndKeys:root,@"root",[@"native-" stringByAppendingString:uid],@"key",
      [NSString stringWithFormat:@"%@%@%@.ics",collection,[collection hasSuffix:@"/"] ? @"" : @"/",uid],@"href",data,@"body",
      paths,@"paths",RCTwoWaySubgraph(truth,[paths allValues]),@"graph",nil];
}
static BOOL AddEdit(icalcomponent *event,int component,NSString *property,NSString *value,NSMutableArray *edits,RCError *error)
{
  icalproperty_kind kind=icalproperty_string_to_kind([property UTF8String]);
  int count=icalcomponent_count_properties(event,kind);
  if (count>1) { RCErrorSet(error,1,"Event component %d property %s occurs %d times",component,[property UTF8String],count); return NO; }
  if (!count && !value) return YES;
  [edits addObject:[NSDictionary dictionaryWithObjectsAndKeys:property,@"name",[NSNumber numberWithInt:component],@"component",
      [NSNumber numberWithInt:count ? 0 : -1],@"occurrence",value ?: (id)[NSNull null],@"value",nil]];
  return YES;
}
static int ComponentCount(icalcomponent *component)
{
  int count=1; icalcomponent *child;
  for(child=icalcomponent_get_first_component(component,ICAL_ANY_COMPONENT);child;
      child=icalcomponent_get_next_component(component,ICAL_ANY_COMPONENT)) count+=ComponentCount(child);
  return count;
}
static BOOL AudioEdits(icalcomponent *event,int component,NSDictionary *base,
    NSDictionary *graph,NSDictionary *truth,NSMutableArray *edits,RCError *error)
{
  icalcomponent *alarm; int index=component+1; NSUInteger audio=0;
  NSArray *ids=[base objectForKey:@"audio alarms"];
  for(alarm=icalcomponent_get_first_component(event,ICAL_ANY_COMPONENT);alarm;
      index+=ComponentCount(alarm),alarm=icalcomponent_get_next_component(event,ICAL_ANY_COMPONENT)) {
    const char *action=RCICalendarValue(alarm,ICAL_ACTION_PROPERTY);
    if(icalcomponent_isa(alarm)!=ICAL_VALARM_COMPONENT || !action || strcmp(action,"AUDIO")) continue;
    if(audio>=[ids count]) { RCErrorSet(error,1,"Audio alarm identity is missing"); return NO; }
    NSString *identifier=[ids objectAtIndex:audio++];
    NSDictionary *old=[graph objectForKey:identifier], *record=[truth objectForKey:identifier];
    if(!record) { RCErrorSet(error,1,"Audio alarm removal requires a richer mapper"); return NO; }
    NSMutableDictionary *expected=[NSMutableDictionary dictionaryWithDictionary:old];
    BOOL valid,priorValid;
    NSURL *sound=RCNativeAlarmSound(record,&valid), *prior=RCNativeAlarmSound(old,&priorValid);
    if(!valid || !priorValid) { RCErrorSet(error,1,"Invalid or conflicting audio alarm sound fields"); return NO; }
    [expected removeObjectForKey:@"sound"];
    if(sound) [expected setObject:sound forKey:@"com.apple.ical.sound"]; else [expected removeObjectForKey:@"com.apple.ical.sound"];
    if(!RCTwoWayRecordsEqual(expected,record)) { RCErrorSet(error,1,"Audio alarm field '%s' changed beyond the reverse mapper",[DifferentField(expected,record) UTF8String]); return NO; }
    if((!prior && !sound) || [prior isEqual:sound]) continue;
    int count=icalcomponent_count_properties(alarm,ICAL_ATTACH_PROPERTY);
    icalproperty *p=icalcomponent_get_first_property(alarm,ICAL_ATTACH_PROPERTY);
    if(count>1 || (p && !icalattach_get_is_url(icalproperty_get_attach(p)))) {
      RCErrorSet(error,1,"Embedded or multiple sound attachments require a richer mapper"); return NO;
    }
    if(!count && !sound) continue;
    [edits addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"ATTACH",@"name",
        [NSNumber numberWithInt:index],@"component",[NSNumber numberWithInt:count ? 0 : -1],@"occurrence",
        sound ? (id)SoundValue(sound) : (id)[NSNull null],@"value",nil]];
  }
  return YES;
}
/* Add/remove detached VEVENTs as part of the master's existing DAV resource.
   Existing components remain byte-for-byte intact; only new exceptions are
   cloned. The normal field mapper and final projection verify the whole graph. */
static NSDictionary *PrepareExceptions(RCCalendarStore *store,NSDictionary *resource,
    NSDictionary *truth,NSString *root,RCError *error)
{
  NSDictionary *base=[resource objectForKey:@"graph"], *masterRecord=[truth objectForKey:root];
  NSArray *before=[[base objectForKey:root] objectForKey:@"detached events"] ?: [NSArray array];
  NSArray *after=[masterRecord objectForKey:@"detached events"] ?: [NSArray array];
  if ([[NSSet setWithArray:before] isEqual:[NSSet setWithArray:after]]) return resource;
  if ([[masterRecord objectForKey:@"calendar"] count]!=1) {
    RCErrorSet(error,1,"Detached edits require a unique parent calendar"); return nil;
  }
  NSData *raw=[resource objectForKey:@"body"];
  icalcomponent *calendar=RCICalendarParse([raw bytes],[raw length],error), *master=NULL,*event;
  if(!calendar) return nil;
  NSDictionary *result=nil;
  NSArray *sources=SourceEvents(raw,error);
  NSMutableDictionary *paths=[NSMutableDictionary dictionaryWithDictionary:[resource objectForKey:@"paths"]];
  NSMutableData *body=[NSMutableData data]; NSUInteger cursor=0;
  NSEnumerator *it=[sources objectEnumerator]; NSDictionary *source;
  if(!sources) goto done;
  for(event=icalcomponent_get_first_component(calendar,ICAL_VEVENT_COMPONENT);event;
      event=icalcomponent_get_next_component(calendar,ICAL_VEVENT_COMPONENT))
    if(!icalcomponent_count_properties(event,ICAL_RECURRENCEID_PROPERTY)) master=event;
  if(!master || !icalcomponent_count_properties(master,ICAL_RRULE_PROPERTY)) {
    RCErrorSet(error,1,"Detached edits require an existing recurring master"); goto done;
  }
  while((source=[it nextObject])) {
    NSString *path=[source objectForKey:@"path"], *identifier=[paths objectForKey:path];
    if(!identifier || [identifier isEqual:root] || [after containsObject:identifier]) continue;
    if([truth objectForKey:identifier]) { RCErrorSet(error,1,"Detached event still exists outside its parent series"); goto done; }
    NSRange range=[[source objectForKey:@"range"] rangeValue];
    [body appendBytes:(const unsigned char *)[raw bytes]+cursor length:range.location-cursor];
    cursor=NSMaxRange(range);
    NSEnumerator *keys=[[[[paths allKeys] copy] autorelease] objectEnumerator]; NSString *key;
    while((key=[keys nextObject])) if([key isEqual:path] || [key hasPrefix:[path stringByAppendingString:@"/"]]) {
      if([truth objectForKey:[paths objectForKey:key]]) { RCErrorSet(error,1,"Deleted exception still owns native records"); goto done; }
      [paths removeObjectForKey:key];
    }
  }
  [body appendBytes:(const unsigned char *)[raw bytes]+cursor length:[raw length]-cursor];
  NSMutableData *additions=[NSMutableData data];
  it=[after objectEnumerator]; NSString *identifier;
  while((identifier=[it nextObject])) {
    NSDictionary *record=[truth objectForKey:identifier];
    if(![[record objectForKey:@"main event"] isEqual:[NSArray arrayWithObject:root]] ||
        ![[record objectForKey:@"calendar"] isEqual:[masterRecord objectForKey:@"calendar"]]) {
      RCErrorSet(error,1,"Detached event has an inconsistent parent or calendar"); goto done;
    }
    if([before containsObject:identifier]) continue;
    icalproperty *start=icalcomponent_get_first_property(master,ICAL_DTSTART_PROPERTY);
    BOOL allDay=icalproperty_get_dtstart(start).is_date;
    const char *tz=RCICalendarTZID(start);
    NSTimeZone *zone=tz ? [NSTimeZone timeZoneWithName:S(tz)] : nil;
    NSString *date=DateValue([record objectForKey:@"original date"],allDay,zone);
    if(!date || (tz && !zone)) { RCErrorSet(error,1,"Detached event has an invalid original date or timezone"); goto done; }
    NSString *line=[NSString stringWithFormat:@"RECURRENCE-ID%@:%@",allDay ? @";VALUE=DATE" : tz ? [@";TZID=" stringByAppendingString:S(tz)] : @"",date];
    icalproperty *rid=icalproperty_new_from_string([line UTF8String]);
    icalcomponent *clone=icalcomponent_new_clone(master);
    if(!rid || !clone) { if(rid) icalproperty_free(rid); if(clone) icalcomponent_free(clone); goto done; }
    icalproperty_kind remove[]={ICAL_RRULE_PROPERTY,ICAL_EXDATE_PROPERTY,ICAL_RDATE_PROPERTY,ICAL_EXRULE_PROPERTY}; int k;
    for(k=0;k<4;k++) { icalproperty *p; while((p=icalcomponent_get_first_property(clone,remove[k]))) { icalcomponent_remove_property(clone,p); icalproperty_free(p); } }
    icalcomponent_add_property(clone,rid);
    char *recurrence=RCICalendarRecurrenceKey(clone);
    NSString *path=[@"event:" stringByAppendingString:S(recurrence)]; free(recurrence);
    if([paths objectForKey:path]) { icalcomponent_free(clone); RCErrorSet(error,1,"Duplicate detached recurrence identity"); goto done; }
    [paths setObject:identifier forKey:path];
    for(k=0;k<5;k++) {
      NSArray *children=[record objectForKey:childLinks[k]]; NSUInteger n;
      for(n=0;n<[children count];n++) [paths setObject:[children objectAtIndex:n]
          forKey:[NSString stringWithFormat:@"%@/%@:%lu",path,childLinks[k],(unsigned long)n]];
    }
    char *encoded=icalcomponent_as_ical_string_r(clone); icalcomponent_free(clone);
    if(!encoded) goto done;
    [additions appendBytes:encoded length:strlen(encoded)]; free(encoded);
  }
  /* Locate the final root END without changing line endings or folded values. */
  if([additions length]) {
    const unsigned char *bytes=[body bytes]; NSUInteger pos=0,end=NSNotFound;
    while(pos<[body length]) {
      NSUInteger begin=pos; while(pos<[body length] && bytes[pos]!='\r' && bytes[pos]!='\n') pos++;
      if(pos-begin==13 && !strncasecmp((const char *)bytes+begin,"END:VCALENDAR",13)) end=begin;
      if(pos<[body length] && bytes[pos]=='\r') pos++;
      if(pos<[body length] && bytes[pos]=='\n') pos++;
    }
    if(end==NSNotFound) goto done;
    [body replaceBytesInRange:NSMakeRange(end,0) withBytes:[additions bytes] length:[additions length]];
  }
  {
    RCWriteJournal journal=RCCalendarStoreWriteJournal(store);
    if(!RCTwoWaySQL(&journal,error,"SAVEPOINT prepare_exceptions")) goto done;
    NSDictionary *mapped=RCCalendarNativeGraph(store,-1,[[masterRecord objectForKey:@"calendar"] objectAtIndex:0],body,error);
    NSString *unused=nil;
    NSDictionary *generated=mapped ? Paths(store,-1,body,mapped,&unused,error) : nil;
    NSMutableDictionary *aliases=[NSMutableDictionary dictionary];
    NSEnumerator *keys=[generated keyEnumerator]; NSString *key;
    while((key=[keys nextObject])) if([paths objectForKey:key]) [aliases setObject:[paths objectForKey:key] forKey:[generated objectForKey:key]];
    NSMutableDictionary *graph=generated ? [NSMutableDictionary dictionaryWithDictionary:RCTwoWayRemap(mapped,aliases)] : nil;
    BOOL rolledBack=RCTwoWaySQL(&journal,NULL,"ROLLBACK TO prepare_exceptions;RELEASE prepare_exceptions");
    if(!graph || !rolledBack) goto done;
    /* Preserve the original comparison baseline for existing records. */
    keys=[base keyEnumerator];
    while((key=[keys nextObject])) if([graph objectForKey:key]) [graph setObject:[base objectForKey:key] forKey:key];
    NSMutableDictionary *masterBase=[NSMutableDictionary dictionaryWithDictionary:[graph objectForKey:root]];
    [masterBase setObject:after forKey:@"detached events"]; [graph setObject:masterBase forKey:root];
    NSMutableDictionary *prepared=[NSMutableDictionary dictionaryWithDictionary:resource];
    [prepared setObject:body forKey:@"body"]; [prepared setObject:paths forKey:@"paths"]; [prepared setObject:graph forKey:@"graph"];
    result=prepared;
  }
done:
  icalcomponent_free(calendar);
  if(!result && (!error || !error->code)) RCErrorSet(error,1,"Could not encode detached recurrence changes");
  return result;
}
NSMutableDictionary *RCCalendarEncodeLocal(void *opaque,NSDictionary *resource,NSDictionary *truth,NSString *root,RCError *error)
{
  if (!resource) return Create(opaque,truth,root,error);
  resource=PrepareExceptions(opaque,resource,truth,root,error);
  if (!resource) return nil;
  resource=PrepareStructure(resource,truth,error);
  if(!resource) return nil;
  NSData *raw=[resource objectForKey:@"body"];
  icalcomponent *calendar=RCICalendarParse([raw bytes],[raw length],error), *event;
  if (!calendar) return nil;
  NSMutableArray *edits=[NSMutableArray array];
  NSDictionary *baseGraph=[resource objectForKey:@"graph"];
  NSArray *sourceEvents=SourceEvents(raw,error);
  if (!sourceEvents) goto failed;
  for(event=icalcomponent_get_first_component(calendar,ICAL_ANY_COMPONENT);event;
      event=icalcomponent_get_next_component(calendar,ICAL_ANY_COMPONENT)) {
    if (icalcomponent_isa(event)!=ICAL_VEVENT_COMPONENT) continue;
    NSDictionary *source=SourceEvent(sourceEvents,event);
    if (!source) { RCErrorSet(error,1,"Event source identity was not found"); goto failed; }
    int component=[[source objectForKey:@"component"] intValue];
    char *recurrence=RCICalendarRecurrenceKey(event);
    NSString *path=[@"event:" stringByAppendingString:S(recurrence)]; free(recurrence);
    NSString *identifier=[[resource objectForKey:@"paths"] objectForKey:path];
    if (!identifier) continue;
    NSDictionary *base=[baseGraph objectForKey:identifier], *record=[truth objectForKey:identifier];
    if (!record) { RCErrorSet(error,1,"Event component %d is missing from native truth",component); goto failed; }
    NSMutableDictionary *expected=[NSMutableDictionary dictionaryWithDictionary:base];
    NSString *keys[]={@"summary",@"description",@"location",@"url",@"status",@"classification",@"start date",@"end date"};
    NSString *names[]={@"SUMMARY",@"DESCRIPTION",@"LOCATION",@"URL",@"STATUS",@"CLASS",@"DTSTART",@"DTEND"};
    int k;
    for(k=0;k<8;k++) {
      id old=[base objectForKey:keys[k]], value=[record objectForKey:keys[k]];
      if (RCNativePropertyValuesEqual(eventEntity,keys[k],old,value)) continue;
      /* Remove cleared optional properties. libical rejects empty text values;
         an omitted SUMMARY uses the forward mapper's existing title default. */
      NSString *encoded=RCNativeEmptyValue(value) ? nil : RCTwoWayEscape(value);
      if (k==4) encoded=RCNativeEmptyValue(value) || [value isEqual:@"none"] ? nil : [value uppercaseString];
      if (k==5) encoded=RCNativeEmptyValue(value) ? nil : [value uppercaseString];
      if (k>=6) {
        BOOL allDay=[[base objectForKey:@"all day"] boolValue];
        icalproperty *p=icalcomponent_get_first_property(event,k==6 ? ICAL_DTSTART_PROPERTY : ICAL_DTEND_PROPERTY);
        const char *tz=RCICalendarTZID(p); NSTimeZone *zone=tz ? [NSTimeZone timeZoneWithName:S(tz)] : nil;
        if ((tz && !zone) || (!p && allDay) || icalcomponent_count_properties(event,ICAL_DURATION_PROPERTY)) {
          RCErrorSet(error,1,"Event component %d field '%s': %s",component,[keys[k] UTF8String],
              tz && !zone ? "timezone is unavailable" : !p && allDay ? "missing all-day date property" : "DURATION-based date edits are not supported");
          goto failed;
        }
        encoded=DateValue(value,allDay,zone);
        if (!encoded) { RCErrorSet(error,1,"Event component %d field '%s' has an invalid date",component,[keys[k] UTF8String]); goto failed; }
      }
      if (!AddEdit(event,component,names[k],encoded,edits,error)) goto failed;
      if (value) [expected setObject:value forKey:keys[k]]; else [expected removeObjectForKey:keys[k]];
    }
    NSArray *oldExceptions=[base objectForKey:@"exception dates"] ?: [NSArray array];
    NSArray *exceptions=[record objectForKey:@"exception dates"] ?: [NSArray array];
    if (![RCNativeUnorderedValues(oldExceptions) isEqual:RCNativeUnorderedValues(exceptions)]) {
      /* Cancelled detached components also contribute exception dates. Keep
         those protected until a mapper can explicitly edit their STATUS. */
      if ((NSUInteger)icalcomponent_count_properties(event,ICAL_EXDATE_PROPERTY)!=[oldExceptions count]) {
        RCErrorSet(error,1,"Exception dates include retained cancellations or compound EXDATE values"); goto failed;
      }
      NSUInteger n;
      for(n=0;n<[oldExceptions count];n++) [edits addObject:[NSDictionary dictionaryWithObjectsAndKeys:
          @"EXDATE",@"name",[NSNumber numberWithInt:component],@"component",[NSNumber numberWithUnsignedInt:n],@"occurrence",[NSNull null],@"value",nil]];
      BOOL allDay=[[base objectForKey:@"all day"] boolValue];
      for(n=0;n<[exceptions count];n++) {
        NSString *date=DateValue([exceptions objectAtIndex:n],allDay,nil);
        if(!date) { RCErrorSet(error,1,"Invalid exception date"); goto failed; }
        [edits addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"EXDATE",@"name",
            [NSNumber numberWithInt:component],@"component",[NSNumber numberWithInt:-1],@"occurrence",date,@"value",
            allDay ? @"VALUE=DATE" : @"",@"parameters",nil]];
      }
      [expected setObject:exceptions forKey:@"exception dates"];
    }
    if (!RCTwoWayRecordsEqual(expected,record)) {
      RCErrorSet(error,1,"Event component %d field '%s' changed beyond the reverse mapper",component,[DifferentField(expected,record) UTF8String]); goto failed;
    }
    if (!AudioEdits(event,component,base,baseGraph,truth,edits,error)) goto failed;
    for(k=0;k<5;k++) {
      if(k==2) continue; /* AudioEdits checked every mapped sound record. */
      NSEnumerator *it=[[base objectForKey:childLinks[k]] objectEnumerator]; NSString *id;
      while ((id=[it nextObject])) if (!RCTwoWayRecordsEqual([baseGraph objectForKey:id],[truth objectForKey:id])) {
        RCErrorSet(error,1,"Event component %d child '%s' field '%s' changed beyond the reverse mapper",component,
            [childLinks[k] UTF8String],[DifferentField([baseGraph objectForKey:id],[truth objectForKey:id]) UTF8String]); goto failed;
      }
    }
  }
  {
    RCResourceEdit *patch=calloc([edits count] ?: 1,sizeof(*patch)); NSUInteger n;
    unsigned char *bytes=NULL; size_t length=0;
    if (!patch) goto failed;
    for(n=0;n<[edits count];n++) {
      NSDictionary *edit=[edits objectAtIndex:n];
      patch[n].component=[[edit objectForKey:@"component"] intValue];
      patch[n].property=[[edit objectForKey:@"name"] UTF8String];
      patch[n].occurrence=[[edit objectForKey:@"occurrence"] intValue];
      patch[n].value=[edit objectForKey:@"value"]==[NSNull null] ? NULL : [[edit objectForKey:@"value"] UTF8String];
      if ([[edit objectForKey:@"parameters"] length]) patch[n].parameters=[[edit objectForKey:@"parameters"] UTF8String];
    }
    BOOL ok=RCResourcePatch(RCResourceCalendar,[raw bytes],[raw length],patch,[edits count],&bytes,&length,error);
    free(patch);
    if (ok) {
      NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:resource];
      [result setObject:[NSData dataWithBytes:bytes length:length] forKey:@"body"];
      [result setObject:RCTwoWaySubgraph(truth,[[resource objectForKey:@"paths"] allValues]) forKey:@"graph"];
      free(bytes); icalcomponent_free(calendar);
      return Validate(opaque,[result objectForKey:@"body"],[result objectForKey:@"paths"],truth,root,error) ? result : nil;
    }
    free(bytes);
  }
  goto failed;
failed:
  icalcomponent_free(calendar); return nil;
}
int RCSyncServicesTwoWayCalendars(RCCalendarStore *store,const char *description,long *count,RCError *error)
{
  RCWriteJournal j=RCCalendarStoreWriteJournal(store); sqlite3_stmt *q=NULL;
  NSMutableDictionary *graph=[NSMutableDictionary dictionary], *calendarIDs=[NSMutableDictionary dictionary];
  NSMutableArray *resources=[NSMutableArray array];
  NSString *accountID=nil; long long generation=0; int step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j.db,"SELECT sync_id,generation FROM accounts WHERE id=?",-1,&q,NULL)!=SQLITE_OK) goto failed;
  sqlite3_bind_int64(q,1,j.account);
  if (sqlite3_step(q)==SQLITE_ROW) { accountID=S((const char *)sqlite3_column_text(q,0)); generation=sqlite3_column_int64(q,1); }
  sqlite3_finalize(q); q=NULL;
  if (!generation || !accountID) goto failed;
  if (sqlite3_prepare_v2(j.db,"SELECT id,sync_id,display_name,description FROM calendars WHERE account_id=? AND remote_missing=0",-1,&q,NULL)!=SQLITE_OK) goto failed;
  sqlite3_bind_int64(q,1,j.account);
  while ((step=sqlite3_step(q))==SQLITE_ROW) {
    if(RCCheckCancellation(error)) goto failed;
    NSString *id=[@"calendar-" stringByAppendingString:S((const char *)sqlite3_column_text(q,1))];
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Calendar",ISyncRecordEntityNameKey,
        RCCalendarNativeTitle(j,id,S((const char *)sqlite3_column_text(q,2))),@"title",
        [NSNumber numberWithBool:NO],@"read only",[NSMutableArray array],@"events",[NSArray array],@"tasks",nil];
    if (sqlite3_column_type(q,3)!=SQLITE_NULL) [record setObject:S((const char *)sqlite3_column_text(q,3)) forKey:@"notes"];
    [graph setObject:record forKey:id]; [calendarIDs setObject:id forKey:[NSNumber numberWithLongLong:sqlite3_column_int64(q,0)]];
  }
  if (step!=SQLITE_DONE) goto failed;
  sqlite3_finalize(q); q=NULL;
  if (sqlite3_prepare_v2(j.db,"SELECT r.id,r.calendar_id,r.href,r.raw_ical,r.etag,r.export_ical,r.export_etag,r.parse_error "
      "FROM calendar_resources r JOIN calendars c ON c.id=r.calendar_id WHERE c.account_id=? AND c.remote_missing=0 "
      "AND r.remote_missing=0 AND r.scope_excluded=0",-1,&q,NULL)!=SQLITE_OK) goto failed;
  sqlite3_bind_int64(q,1,j.account);
  while ((step=sqlite3_step(q))==SQLITE_ROW) {
    if(RCCheckCancellation(error)) goto failed;
    long long id=sqlite3_column_int64(q,0); NSString *calendar=[calendarIDs objectForKey:[NSNumber numberWithLongLong:sqlite3_column_int64(q,1)]];
    NSData *body=[NSData dataWithBytes:sqlite3_column_blob(q,3) length:sqlite3_column_bytes(q,3)];
    NSString *etag=S((const char *)sqlite3_column_text(q,4)); RCError mappingError; RCErrorClear(&mappingError);
    NSDictionary *mapped=sqlite3_column_type(q,7)==SQLITE_NULL ? RCCalendarNativeGraph(store,id,calendar,body,&mappingError) : nil;
    if (!mapped && sqlite3_column_type(q,5)!=SQLITE_NULL) {
      body=[NSData dataWithBytes:sqlite3_column_blob(q,5) length:sqlite3_column_bytes(q,5)]; etag=S((const char *)sqlite3_column_text(q,6));
      mapped=RCCalendarNativeGraph(store,id,calendar,body,&mappingError);
      if (!mapped) { RCErrorSet(error,1,"Could not reconstruct retained calendar graph"); goto failed; }
    }
    if (!mapped) { RCLogger(RCLogWarning, "Calendars", "Apply", @"Two-way calendar resource %lld is unsupported: %s",id,sqlite3_column_type(q,7)!=SQLITE_NULL ? (const char *)sqlite3_column_text(q,7) : mappingError.message); continue; }
    NSString *root=nil; NSDictionary *paths=Paths(store,id,body,mapped,&root,error);
    if (!paths || !root) goto failed;
    [resources addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"resource-%lld",id],@"key",root,@"root",
        S((const char *)sqlite3_column_text(q,2)),@"href",etag,@"etag",body,@"body",mapped,@"graph",paths,@"paths",
        [NSNumber numberWithLongLong:generation],@"revision",nil]];
    [graph addEntriesFromDictionary:mapped]; NSEnumerator *it=[mapped keyEnumerator]; NSString *key;
    while ((key=[it nextObject])) if ([[[mapped objectForKey:key] objectForKey:ISyncRecordEntityNameKey] isEqual:eventEntity])
      [[[graph objectForKey:calendar] objectForKey:@"events"] addObject:key];
  }
  if (step!=SQLITE_DONE) goto failed;
  sqlite3_finalize(q); q=NULL;
  RCTwoWayContext c={j,RCCalendarSyncClientIdentifier(accountID),S(description),eventEntity,resources,graph,RCCalendarEncodeLocal,store,NO,RCCalendarProjectVerified,NO};
  if (!RCTwoWayExchange(&c,error)) return 0;
  if (c.didPublishAll) {
    if (!RCTwoWaySQL(&j,error,"BEGIN IMMEDIATE")) return 0;
    NSEnumerator *it=[resources objectEnumerator]; NSDictionary *r;
    while ((r=[it nextObject])) {
      sqlite3_stmt *update=NULL;
      BOOL ok=sqlite3_prepare_v2(j.db,"UPDATE calendar_resources SET export_ical=?,export_etag=?,export_status='exported',export_error=NULL "
          "WHERE href=? AND calendar_id IN(SELECT id FROM calendars WHERE account_id=?)",-1,&update,NULL)==SQLITE_OK;
      if (ok) {
        NSData *body=[r objectForKey:@"body"];
        sqlite3_bind_blob(update,1,[body bytes],(int)[body length],SQLITE_TRANSIENT);
        sqlite3_bind_text(update,2,[[r objectForKey:@"etag"] UTF8String],-1,SQLITE_TRANSIENT);
        sqlite3_bind_text(update,3,[[r objectForKey:@"href"] UTF8String],-1,SQLITE_TRANSIENT);
        sqlite3_bind_int64(update,4,j.account); ok=sqlite3_step(update)==SQLITE_DONE;
      }
      sqlite3_finalize(update);
      if (!ok) { RCTwoWaySQL(&j,NULL,"ROLLBACK"); RCErrorSet(error,1,"Could not checkpoint two-way calendar publication"); return 0; }
    }
    if (!RCCalendarStoreSnapshotWriteBases(store,generation,error) ||
        !RCTwoWaySQL(&j,error,"UPDATE accounts SET published_generation=%lld WHERE id=%lld;COMMIT",generation,j.account)) {
      RCTwoWaySQL(&j,NULL,"ROLLBACK"); return 0;
    }
  }
  if (count) *count=c.didPublishAll ? (long)[graph count] : -1;
  return 1;
failed:
  sqlite3_finalize(q); if (!error->code) RCErrorSet(error,1,"Could not build two-way calendar graph"); return 0;
}
