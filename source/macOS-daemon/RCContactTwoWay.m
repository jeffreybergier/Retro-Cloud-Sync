#import "RCTwoWayNative.h"
#import "RCContactSyncClient.h"
#import "RCSyncRecordEquality.h"
#include "RCResourcePatch.h"
#include <string.h>
#include <stdlib.h>

static NSString *relations[]={@"phone numbers",@"email addresses",@"street addresses",@"URLs"};
static NSString *properties[]={@"TEL",@"EMAIL",@"ADR",@"URL"};
static NSString *primaryKeys[]={@"primary phone number",@"primary email address",@"primary street address",@"primary URL"};
static NSString *entity=@"com.apple.contacts.Contact";
static NSString *S(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }
static BOOL Changed(NSDictionary *a,NSDictionary *b,NSString *key)
{
  id x=[a objectForKey:key], y=[b objectForKey:key];
  NSString *kind=[a objectForKey:ISyncRecordEntityNameKey];
  if (![kind isEqual:[b objectForKey:ISyncRecordEntityNameKey]]) kind=nil;
  return !RCNativePropertyValuesEqual(kind,key,x,y);
}
static NSString *Structured(NSDictionary *record, NSArray *keys)
{
  NSMutableArray *parts=[NSMutableArray array];
  NSEnumerator *it=[keys objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) [parts addObject:RCTwoWayEscape([record objectForKey:key])];
  return [parts componentsJoinedByString:@";"];
}
/* Replace only edited structured components. Keep invisible extra components,
   comma-separated alternatives and original escaping in every untouched part. */
static NSString *StructuredEdit(RCVCardDocument *doc, NSString *name, int occurrence,
    NSArray *keys, NSDictionary *base, NSDictionary *record, BOOL address)
{
  NSString *original=@""; size_t p; int n=0;
  for(p=0;p<doc->propertyCount;p++) if (!strcasecmp(doc->properties[p].name,[name UTF8String]) && n++==occurrence)
    original=S(doc->properties[p].originalValue);
  NSMutableArray *parts=[NSMutableArray array]; NSUInteger start=0,i; BOOL escaped=NO;
  for(i=0;i<[original length];i++) {
    unichar c=[original characterAtIndex:i];
    if (!escaped && c==';') { [parts addObject:[original substringWithRange:NSMakeRange(start,i-start)]]; start=i+1; }
    if (!escaped && c=='\\') escaped=YES; else escaped=NO;
  }
  [parts addObject:[original substringFromIndex:start]];
  while ([parts count]<[keys count]) [parts addObject:@""];
  for(i=0;i<[keys count];i++) {
    NSString *key=[keys objectAtIndex:i];
    if ([key length] && Changed(base,record,key)) [parts replaceObjectAtIndex:i withObject:RCTwoWayEscape([record objectForKey:key])];
  }
  if (address && Changed(base,record,@"street")) { [parts replaceObjectAtIndex:0 withObject:@""]; [parts replaceObjectAtIndex:1 withObject:@""]; }
  return [parts componentsJoinedByString:@";"];
}
NSDictionary *RCContactNativePaths(NSData *body, NSDictionary *graph, NSString *root, RCError *error)
{
  RCVCardDocument doc;
  if (!RCVCardParse([body bytes],[body length],&doc,error)) return nil;
  NSMutableDictionary *paths=[NSMutableDictionary dictionaryWithObject:root forKey:@"root"];
  NSDictionary *contact=[graph objectForKey:root]; int k;
  for (k=0;k<4;k++) {
    NSArray *ids=[contact objectForKey:relations[k]]; NSUInteger n=0; size_t p; int occurrence=0;
    for (p=0;p<doc.propertyCount;p++) if (!strcasecmp(doc.properties[p].name,[properties[k] UTF8String])) {
      NSString *value=S(doc.properties[p].decodedValue);
      BOOL visible=k==2 || ([value length] && (k!=3 || [NSURL URLWithString:value]));
      if (visible) {
        if (n>=[ids count]) { RCVCardDocumentClear(&doc); RCErrorSet(error,1,"Contact paths do not match the native graph"); return nil; }
        [paths setObject:[ids objectAtIndex:n++] forKey:[NSString stringWithFormat:@"%@:%d",properties[k],occurrence]];
      }
      occurrence++;
    }
    if (n!=[ids count]) { RCVCardDocumentClear(&doc); RCErrorSet(error,1,"Contact paths do not match the native graph"); return nil; }
  }
  RCVCardDocumentClear(&doc); return paths;
}
NSDictionary *RCContactProjectVerified(void *opaque,NSDictionary *current,NSData *body,RCError *error)
{
  (void)opaque;
  RCVCardDocument old,new;
  RCVCardDocumentInit(&old); RCVCardDocumentInit(&new);
  NSData *latest=[current objectForKey:@"body"];
  BOOL valid=RCVCardParse([body bytes],[body length],&old,error) &&
      RCVCardParse([latest bytes],[latest length],&new,error);
  size_t i; int oldUIDs=0,newUIDs=0;
  for(i=0;i<old.propertyCount;i++) if (!strcasecmp(old.properties[i].name,"UID")) oldUIDs++;
  for(i=0;i<new.propertyCount;i++) if (!strcasecmp(new.properties[i].name,"UID")) newUIDs++;
  valid=valid && oldUIDs==1 && newUIDs==1 && old.uid && old.uid[0] && new.uid && !strcmp(old.uid,new.uid);
  RCVCardDocumentClear(&old); RCVCardDocumentClear(&new);
  if (!valid) return nil;
  NSString *root=[current objectForKey:@"root"];
  NSDictionary *mapped=RCContactNativeGraphForPaths(body,[current objectForKey:@"paths"],error);
  if (!mapped || !root) return nil;
  mapped=RCTwoWayRemap(mapped,[NSDictionary dictionaryWithObject:root forKey:@"contact-validation"]);
  /* Root-field edits (such as a newer note) preserve the contact identity.
     Child paths are positional: do not alias a changed/reordered child graph
     using an older receipt. A richer child-identity mapper is needed there. */
  NSMutableDictionary *oldChildren=[NSMutableDictionary dictionaryWithDictionary:mapped];
  NSMutableDictionary *newChildren=[NSMutableDictionary dictionaryWithDictionary:[current objectForKey:@"graph"]];
  [oldChildren removeObjectForKey:root]; [newChildren removeObjectForKey:root];
  if (!RCTwoWayGraphsEqual(oldChildren,newChildren)) return nil;
  NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:current];
  [result setObject:body forKey:@"body"]; [result setObject:mapped forKey:@"graph"];
  return result;
}
static BOOL AddEdit(RCVCardDocument *doc, NSString *name, int wanted,
                    NSString *value, NSMutableArray *edits, RCError *error)
{
  size_t i; int occurrence=0; RCVCardProperty *p=NULL;
  for(i=0;i<doc->propertyCount;i++) if (!strcasecmp(doc->properties[i].name,[name UTF8String])) {
    if (occurrence++==wanted) p=&doc->properties[i];
  }
  if (wanted==0 && occurrence>1 && ![properties[0] isEqual:name] && ![properties[1] isEqual:name] &&
      ![properties[2] isEqual:name] && ![properties[3] isEqual:name]) {
    RCErrorSet(error,1,"Ambiguous repeated contact property"); return NO;
  }
  if (!p && !value) return YES;
  if (p && value) for(i=0;i<p->parameterCount;i++) {
    const RCVCardParameter *parameter=&p->parameters[i];
    if (!strcasecmp(parameter->name,"ENCODING") ||
        (!strcasecmp(parameter->name,"CHARSET") && strcasecmp(parameter->value,"UTF-8"))) {
      RCErrorSet(error,1,"Legacy encoded contact field requires an encoding-aware editor"); return NO;
    }
  }
  int grouped=0;
  if (p) for(i=0;&doc->properties[i]!=p;i++) if (!strcasecmp(doc->properties[i].name,p->name) &&
      ((!p->group && !doc->properties[i].group) || (p->group && doc->properties[i].group && !strcmp(p->group,doc->properties[i].group)))) grouped++;
  [edits addObject:[NSDictionary dictionaryWithObjectsAndKeys:name,@"name",p ? S(p->group) : @"",@"group",
      [NSNumber numberWithInt:p ? grouped : -1],@"occurrence",value ?: (id)[NSNull null],@"value",nil]];
  return YES;
}
static NSString *NewType(NSDictionary *child, BOOL preferred)
{
  NSDictionary *types=[NSDictionary dictionaryWithObjectsAndKeys:@"HOME",@"home",@"WORK",@"work",@"CELL",@"mobile",
      @"PAGER",@"pager",@"HOME,FAX",@"home fax",@"WORK,FAX",@"work fax",@"",@"other",@"",@"home page",nil];
  id labelType=[child objectForKey:@"type"];
  NSString *type=[types objectForKey:RCNativeEmptyValue(labelType) ? @"other" : labelType];
  if (!type) return nil;
  if (preferred) type=[type length] ? [type stringByAppendingString:@",PREF"] : @"PREF";
  return [type length] ? [@"TYPE=" stringByAppendingString:type] : @"";
}
static NSString *NewLabel(NSDictionary *child)
{
  if ([[child objectForKey:@"type"] isEqual:@"home page"] &&
      [[child objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.contacts.URL"])
    return @"_$!<HomePage>!$_";
  return [child objectForKey:@"label"];
}
static void AppendProperty(NSMutableArray *edits,NSString *name,NSString *group,NSString *value,NSString *parameters)
{
  [edits addObject:[NSDictionary dictionaryWithObjectsAndKeys:name,@"name",group,@"group",value,@"value",
      [NSNumber numberWithInt:-1],@"occurrence",parameters ?: @"",@"parameters",nil]];
}
static NSString *Birthday(id date)
{
  return [date isKindOfClass:[NSDate class]] ? [date descriptionWithCalendarFormat:@"%Y-%m-%d"
      timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0] locale:nil] : nil;
}
static BOOL Validate(NSData *body, NSDictionary *paths, NSDictionary *truth, RCError *error)
{
  NSDictionary *mapped=RCContactNativeGraphForPaths(body,paths,error);
  if (!mapped) return NO;
  mapped=RCTwoWayRemap(mapped,[NSDictionary dictionaryWithObject:[paths objectForKey:@"root"] forKey:@"contact-validation"]);
  if (!RCTwoWayGraphsEqual(mapped,RCTwoWaySubgraph(truth,[paths allValues]))) {
    RCErrorSet(error,1,"Contact edit cannot round-trip through the native schema without loss"); return NO;
  }
  return YES;
}
static NSMutableDictionary *Create(RCContactStore *store,NSDictionary *truth,NSString *root,RCError *error)
{
  RCWriteJournal j=RCContactStoreWriteJournal(store);
  sqlite3_stmt *q=NULL; NSString *collection=nil; int count=0,step=SQLITE_ERROR;
  if (sqlite3_prepare_v2(j.db,"SELECT url FROM collections WHERE account_id=? AND remote_missing=0",-1,&q,NULL)==SQLITE_OK) {
    sqlite3_bind_int64(q,1,j.account);
    while ((step=sqlite3_step(q))==SQLITE_ROW) { collection=S((const char *)sqlite3_column_text(q,0)); count++; }
  }
  sqlite3_finalize(q);
  if (step!=SQLITE_DONE || count!=1) { RCErrorSet(error,1,"New contacts require one unambiguous address book"); return nil; }
  NSDictionary *record=[truth objectForKey:root];
  NSString *uid=RCTwoWayNewIdentifier();
  if (!uid) { RCErrorSet(error,1,"Could not allocate remote resource identity"); return nil; }
  NSString *href=[NSString stringWithFormat:@"%@%@%@.vcf",collection,[collection hasSuffix:@"/"] ? @"" : @"/",uid];
  NSMutableString *body=[NSMutableString stringWithFormat:@"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:%@\r\n",uid];
  [body appendFormat:@"N:%@\r\n",Structured(record,[NSArray arrayWithObjects:@"last name",@"first name",@"middle name",@"title",@"suffix",nil])];
  NSString *fn=[[NSArray arrayWithObjects:RCTwoWayString([record objectForKey:@"first name"]),
      RCTwoWayString([record objectForKey:@"last name"]),nil] componentsJoinedByString:@" "];
  if (![[fn stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length]) fn=RCTwoWayString([record objectForKey:@"company name"]);
  [body appendFormat:@"FN:%@\r\nORG:%@\r\n",RCTwoWayEscape(fn),Structured(record,[NSArray arrayWithObjects:@"company name",@"department",nil])];
  NSString *keys[]={@"notes",@"job title",@"nickname"}, *names[]={@"NOTE",@"TITLE",@"NICKNAME"}; int k;
  for(k=0;k<3;k++) if ([[record objectForKey:keys[k]] length]) [body appendFormat:@"%@:%@\r\n",names[k],RCTwoWayEscape([record objectForKey:keys[k]])];
  if (!RCNativeEmptyValue([record objectForKey:@"birthday"])) [body appendFormat:@"BDAY:%@\r\n",Birthday([record objectForKey:@"birthday"])];
  if ([[record objectForKey:@"display as company"] isEqual:@"company"]) [body appendString:@"X-ABShowAs:COMPANY\r\n"];
  NSMutableDictionary *paths=[NSMutableDictionary dictionaryWithObject:root forKey:@"root"];
  for(k=0;k<4;k++) {
    NSEnumerator *ids=[[record objectForKey:relations[k]] objectEnumerator]; NSString *identifier; int n=0;
    while ((identifier=[ids nextObject])) {
      NSDictionary *child=[truth objectForKey:identifier];
      if (!child) { RCErrorSet(error,1,"New contact has an incomplete child graph"); return nil; }
      NSString *type=[child objectForKey:@"type"];
      if (RCNativeEmptyValue(type)) type=@"other";
      NSDictionary *types=[NSDictionary dictionaryWithObjectsAndKeys:@"HOME",@"home",@"WORK",@"work",@"CELL",@"mobile",
          @"PAGER",@"pager",@"HOME,FAX",@"home fax",@"WORK,FAX",@"work fax",@"",@"other",@"",@"home page",nil];
      if (![types objectForKey:type]) { RCErrorSet(error,1,"Unsupported contact label type"); return nil; }
      NSString *param=[types objectForKey:type];
      if ([[record objectForKey:primaryKeys[k]] containsObject:identifier]) param=[param length] ? [param stringByAppendingString:@",PREF"] : @"PREF";
      NSString *group=[NSString stringWithFormat:@"item%d-%d",k,n];
      NSString *value=k==2 ? [@";;" stringByAppendingString:Structured(child,[NSArray arrayWithObjects:@"street",@"city",@"state",@"postal code",@"country",nil])] : RCTwoWayEscape([child objectForKey:@"value"]);
      [body appendFormat:@"%@.%@%@:%@\r\n",group,properties[k],[param length] ? [@";TYPE=" stringByAppendingString:param] : @"",value];
      if ([NewLabel(child) length]) [body appendFormat:@"%@.X-ABLabel:%@\r\n",group,RCTwoWayEscape(NewLabel(child))];
      if (k==2 && [[child objectForKey:@"country code"] length]) [body appendFormat:@"%@.X-ABADR:%@\r\n",group,RCTwoWayEscape([child objectForKey:@"country code"])];
      [paths setObject:identifier forKey:[NSString stringWithFormat:@"%@:%d",properties[k],n++]];
    }
  }
  [body appendString:@"END:VCARD\r\n"];
  NSData *data=[body dataUsingEncoding:NSUTF8StringEncoding]; RCVCardDocument doc;
  BOOL valid=RCVCardParse([data bytes],[data length],&doc,error); RCVCardDocumentClear(&doc);
  if (!valid || !Validate(data,paths,truth,error)) return nil;
  return [NSMutableDictionary dictionaryWithObjectsAndKeys:root,@"root",[@"native-" stringByAppendingString:uid],@"key",href,@"href",data,@"body",
      paths,@"paths",RCTwoWaySubgraph(truth,[paths allValues]),@"graph",nil];
}
NSMutableDictionary *RCContactEncodeLocal(void *opaque,NSDictionary *resource,NSDictionary *truth,NSString *root,RCError *error)
{
  if (!resource) return Create(opaque,truth,root,error);
  NSDictionary *baseGraph=[resource objectForKey:@"graph"], *base=[baseGraph objectForKey:root], *record=[truth objectForKey:root];
  NSMutableDictionary *expected=[NSMutableDictionary dictionaryWithDictionary:base];
  NSMutableArray *edits=[NSMutableArray array];
  NSData *raw=[resource objectForKey:@"body"];
  RCVCardDocument doc; BOOL ok=NO;
  if (!RCVCardParse([raw bytes],[raw length],&doc,error)) return nil;
  NSString *nameKeys[]={@"last name",@"first name",@"middle name",@"title",@"suffix"}; int k; BOOL nameChanged=NO;
  for(k=0;k<5;k++) if (Changed(base,record,nameKeys[k])) nameChanged=YES;
  if (nameChanged) {
    if (!AddEdit(&doc,@"N",0,StructuredEdit(&doc,@"N",0,[NSArray arrayWithObjects:nameKeys count:5],base,record,NO),edits,error)) goto done;
    NSString *fn=[[NSArray arrayWithObjects:RCTwoWayString([record objectForKey:@"first name"]),RCTwoWayString([record objectForKey:@"middle name"]),RCTwoWayString([record objectForKey:@"last name"]),nil] componentsJoinedByString:@" "];
    if (!AddEdit(&doc,@"FN",0,RCTwoWayEscape(fn),edits,error)) goto done;
  }
  if (Changed(base,record,@"company name") || Changed(base,record,@"department")) {
    if (!AddEdit(&doc,@"ORG",0,StructuredEdit(&doc,@"ORG",0,[NSArray arrayWithObjects:@"company name",@"department",nil],base,record,NO),edits,error)) goto done;
  }
  NSString *keys[]={@"notes",@"job title",@"nickname",@"birthday",@"display as company"};
  NSString *names[]={@"NOTE",@"TITLE",@"NICKNAME",@"BDAY",@"X-ABShowAs"};
  for(k=0;k<5;k++) if (Changed(base,record,keys[k])) {
    id v=[record objectForKey:keys[k]];
    NSString *value=k==3 ? Birthday(v) : k==4 ? ([v isEqual:@"company"] ? @"COMPANY" : nil) : v ? RCTwoWayEscape(v) : nil;
    if (!AddEdit(&doc,names[k],0,value,edits,error)) goto done;
  }
  NSArray *allowed=[NSArray arrayWithObjects:@"last name",@"first name",@"middle name",@"title",@"suffix",@"company name",@"department",@"notes",@"job title",@"nickname",@"birthday",@"display as company",nil];
  NSEnumerator *it=[allowed objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) { if ([record objectForKey:key]) [expected setObject:[record objectForKey:key] forKey:key]; else [expected removeObjectForKey:key]; }
  for(k=0;k<4;k++) {
    if ([record objectForKey:relations[k]]) [expected setObject:[record objectForKey:relations[k]] forKey:relations[k]];
    else [expected removeObjectForKey:relations[k]];
    if ([record objectForKey:primaryKeys[k]]) [expected setObject:[record objectForKey:primaryKeys[k]] forKey:primaryKeys[k]];
    else [expected removeObjectForKey:primaryKeys[k]];
  }
  if (!RCTwoWayRecordsEqual(expected,record)) goto unsupported;
  NSMutableDictionary *desiredPaths=[NSMutableDictionary dictionaryWithObject:root forKey:@"root"];
  for(k=0;k<4;k++) {
    NSArray *ids=[base objectForKey:relations[k]], *currentIDs=[record objectForKey:relations[k]];
    int n=0, outputIndex=0; size_t propertyIndex;
    for(propertyIndex=0;propertyIndex<doc.propertyCount;propertyIndex++) {
      if (strcasecmp(doc.properties[propertyIndex].name,[properties[k] UTF8String])) continue;
      int occurrence=n++;
      NSString *identifier=[[resource objectForKey:@"paths"] objectForKey:
          [NSString stringWithFormat:@"%@:%d",properties[k],occurrence]];
      /* Invisible raw fields still occupy positions and must survive edits. */
      if (!identifier) { outputIndex++; continue; }
      NSDictionary *old=[baseGraph objectForKey:identifier], *child=[truth objectForKey:identifier];
      if (![currentIDs containsObject:identifier]) {
        if (!AddEdit(&doc,properties[k],occurrence,nil,edits,error)) goto done;
        continue;
      }
      if (!child) goto unsupported;
      [desiredPaths setObject:identifier forKey:[NSString stringWithFormat:@"%@:%d",properties[k],outputIndex++]];
      NSMutableDictionary *check=[NSMutableDictionary dictionaryWithDictionary:old];
      NSArray *fields=k==2 ? [NSArray arrayWithObjects:@"street",@"city",@"state",@"postal code",@"country",nil] : [NSArray arrayWithObject:@"value"];
      it=[fields objectEnumerator]; BOOL changed=NO;
      while ((key=[it nextObject])) {
        if (Changed(old,child,key)) changed=YES;
        if ([child objectForKey:key]) [check setObject:[child objectForKey:key] forKey:key]; else [check removeObjectForKey:key];
      }
      if (!RCTwoWayRecordsEqual(check,child)) goto unsupported;
      if (changed) {
        NSString *value=k==2 ? StructuredEdit(&doc,@"ADR",occurrence,[NSArray arrayWithObjects:@"",@"",@"street",@"city",@"state",@"postal code",@"country",nil],old,child,YES) : RCTwoWayEscape([child objectForKey:@"value"]);
        if (!AddEdit(&doc,properties[k],occurrence,value,edits,error)) goto done;
      }
    }
    NSEnumerator *newIDs=[currentIDs objectEnumerator]; NSString *identifier;
    while ((identifier=[newIDs nextObject])) if (![ids containsObject:identifier]) {
      NSDictionary *child=[truth objectForKey:identifier];
      NSString *params=NewType(child,[[record objectForKey:primaryKeys[k]] containsObject:identifier]);
      if (!child || !params) goto unsupported;
      NSString *group=[@"rc-" stringByAppendingString:RCTwoWayNewIdentifier()];
      NSString *value=k==2 ? [@";;" stringByAppendingString:Structured(child,[NSArray arrayWithObjects:@"street",@"city",@"state",@"postal code",@"country",nil])] : RCTwoWayEscape([child objectForKey:@"value"]);
      AppendProperty(edits,properties[k],group,value,params);
      if ([NewLabel(child) length]) AppendProperty(edits,@"X-ABLabel",group,RCTwoWayEscape(NewLabel(child)),nil);
      if (k==2 && [[child objectForKey:@"country code"] length]) AppendProperty(edits,@"X-ABADR",group,RCTwoWayEscape([child objectForKey:@"country code"]),nil);
      [desiredPaths setObject:identifier forKey:[NSString stringWithFormat:@"%@:%d",properties[k],outputIndex++]];
    }
  }
  {
    RCResourceEdit *patch=calloc([edits count] ?: 1,sizeof(*patch)); NSUInteger n;
    unsigned char *bytes=NULL; size_t length=0;
    if (!patch) goto done;
    for(n=0;n<[edits count];n++) {
      NSDictionary *edit=[edits objectAtIndex:n];
      patch[n].property=[[edit objectForKey:@"name"] UTF8String];
      patch[n].group=[[edit objectForKey:@"group"] length] ? [[edit objectForKey:@"group"] UTF8String] : NULL;
      patch[n].occurrence=[[edit objectForKey:@"occurrence"] intValue];
      patch[n].parameters=[[edit objectForKey:@"parameters"] length] ? [[edit objectForKey:@"parameters"] UTF8String] : NULL;
      patch[n].value=[edit objectForKey:@"value"]==[NSNull null] ? NULL : [[edit objectForKey:@"value"] UTF8String];
    }
    ok=RCResourcePatch(RCResourceVCard,[raw bytes],[raw length],patch,[edits count],&bytes,&length,error);
    free(patch);
    if (ok) {
      NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:resource];
      [result setObject:[NSData dataWithBytes:bytes length:length] forKey:@"body"];
      [result setObject:desiredPaths forKey:@"paths"];
      [result setObject:RCTwoWaySubgraph(truth,[desiredPaths allValues]) forKey:@"graph"];
      free(bytes); RCVCardDocumentClear(&doc);
      return Validate([result objectForKey:@"body"],[result objectForKey:@"paths"],truth,error) ? result : nil;
    }
    free(bytes);
  }
  goto done;
unsupported:
  RCErrorSet(error,1,"Contact structure or labels changed beyond the supported reverse mapper");
done:
  RCVCardDocumentClear(&doc); return nil;
}
int RCSyncServicesTwoWayContacts(RCContactStore *store,const char *description,long *count,RCError *error)
{
  RCWriteJournal j=RCContactStoreWriteJournal(store); sqlite3_stmt *q=NULL;
  NSMutableDictionary *graph=[NSMutableDictionary dictionary]; NSMutableArray *resources=[NSMutableArray array];
  long long generation,published; int step=SQLITE_ERROR;
  if (!RCContactStoreGetPublicationState(store,&generation,&published,error) || !generation) {
    RCErrorSet(error,1,"Contacts have no complete inventory for two-way sync"); return 0;
  }
  if (sqlite3_prepare_v2(j.db,"SELECT c.id,c.sync_record_id,c.href,c.usable_etag,c.usable_vcard "
      "FROM contacts c JOIN collections b ON b.id=c.collection_id WHERE b.account_id=? AND b.remote_missing=0 "
      "AND c.remote_missing=0 AND c.usable_vcard IS NOT NULL ORDER BY c.id",-1,&q,NULL)!=SQLITE_OK) goto failed;
  sqlite3_bind_int64(q,1,j.account);
  while ((step=sqlite3_step(q))==SQLITE_ROW) {
    NSString *key=S((const char *)sqlite3_column_text(q,1)), *root=[@"contact-" stringByAppendingString:key];
    NSData *body=[NSData dataWithBytes:sqlite3_column_blob(q,4) length:sqlite3_column_bytes(q,4)];
    NSDictionary *mapped=RCContactNativeGraph(store,sqlite3_column_int64(q,0),[key UTF8String],body,error);
    if (!mapped) goto failed;
    NSDictionary *paths=RCContactNativePaths(body,mapped,root,error);
    if (!paths) goto failed;
    [graph addEntriesFromDictionary:mapped];
    [resources addObject:[NSDictionary dictionaryWithObjectsAndKeys:key,@"key",root,@"root",S((const char *)sqlite3_column_text(q,2)),@"href",
        S((const char *)sqlite3_column_text(q,3)),@"etag",body,@"body",mapped,@"graph",paths,@"paths",
        [NSNumber numberWithLongLong:generation],@"revision",nil]];
  }
  if (step!=SQLITE_DONE) goto failed;
  sqlite3_finalize(q); q=NULL;
  RCTwoWayContext c={j,RCContactSyncClientIdentifier(S(RCContactStoreSyncIdentifier(store))),S(description),entity,resources,graph,RCContactEncodeLocal,store,NO,RCContactProjectVerified,NO};
  if (!RCTwoWayExchange(&c,error)) return 0;
  if (c.didPublishAll && !RCContactStoreMarkPublished(store,generation,error)) return 0;
  if (count) *count=c.didPublishAll ? (long)[graph count] : -1;
  return 1;
failed:
  sqlite3_finalize(q); if (!error->code) RCErrorSet(error,1,"Could not build two-way contact graph"); return 0;
}
