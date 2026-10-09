#import "RCRecordGraph.h"
#import "RCTwoWaySync.h"
#import "RCAutorelease.h"
#import "RCContactPhoto.h"
#import "RCTwoWayNative.h"
#import "RCContactSyncClient.h"
#import "RCSyncRecordEquality.h"
#include "RCResourcePatch.h"
#include <string.h>
#include <stdlib.h>

#import "RCContactIM.h"

static NSString *relations[]={@"phone numbers",@"email addresses",@"street addresses",@"URLs",@"dates",@"related names",@"IMs"};
static NSString *properties[]={@"TEL",@"EMAIL",@"ADR",@"URL",@"X-ABDATE",@"X-ABRELATEDNAMES",@"IMPP"};
static NSString *primaryKeys[]={@"primary phone number",@"primary email address",@"primary street address",@"primary URL",@"primary date",@"primary related name",@"primary IM"};
static NSString *entity=@"com.apple.contacts.Contact";
static NSString *S(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }
static BOOL Changed(NSDictionary *a,NSDictionary *b,NSString *key)
{
  id x=[a objectForKey:key], y=[b objectForKey:key];
  NSString *kind=[a objectForKey:RCRecordEntityNameKey];
  if (![kind isEqual:[b objectForKey:RCRecordEntityNameKey]]) kind=nil;
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
  for (k=0;k<7;k++) {
    NSArray *ids=[contact objectForKey:relations[k]]; NSUInteger n=0; size_t p; int occurrence=0;
    for (p=0;p<doc.propertyCount;p++) if ([RCContactPathName(doc.properties[p].name) isEqual:properties[k]]) {
      BOOL visible=RCContactPropertyVisible(&doc.properties[p]);
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
  NSDictionary *mapped=RCContactNativeGraphWithPhotoCache(opaque,body,[current objectForKey:@"paths"],[current objectForKey:@"href"],[current objectForKey:@"verifiedETag"] ?: [current objectForKey:@"etag"],error);
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
  if ([current objectForKey:@"verifiedETag"]) [result setObject:[current objectForKey:@"verifiedETag"] forKey:@"etag"];
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
      ![properties[2] isEqual:name] && ![properties[3] isEqual:name] && ![properties[4] isEqual:name] && ![properties[5] isEqual:name] && ![RCContactPathName([name UTF8String]) isEqual:@"IMPP"] && ![name isEqual:@"X-ABLabel"] && ![name isEqual:@"X-ABADR"]) {
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
  NSString *kind=[child objectForKey:RCRecordEntityNameKey];
  if ([kind isEqual:@"com.apple.contacts.Date"] || [kind isEqual:@"com.apple.contacts.Related Name"]) labelType=@"other";
  NSString *type=[types objectForKey:RCNativeEmptyValue(labelType) ? @"other" : labelType];
  if (!type) return nil;
  if (preferred) type=[type length] ? [type stringByAppendingString:@",PREF"] : @"PREF";
  return [type length] ? [@"TYPE=" stringByAppendingString:type] : @"";
}
static NSString *NewLabel(NSDictionary *child)
{
  if ([[child objectForKey:@"type"] isEqual:@"home page"] &&
      [[child objectForKey:RCRecordEntityNameKey] isEqual:@"com.apple.contacts.URL"])
    return @"_$!<HomePage>!$_";
  NSString *kind=[child objectForKey:RCRecordEntityNameKey], *type=[child objectForKey:@"type"];
  if (([kind isEqual:@"com.apple.contacts.Date"] || [kind isEqual:@"com.apple.contacts.Related Name"]) && [type length] && ![type isEqual:@"other"])
    return [NSString stringWithFormat:@"_$!<%@>!$_",[type capitalizedString]];
  return [child objectForKey:@"label"];
}
static void AppendProperty(NSMutableArray *edits,NSString *name,NSString *group,NSString *value,NSString *parameters)
{
  [edits addObject:[NSDictionary dictionaryWithObjectsAndKeys:name,@"name",group,@"group",value,@"value",
      [NSNumber numberWithInt:-1],@"occurrence",parameters ?: @"",@"parameters",nil]];
}
/* Replace the PHOTO property explicitly so ENCODING/VALUE/TYPE describe the
   new bytes, even when replacing a URI or changing image format. Preserve its
   group and all unrelated parameters; the patcher rejects unsafe parameters. */
static BOOL PhotoEdit(RCVCardDocument *doc, id image, NSMutableArray *edits, RCError *error)
{
  NSString *value=RCNativeEmptyValue(image) ? nil : RCPhotoEncode(image);
  if (!RCNativeEmptyValue(image) && !value) { RCErrorSet(error,1,"Contact image must be binary data"); return NO; }
  RCVCardProperty *photo=NULL; size_t i;
  for(i=0;i<doc->propertyCount;i++) if (!strcasecmp(doc->properties[i].name,"PHOTO")) {
    if (photo) { RCErrorSet(error,1,"Ambiguous repeated contact photo"); return NO; }
    photo=&doc->properties[i];
  }
  if (photo && !AddEdit(doc,@"PHOTO",0,nil,edits,error)) return NO;
  if (value) {
    NSMutableString *parameters=[NSMutableString stringWithString:@"ENCODING=b"];
    NSString *type=RCPhotoType(image);
    if (type) [parameters appendFormat:@";TYPE=%@",type];
    if (photo) for(i=0;i<photo->parameterCount;i++) {
      RCVCardParameter *p=&photo->parameters[i];
      if (strcasecmp(p->name,"ENCODING") && strcasecmp(p->name,"VALUE") && strcasecmp(p->name,"TYPE")) {
        /* Parsed quoted values cannot be interpolated as raw parameters:
           delimiters would change their meaning. Leave that image pending. */
        const char *v=p->value;
        for (; *v; v++) if (!((*v>='a' && *v<='z') || (*v>='A' && *v<='Z') ||
            (*v>='0' && *v<='9') || strchr(",-_./",*v))) {
          RCErrorSet(error,1,"Contact photo has an uneditable extension parameter"); return NO;
        }
        [parameters appendFormat:@";%@=%@",S(p->name),S(p->value)];
      }
    }
    AppendProperty(edits,@"PHOTO",photo ? S(photo->group) : @"",value,parameters);
  }
  return YES;
}
static NSString *Birthday(id date)
{
  return [date isKindOfClass:[NSDate class]] ? [date descriptionWithCalendarFormat:@"%Y-%m-%d"
      timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0] locale:nil] : nil;
}
static NSString *ChildValue(NSDictionary *child,int kind)
{
  if(kind==4) return Birthday([child objectForKey:@"value"]);
  if(kind==6) {
    NSString *service=[child objectForKey:@"service"], *user=[child objectForKey:@"user"];
    if (![[@"aim|jabber|msn|yahoo|icq" componentsSeparatedByString:@"|"] containsObject:service] || ![user length]) return nil;
    return [NSString stringWithFormat:@"%@:%@",[service isEqual:@"jabber"] ? @"xmpp" : service,
        [user stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
  }
  return RCTwoWayEscape([child objectForKey:@"value"]);
}
static BOOL MetadataEdit(RCVCardDocument *doc,RCVCardProperty *property,int occurrence,
    NSDictionary *child,BOOL preferred,NSString *value,NSMutableArray *edits,RCError *error)
{
  NSString *type=NewType(child,preferred);
  if (!type || !value) return NO;
  NSMutableString *params=[NSMutableString stringWithString:type]; size_t i;
  NSArray *mappedTypes=[@"HOME|WORK|CELL|PAGER|FAX|PREF" componentsSeparatedByString:@"|"];
  NSMutableArray *extraTypes=[NSMutableArray array];
  for(i=0;i<property->parameterCount;i++) if(!strcasecmp(property->parameters[i].name,"TYPE")) {
    NSEnumerator *tokens=[[S(property->parameters[i].value) componentsSeparatedByString:@","] objectEnumerator]; NSString *token;
    while((token=[tokens nextObject])) if([token length] && ![mappedTypes containsObject:[token uppercaseString]]) [extraTypes addObject:token];
  }
  if([extraTypes count]) [params appendFormat:@"%@%@",[params length] ? @"," : @"TYPE=",[extraTypes componentsJoinedByString:@","]];
  for(i=0;i<property->parameterCount;i++) {
    RCVCardParameter *p=&property->parameters[i];
    if (!strcasecmp(p->name,"TYPE")) continue;
    if (!strcasecmp(p->name,"X-SERVICE-TYPE") && [child objectForKey:@"service"]) { if([params length]) [params appendString:@";"]; [params appendFormat:@"X-SERVICE-TYPE=%@",[[child objectForKey:@"service"] uppercaseString]]; continue; }
    if ([params length]) [params appendString:@";"];
    [params appendFormat:@"%@=%@",S(p->name),S(p->value)];
  }
  if(!AddEdit(doc,S(property->name),occurrence,value,edits,error)) return NO;
  NSMutableDictionary *edit=[NSMutableDictionary dictionaryWithDictionary:[edits lastObject]];
  [edit setObject:params forKey:@"parameters"]; [edits replaceObjectAtIndex:[edits count]-1 withObject:edit];
  return YES;
}
static BOOL GroupEdit(RCVCardDocument *doc,RCVCardProperty *owner,NSString *name,NSString *value,NSMutableArray *edits,RCError *error)
{
  size_t i; int n=0; RCVCardProperty *found=NULL;
  for(i=0;i<doc->propertyCount;i++) if (!strcasecmp(doc->properties[i].name,[name UTF8String])) {
    RCVCardProperty *p=&doc->properties[i];
    if ([S(p->group) isEqual:S(owner->group)]) {
      if(found) { RCErrorSet(error,1,"Ambiguous grouped contact metadata"); return NO; }
      found=p;
      if(!AddEdit(doc,name,n,value,edits,error)) return NO;
    }
    n++;
  }
  if(!found && value) AppendProperty(edits,name,S(owner->group),value,nil);
  return YES;
}
static BOOL Validate(RCContactStore *store, NSDictionary *resource, NSData *body, NSDictionary *paths, NSDictionary *truth, RCError *error)
{
  NSDictionary *mapped=RCContactNativeGraphWithPhotoCache(store,body,paths,[resource objectForKey:@"href"],[resource objectForKey:@"etag"],error);
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
  NSString *keys[]={@"notes",@"job title",@"nickname",@"first name yomi",@"middle name yomi",@"last name yomi",@"company name yomi"}, *names[]={@"NOTE",@"TITLE",@"NICKNAME",@"X-PHONETIC-FIRST-NAME",@"X-PHONETIC-MIDDLE-NAME",@"X-PHONETIC-LAST-NAME",@"X-PHONETIC-ORG"}; int k;
  for(k=0;k<7;k++) if ([[record objectForKey:keys[k]] length]) [body appendFormat:@"%@:%@\r\n",names[k],RCTwoWayEscape([record objectForKey:keys[k]])];
  if (!RCNativeEmptyValue([record objectForKey:@"birthday"])) [body appendFormat:@"BDAY:%@\r\n",Birthday([record objectForKey:@"birthday"])];
  if ([[record objectForKey:@"display as company"] isEqual:@"company"]) [body appendString:@"X-ABShowAs:COMPANY\r\n"];
  NSMutableDictionary *paths=[NSMutableDictionary dictionaryWithObject:root forKey:@"root"];
  for(k=0;k<7;k++) {
    NSEnumerator *ids=[[record objectForKey:relations[k]] objectEnumerator]; NSString *identifier; int n=0;
    while ((identifier=[ids nextObject])) {
      NSDictionary *child=[truth objectForKey:identifier];
      if (!child) { RCErrorSet(error,1,"New contact has an incomplete child graph"); return nil; }
      NSString *param=NewType(child,[[record objectForKey:primaryKeys[k]] containsObject:identifier]);
      if (!param) { RCErrorSet(error,1,"Unsupported contact label type"); return nil; }
      NSString *group=[NSString stringWithFormat:@"item%d-%d",k,n];
      NSString *value=k==2 ? [@";;" stringByAppendingString:Structured(child,[NSArray arrayWithObjects:@"street",@"city",@"state",@"postal code",@"country",nil])] : ChildValue(child,k);
      [body appendFormat:@"%@.%@%@:%@\r\n",group,properties[k],[param length] ? [@";" stringByAppendingString:param] : @"",value];
      if ([NewLabel(child) length]) [body appendFormat:@"%@.X-ABLabel:%@\r\n",group,RCTwoWayEscape(NewLabel(child))];
      if (k==2 && [[child objectForKey:@"country code"] length]) [body appendFormat:@"%@.X-ABADR:%@\r\n",group,RCTwoWayEscape([child objectForKey:@"country code"])];
      [paths setObject:identifier forKey:[NSString stringWithFormat:@"%@:%d",properties[k],n++]];
    }
  }
  [body appendString:@"END:VCARD\r\n"];
  /* Use the same folded binary property writer for creation and updates. */
  if (!RCNativeEmptyValue([record objectForKey:@"image"])) {
    NSData *raw=[body dataUsingEncoding:NSUTF8StringEncoding];
    RCVCardDocument empty; RCVCardDocumentInit(&empty);
    NSMutableArray *edits=[NSMutableArray array];
    if (!PhotoEdit(&empty,[record objectForKey:@"image"],edits,error)) return nil;
    NSDictionary *edit=[edits objectAtIndex:0];
    RCResourceEdit patch={0,"PHOTO",NULL,-1,[[edit objectForKey:@"value"] UTF8String],[[edit objectForKey:@"parameters"] UTF8String],NULL,NULL};
    unsigned char *bytes=NULL; size_t length=0;
    if (!RCResourcePatch(RCResourceVCard,[raw bytes],[raw length],&patch,1,&bytes,&length,error)) return nil;
    body=[[[NSMutableString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] autorelease];
    free(bytes);
  }
  NSData *data=[body dataUsingEncoding:NSUTF8StringEncoding]; RCVCardDocument doc;
  BOOL valid=RCVCardParse([data bytes],[data length],&doc,error); RCVCardDocumentClear(&doc);
  if (!valid || !Validate(store,nil,data,paths,truth,error)) return nil;
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
  NSString *keys[]={@"notes",@"job title",@"nickname",@"birthday",@"display as company",@"first name yomi",@"middle name yomi",@"last name yomi",@"company name yomi"};
  NSString *names[]={@"NOTE",@"TITLE",@"NICKNAME",@"BDAY",@"X-ABShowAs",@"X-PHONETIC-FIRST-NAME",@"X-PHONETIC-MIDDLE-NAME",@"X-PHONETIC-LAST-NAME",@"X-PHONETIC-ORG"};
  for(k=0;k<9;k++) if (Changed(base,record,keys[k])) {
    id v=[record objectForKey:keys[k]];
    NSString *value=k==3 ? Birthday(v) : k==4 ? ([v isEqual:@"company"] ? @"COMPANY" : nil) : v ? RCTwoWayEscape(v) : nil;
    if (!AddEdit(&doc,names[k],0,value,edits,error)) goto done;
  }
  if (Changed(base,record,@"image") && !PhotoEdit(&doc,[record objectForKey:@"image"],edits,error)) goto done;
  NSArray *allowed=[NSArray arrayWithObjects:@"image",@"last name",@"first name",@"middle name",@"title",@"suffix",@"company name",@"department",@"notes",@"job title",@"nickname",@"birthday",@"display as company",@"first name yomi",@"middle name yomi",@"last name yomi",@"company name yomi",nil];
  NSEnumerator *it=[allowed objectEnumerator]; NSString *key;
  while ((key=[it nextObject])) { if ([record objectForKey:key]) [expected setObject:[record objectForKey:key] forKey:key]; else [expected removeObjectForKey:key]; }
  for(k=0;k<7;k++) {
    if ([record objectForKey:relations[k]]) [expected setObject:[record objectForKey:relations[k]] forKey:relations[k]];
    else [expected removeObjectForKey:relations[k]];
    if (k<4 && [record objectForKey:primaryKeys[k]]) [expected setObject:[record objectForKey:primaryKeys[k]] forKey:primaryKeys[k]];
    else [expected removeObjectForKey:primaryKeys[k]];
  }
  if (!RCTwoWayRecordsEqual(expected,record)) goto unsupported;
  NSMutableDictionary *desiredPaths=[NSMutableDictionary dictionaryWithObject:root forKey:@"root"];
  for(k=0;k<7;k++) {
    NSArray *ids=[base objectForKey:relations[k]], *currentIDs=[record objectForKey:relations[k]];
    int n=0, outputIndex=0; size_t propertyIndex;
    for(propertyIndex=0;propertyIndex<doc.propertyCount;propertyIndex++) {
      if (![RCContactPathName(doc.properties[propertyIndex].name) isEqual:properties[k]]) continue;
      NSString *wireName=S(doc.properties[propertyIndex].name); int wireOccurrence=0; size_t wi;
      for(wi=0;wi<propertyIndex;wi++) if(!strcasecmp(doc.properties[wi].name,[wireName UTF8String])) wireOccurrence++;
      int occurrence=n++;
      NSString *identifier=[[resource objectForKey:@"paths"] objectForKey:
          [NSString stringWithFormat:@"%@:%d",properties[k],occurrence]];
      /* Invisible raw fields still occupy positions and must survive edits. */
      if (!identifier) { outputIndex++; continue; }
      NSDictionary *old=[baseGraph objectForKey:identifier], *child=[truth objectForKey:identifier];
      if (![currentIDs containsObject:identifier]) {
        if (!AddEdit(&doc,wireName,wireOccurrence,nil,edits,error)) goto done;
        continue;
      }
      if (!child) goto unsupported;
      [desiredPaths setObject:identifier forKey:[NSString stringWithFormat:@"%@:%d",properties[k],outputIndex++]];
      NSMutableDictionary *check=[NSMutableDictionary dictionaryWithDictionary:old];
      NSArray *fields=k==2 ? [NSArray arrayWithObjects:@"street",@"city",@"state",@"postal code",@"country",@"country code",@"type",@"label",nil] :
          k==6 ? [NSArray arrayWithObjects:@"user",@"service",@"type",@"label",nil] : [NSArray arrayWithObjects:@"value",@"type",@"label",nil];
      it=[fields objectEnumerator]; BOOL changed=NO;
      while ((key=[it nextObject])) {
        if (Changed(old,child,key)) changed=YES;
        if ([child objectForKey:key]) [check setObject:[child objectForKey:key] forKey:key]; else [check removeObjectForKey:key];
      }
      if (!RCTwoWayRecordsEqual(check,child)) goto unsupported;
      BOOL preferred=[[record objectForKey:primaryKeys[k]] containsObject:identifier];
      BOOL metadata=Changed(old,child,@"type") || Changed(old,child,@"label") || (k==6 && Changed(old,child,@"service")) || (k<4 && Changed(base,record,primaryKeys[k])) ||
          (preferred != [[base objectForKey:primaryKeys[k]] containsObject:identifier]);
      if (changed || metadata) {
        NSString *value=k==2 ? StructuredEdit(&doc,@"ADR",occurrence,[NSArray arrayWithObjects:@"",@"",@"street",@"city",@"state",@"postal code",@"country",nil],old,child,YES) : ChildValue(child,k);
        NSString *legacy=RCLegacyIMService(doc.properties[propertyIndex].name);
        BOOL renameIM=legacy && ![legacy isEqual:[child objectForKey:@"service"]];
        if(legacy && !renameIM) value=RCTwoWayEscape([child objectForKey:@"user"]);
        NSString *newGroup=nil;
        if(!doc.properties[propertyIndex].group && (metadata || (k==2 && Changed(old,child,@"country code"))))
          newGroup=[@"rc-" stringByAppendingString:RCTwoWayNewIdentifier()];
        if (metadata) {
          if(!MetadataEdit(&doc,&doc.properties[propertyIndex],wireOccurrence,child,preferred,value,edits,error)) goto done;
        } else if (!AddEdit(&doc,wireName,wireOccurrence,value,edits,error)) goto done;
        if(renameIM) {
          NSMutableDictionary *edit=[NSMutableDictionary dictionaryWithDictionary:[edits lastObject]];
          [edit setObject:@"IMPP" forKey:@"replacementProperty"]; [edits replaceObjectAtIndex:[edits count]-1 withObject:edit];
        }
        if(newGroup) {
          NSMutableDictionary *edit=[NSMutableDictionary dictionaryWithDictionary:[edits lastObject]];
          [edit setObject:newGroup forKey:@"replacementGroup"]; [edits replaceObjectAtIndex:[edits count]-1 withObject:edit];
          if([NewLabel(child) length]) AppendProperty(edits,@"X-ABLabel",newGroup,RCTwoWayEscape(NewLabel(child)),nil);
          if(k==2 && [[child objectForKey:@"country code"] length]) AppendProperty(edits,@"X-ABADR",newGroup,RCTwoWayEscape([child objectForKey:@"country code"]),nil);
        } else {
          if(Changed(old,child,@"label") || Changed(old,child,@"type"))
            if(!GroupEdit(&doc,&doc.properties[propertyIndex],@"X-ABLabel",[NewLabel(child) length] ? RCTwoWayEscape(NewLabel(child)) : nil,edits,error)) goto done;
          if(k==2 && Changed(old,child,@"country code"))
            if(!GroupEdit(&doc,&doc.properties[propertyIndex],@"X-ABADR",[[child objectForKey:@"country code"] length] ? RCTwoWayEscape([child objectForKey:@"country code"]) : nil,edits,error)) goto done;
        }
      }
    }
    NSEnumerator *newIDs=[currentIDs objectEnumerator]; NSString *identifier;
    while ((identifier=[newIDs nextObject])) if (![ids containsObject:identifier]) {
      NSDictionary *child=[truth objectForKey:identifier];
      NSString *params=NewType(child,[[record objectForKey:primaryKeys[k]] containsObject:identifier]);
      if (!child || !params) goto unsupported;
      NSString *group=[@"rc-" stringByAppendingString:RCTwoWayNewIdentifier()];
      NSString *value=k==2 ? [@";;" stringByAppendingString:Structured(child,[NSArray arrayWithObjects:@"street",@"city",@"state",@"postal code",@"country",nil])] : ChildValue(child,k);
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
      patch[n].replacementProperty=[[edit objectForKey:@"replacementProperty"] UTF8String];
      patch[n].replacementGroup=[[edit objectForKey:@"replacementGroup"] UTF8String];
      patch[n].parameters=[edit objectForKey:@"parameters"] ? [[edit objectForKey:@"parameters"] UTF8String] : NULL;
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
      return Validate(opaque,resource,[result objectForKey:@"body"],[result objectForKey:@"paths"],truth,error) ? result : nil;
    }
    free(bytes);
  }
  goto done;
unsupported:
  RCErrorSet(error,1,"Contact structure or labels changed beyond the supported reverse mapper");
done:
  RCVCardDocumentClear(&doc); return nil;
}
int RCExchangeContacts(RCContactStore *store,const char *description,RCBackendExchange exchange,BOOL twoWay,long *count,RCError *error)
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
    NSAutoreleasePool *resourcePool=[[NSAutoreleasePool alloc] init];
    @try {
      if(RCCheckCancellation(error)) goto failed;
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
    } @catch(id exception) {
      RCDrainPoolPreservingException(&resourcePool,exception); @throw;
    } @finally { [resourcePool release]; }
  }
  if (step!=SQLITE_DONE) goto failed;
  sqlite3_finalize(q); q=NULL;
  RCTwoWayContext c={j,RCContactSyncClientIdentifier(S(RCContactStoreSyncIdentifier(store))),S(description),entity,resources,graph,RCContactEncodeLocal,store,NO,RCContactProjectVerified,NO};
  if (!exchange(&c,twoWay,error)) return 0;
  if (c.didPublishAll && !RCContactStoreMarkPublished(store,generation,error)) return 0;
  if (count) *count=c.didPublishAll ? (long)[graph count] : -1;
  return 1;
failed:
  sqlite3_finalize(q); if (!error->code) RCErrorSet(error,1,"Could not build two-way contact graph"); return 0;
}
