#import "RCTwoWayNative.h"
#import "RCCalendarSyncClient.h"
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
static int RCNativeComponentCount(icalcomponent *c)
{
  icalcomponent *child; int n=1;
  for(child=icalcomponent_get_first_component(c,ICAL_ANY_COMPONENT);child;
      child=icalcomponent_get_next_component(c,ICAL_ANY_COMPONENT)) n+=RCNativeComponentCount(child);
  return n;
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
  if (sqlite3_prepare_v2(j.db,"SELECT url FROM calendars WHERE account_id=? AND remote_missing=0 AND 'calendar-'||sync_id=?",-1,&q,NULL)==SQLITE_OK) {
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
static NSMutableDictionary *Create(RCCalendarStore *store,NSDictionary *truth,NSString *root,RCError *error)
{
  NSDictionary *record=[truth objectForKey:root]; NSArray *calendars=[record objectForKey:@"calendar"];
  if ([calendars count]!=1) { RCErrorSet(error,1,"New event has no unique calendar"); return nil; }
  NSString *collection=CalendarURL(store,[calendars objectAtIndex:0],error);
  if (!collection) return nil;
  /* Scheduling and recurrence structure need their own verified reverse mapper.
     Never silently create a simplified event from a richer native graph. */
  NSString *unsupported[]={@"main event",@"detached events",@"exception dates",@"recurrences",@"attendees",@"organizer",@"mail alarms"};
  int k; for(k=0;k<7;k++) if ([[record objectForKey:unsupported[k]] count]) {
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
  for(k=1;k<=2;k++) {
    NSArray *ids=[record objectForKey:childLinks[k]]; NSUInteger n;
    for(n=0;n<[ids count];n++) {
      NSString *id=[ids objectAtIndex:n]; NSDictionary *alarm=[truth objectForKey:id];
      if (!alarm || [alarm objectForKey:@"triggerdate"] || ![alarm objectForKey:@"triggerduration"] ||
          [alarm objectForKey:@"repeat count"] || [alarm objectForKey:@"repeat interval"]) {
        RCErrorSet(error,1,"New alarm requires a simple relative trigger"); return nil;
      }
      char *duration=icaldurationtype_as_ical_string_r(icaldurationtype_from_int([[alarm objectForKey:@"triggerduration"] intValue]));
      if (!duration) return nil;
      [body appendFormat:@"BEGIN:VALARM\r\nACTION:%@\r\nTRIGGER:%s\r\n",k==1 ? @"DISPLAY" : @"AUDIO",duration];
      free(duration);
      if ([alarm objectForKey:@"description"]) [body appendFormat:@"DESCRIPTION:%@\r\n",RCTwoWayEscape([alarm objectForKey:@"description"])];
      [body appendString:@"END:VALARM\r\n"];
      [paths setObject:id forKey:[NSString stringWithFormat:@"event:/%@:%lu",childLinks[k],(unsigned long)n]];
    }
  }
  [body appendString:@"END:VEVENT\r\nEND:VCALENDAR\r\n"];
  NSData *data=[body dataUsingEncoding:NSUTF8StringEncoding];
  icalcomponent *check=RCICalendarParse([data bytes],[data length],error);
  if (!check) return nil;
  icalcomponent_free(check);
  if (!Validate(store,data,paths,truth,root,error)) return nil;
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
NSMutableDictionary *RCCalendarEncodeLocal(void *opaque,NSDictionary *resource,NSDictionary *truth,NSString *root,RCError *error)
{
  if (!resource) return Create(opaque,truth,root,error);
  NSData *raw=[resource objectForKey:@"body"];
  icalcomponent *calendar=RCICalendarParse([raw bytes],[raw length],error), *event;
  if (!calendar) return nil;
  NSMutableArray *edits=[NSMutableArray array];
  NSDictionary *baseGraph=[resource objectForKey:@"graph"];
  int component=1;
  for(event=icalcomponent_get_first_component(calendar,ICAL_ANY_COMPONENT);event;
      component+=RCNativeComponentCount(event),event=icalcomponent_get_next_component(calendar,ICAL_ANY_COMPONENT)) {
    if (icalcomponent_isa(event)!=ICAL_VEVENT_COMPONENT) continue;
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
      if ((old==nil && value==nil) || [old isEqual:value]) continue;
      NSString *encoded=value ? RCTwoWayEscape(value) : nil;
      if (k==4) encoded=[value isEqual:@"none"] ? nil : [value uppercaseString];
      if (k==5) encoded=[value uppercaseString];
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
    if (!RCTwoWayRecordsEqual(expected,record)) {
      RCErrorSet(error,1,"Event component %d field '%s' changed beyond the reverse mapper",component,[DifferentField(expected,record) UTF8String]); goto failed;
    }
    for(k=0;k<5;k++) {
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
    NSString *id=[@"calendar-" stringByAppendingString:S((const char *)sqlite3_column_text(q,1))];
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithObjectsAndKeys:@"com.apple.calendars.Calendar",ISyncRecordEntityNameKey,
        [NSString stringWithFormat:@"%@ (iCloud %@)",S((const char *)sqlite3_column_text(q,2)),[id substringFromIndex:[id length]-6]],@"title",
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
    long long id=sqlite3_column_int64(q,0); NSString *calendar=[calendarIDs objectForKey:[NSNumber numberWithLongLong:sqlite3_column_int64(q,1)]];
    NSData *body=[NSData dataWithBytes:sqlite3_column_blob(q,3) length:sqlite3_column_bytes(q,3)];
    NSString *etag=S((const char *)sqlite3_column_text(q,4)); RCError mappingError; RCErrorClear(&mappingError);
    NSDictionary *mapped=sqlite3_column_type(q,7)==SQLITE_NULL ? RCCalendarNativeGraph(store,id,calendar,body,&mappingError) : nil;
    if (!mapped && sqlite3_column_type(q,5)!=SQLITE_NULL) {
      body=[NSData dataWithBytes:sqlite3_column_blob(q,5) length:sqlite3_column_bytes(q,5)]; etag=S((const char *)sqlite3_column_text(q,6));
      mapped=RCCalendarNativeGraph(store,id,calendar,body,&mappingError);
      if (!mapped) { RCErrorSet(error,1,"Could not reconstruct retained calendar graph"); goto failed; }
    }
    if (!mapped) { NSLog(@"Two-way calendar resource %lld is unsupported: %s",id,sqlite3_column_type(q,7)!=SQLITE_NULL ? (const char *)sqlite3_column_text(q,7) : mappingError.message); continue; }
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
