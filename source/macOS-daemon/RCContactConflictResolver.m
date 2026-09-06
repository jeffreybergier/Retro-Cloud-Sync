#import "RCContactConflictResolver.h"
#include "RCResourcePatch.h"
#include "RCVCard.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static const char *fields[] = {"NOTE", "TITLE", "NICKNAME"};
static NSString *keys[] = {@"notes", @"job title", @"nickname"};
static NSString *String(const char *s)
{
  return s ? [NSString stringWithUTF8String:s] : @"";
}
static NSData *Bytes(const char *s)
{
  return [NSData dataWithBytes:s ?: "" length:s ? strlen(s) : 0];
}
static int Editable(const char *name)
{
  int i;
  for (i=0;i<3;i++) if (!strcasecmp(name,fields[i])) return i;
  return -1;
}
static BOOL Mapped(const char *name)
{
  static const char *names[] = {"UID","VERSION","N","FN","ORG","BDAY",
      "X-ABShowAs","TEL","EMAIL","ADR","URL","X-ABLabel","X-ABADR"};
  size_t i;
  for (i=0;i<sizeof(names)/sizeof(names[0]);i++)
    if (!strcasecmp(name,names[i])) return YES;
  return NO;
}
/* Conservative semantic signature: positional changes to repeated properties
   are deferred until the reverse multivalue mapper can identify their owners.
   Remote unknown properties are excluded here and retained by byte patching. */
static NSArray *Signature(RCVCardDocument *d, BOOL mappedOnly)
{
  NSMutableArray *result = [NSMutableArray array];
  size_t i,j;
  for (i=0;i<d->propertyCount;i++) {
    RCVCardProperty *p=&d->properties[i];
    NSMutableArray *parameters=[NSMutableArray array];
    if (Editable(p->name)>=0 || (mappedOnly && !Mapped(p->name))) continue;
    for (j=0;j<p->parameterCount;j++) [parameters addObject:
        [NSArray arrayWithObjects:[String(p->parameters[j].name) uppercaseString],
            Bytes(p->parameters[j].value),nil]];
    [result addObject:[NSArray arrayWithObjects:[String(p->name) uppercaseString],
        Bytes(p->group), Bytes(p->originalValue), parameters, nil]];
  }
  return result;
}
static BOOL TextProperties(RCVCardDocument *d, RCVCardProperty **properties)
{
  size_t i,j;
  memset(properties,0,3*sizeof(*properties));
  for (i=0;i<d->propertyCount;i++) {
    RCVCardProperty *p=&d->properties[i];
    int index=Editable(p->name);
    if (index<0) continue;
    if (properties[index] || p->group || !String(p->decodedValue)) return NO;
    for (j=0;j<p->parameterCount;j++)
      if (strcasecmp(p->parameters[j].name,"LANGUAGE")) return NO;
    properties[index]=p;
  }
  return YES;
}
static NSString *Escape(NSString *value)
{
  NSMutableString *s=[[value mutableCopy] autorelease];
  [s replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"\r" withString:@"\n" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@";" withString:@"\\;" options:0 range:NSMakeRange(0,[s length])];
  [s replaceOccurrencesOfString:@"," withString:@"\\," options:0 range:NSMakeRange(0,[s length])];
  return s;
}
typedef struct {
  ISyncClient *client;
  NSDictionary *graph;
  NSString *recordID;
} Context;

static int Resolve(void *opaque, const RCWriteOperation *o,
    RCConflictDecision *decision, RCError *error)
{
  Context *c=opaque;
  RCVCardDocument base,local,remote;
  RCVCardProperty *bp[3],*lp[3],*rp[3];
  RCResourceEdit edits[3];
  NSMutableDictionary *graph, *record;
  NSDictionary *receipt, *resolved;
  NSData *receiptData;
  NSUInteger count=0;
  int disposition=RCConflictNeedsAttention, i;
  decision->attentionReason="unsupported-contact-mapping";
  RCVCardDocumentInit(&base); RCVCardDocumentInit(&local); RCVCardDocumentInit(&remote);
  if (![c->recordID isEqual:String(o->resourceKey)] &&
      ![c->recordID isEqual:[@"contact-" stringByAppendingString:String(o->resourceKey)]]) {
    decision->attentionReason="resource-identity-changed"; goto done;
  }
  if (!RCVCardParse(o->baseBody,o->baseLength,&base,error) ||
      !RCVCardParse(o->desiredBody,o->desiredLength,&local,error) ||
      !RCVCardParse(o->resultBody,o->resultLength,&remote,error)) goto done;
  if (!base.uid || !*base.uid || !local.uid || !remote.uid ||
      strcmp(base.uid,local.uid) || strcmp(base.uid,remote.uid)) {
    decision->attentionReason="resource-identity-changed"; goto done;
  }
  if (!TextProperties(&base,bp) || !TextProperties(&local,lp) || !TextProperties(&remote,rp) ||
      ![Signature(&base,NO) isEqual:Signature(&local,NO)] ||
      ![Signature(&base,YES) isEqual:Signature(&remote,YES)]) goto done;
  graph=[[c->graph mutableCopy] autorelease];
  record=[[[graph objectForKey:c->recordID] mutableCopy] autorelease];
  if (![[record objectForKey:ISyncRecordEntityNameKey] isEqual:@"com.apple.contacts.Contact"]) goto done;
  for (i=0;i<3;i++) {
    NSString *value=rp[i] ? String(rp[i]->decodedValue) : nil;
    if ([value length]) [record setObject:value forKey:keys[i]];
    else [record removeObjectForKey:keys[i]];
  }
  [graph setObject:record forKey:c->recordID];
  {
    NSMutableDictionary *intent=[NSMutableDictionary dictionary];
    for (i=0;i<3;i++) {
      NSString *before=bp[i] ? String(bp[i]->decodedValue) : @"";
      NSString *after=lp[i] ? String(lp[i]->decodedValue) : @"";
      if (![before isEqual:after]) [intent setObject:[after length] ? (id)after :
          (id)[NSNull null] forKey:keys[i]];
    }
    receipt=RCSyncResolveConflictWithIntent(c->client,graph,
        [NSArray arrayWithObject:c->recordID],
        [NSDictionary dictionaryWithObject:intent forKey:c->recordID],error);
  }
  if (!receipt) { disposition=RCConflictDeferred; goto done; }
  resolved=[receipt objectForKey:c->recordID];
  /* A concurrent edit of an unsupported field must remain pending, not be
     acknowledged just because this resource's text fields can be patched. */
  {
    NSMutableDictionary *a=[[record mutableCopy] autorelease];
    NSMutableDictionary *b=[[resolved mutableCopy] autorelease];
    for (i=0;i<3;i++) { [a removeObjectForKey:keys[i]]; [b removeObjectForKey:keys[i]]; }
    if (![a isEqual:b]) goto done;
  }
  memset(edits,0,sizeof(edits));
  for (i=0;i<3;i++) {
    NSString *value=[resolved objectForKey:keys[i]];
    NSString *old=rp[i] ? String(rp[i]->decodedValue) : nil;
    if (value && ![value isKindOfClass:[NSString class]]) goto done;
    if ((!value && !old) || [value isEqual:old]) continue;
    edits[count].property=fields[i];
    edits[count].occurrence=rp[i] ? 0 : -1;
    edits[count].value=value ? [Escape(value) UTF8String] : NULL;
    count++;
  }
  if (!RCResourcePatch(RCResourceVCard,o->resultBody,o->resultLength,edits,count,
      (unsigned char **)&decision->body,&decision->length,error)) goto done;
  receiptData=[NSPropertyListSerialization dataFromPropertyList:receipt
      format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
  if (!receiptData) goto done;
  decision->receiptLength=[receiptData length];
  decision->receipt=malloc(decision->receiptLength);
  decision->kind=strdup("update");
  if (!decision->receipt || !decision->kind) {
    RCErrorSet(error,1,"Out of memory retaining conflict decision"); disposition=-1; goto done;
  }
  memcpy(decision->receipt,[receiptData bytes],decision->receiptLength);
  disposition=RCConflictResolved;
done:
  RCVCardDocumentClear(&base); RCVCardDocumentClear(&local); RCVCardDocumentClear(&remote);
  return disposition;
}

int RCContactRecoverConflict(RCWriteJournal *j, long long id, ISyncClient *client,
    NSDictionary *graph, NSString *recordID, long long *successor, RCError *error)
{
  Context context;
  RCConflictCallbacks callbacks;
  context.client=client; context.graph=graph; context.recordID=recordID;
  memset(&callbacks,0,sizeof(callbacks)); callbacks.context=&context; callbacks.resolve=Resolve;
  return RCConflictRecover(j,id,&callbacks,successor,error);
}

int RCContactAcceptConflict(ISyncClient *client, const RCWriteOperation *o,
    const void *receiptBytes, size_t length, RCError *error)
{
  RCVCardDocument desired,confirmed;
  RCVCardProperty *dp[3],*cp[3];
  NSDictionary *receipt;
  int ok=0,i;
  RCVCardDocumentInit(&desired); RCVCardDocumentInit(&confirmed);
  if (!receiptBytes || !length || strcmp(o->state,"applied")) goto done;
  receipt=[NSPropertyListSerialization propertyListFromData:
      [NSData dataWithBytes:receiptBytes length:length]
      mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
  if (![receipt isKindOfClass:[NSDictionary class]] || [receipt count]!=1) goto done;
  if (!RCVCardParse(o->desiredBody,o->desiredLength,&desired,error) ||
      !RCVCardParse(o->resultBody,o->resultLength,&confirmed,error) ||
      ![Signature(&desired,YES) isEqual:Signature(&confirmed,YES)] ||
      !TextProperties(&desired,dp) || !TextProperties(&confirmed,cp)) goto done;
  for (i=0;i<3;i++) if (![(dp[i] ? String(dp[i]->decodedValue) : @"")
      isEqual:(cp[i] ? String(cp[i]->decodedValue) : @"")]) goto done;
  ok=RCSyncAcceptConflictResolution(client,receipt,error);
done:
  RCVCardDocumentClear(&desired); RCVCardDocumentClear(&confirmed);
  if (!ok && (!error || !error->code)) RCErrorSet(error,1,"Verified resolution needs mapping review");
  return ok;
}
