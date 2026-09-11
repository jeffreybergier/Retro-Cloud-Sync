#import "RCSyncConflictSession.h"
#import "RCTwoWayNative.h"
#import "RCContactPhoto.h"
#import "RCLogger.h"
#import "RCSyncServicesBridge.h"
#import "RCContactSyncClient.h"
#import "RCTwoWaySync.h"

#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>

#include "RCVCard.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#import "RCContactIM.h"
static NSString * const kRCContactEntity = @"com.apple.contacts.Contact";
static NSString * const kRCPhoneEntity = @"com.apple.contacts.Phone Number";
static NSString * const kRCEmailEntity = @"com.apple.contacts.Email Address";
static NSString * const kRCAddressEntity = @"com.apple.contacts.Street Address";
static NSString * const kRCURLEntity = @"com.apple.contacts.URL";
static NSString * const kRCDateEntity = @"com.apple.contacts.Date";
static NSString * const kRCGroupEntity = @"com.apple.contacts.Group";
static NSString * const kRCSmartGroupEntity = @"com.apple.contacts.SmartGroup";
static NSString * const kRCIMEntity = @"com.apple.contacts.IM";
static NSString * const kRCRelatedNameEntity = @"com.apple.contacts.Related Name";
static NSString * const kRCTestClientIdentifier =
    @"com.retrocloudsync.contacts.test.v1";

typedef struct {
  RCContactStore *store;
  NSMutableDictionary *records;
  long recordCount;
  NSString *photoHref, *photoETag;
  NSDictionary *propertyIdentities; /* optional detached reverse-mapping validation */
} RCSyncExportContext;

static NSString *RCString(const char *value)
{
  NSString *string;
  if (value == NULL || value[0] == '\0') return nil;
  string = [NSString stringWithUTF8String:value];
  if (string == nil) {
    string = [[[NSString alloc] initWithBytes:value length:strlen(value)
                                     encoding:NSISOLatin1StringEncoding]
        autorelease];
  }
  return string;
}

static NSString *RCPrefixedIdentifier(NSString *prefix, const char *identifier)
{
  NSString *value = RCString(identifier);
  return value == nil ? nil : [prefix stringByAppendingString:value];
}

static RCVCardProperty *RCProperty(RCVCardDocument *document,
                                  const char *name)
{
  size_t index;
  for (index = 0; index < document->propertyCount; index++) {
    if (strcasecmp(document->properties[index].name, name) == 0) {
      return &document->properties[index];
    }
  }
  return NULL;
}

static NSString *RCPart(RCVCardProperty *property, int component)
{
  size_t index;
  if (property == NULL) return nil;
  for (index = 0; index < property->partCount; index++) {
    if (property->parts[index].component == component) {
      return RCString(property->parts[index].value);
    }
  }
  return nil;
}

static int RCParameterContains(const RCVCardProperty *property,
                               const char *parameterName,
                               const char *wantedValue)
{
  size_t index;
  for (index = 0; index < property->parameterCount; index++) {
    const RCVCardParameter *parameter = &property->parameters[index];
    const char *start;
    if (strcasecmp(parameter->name, parameterName) != 0) continue;
    start = parameter->value;
    while (start != NULL && *start != '\0') {
      const char *end = strchr(start, ',');
      size_t length = end == NULL ? strlen(start) : (size_t)(end - start);
      if (strlen(wantedValue) == length &&
          strncasecmp(start, wantedValue, length) == 0) return 1;
      start = end == NULL ? NULL : end + 1;
    }
  }
  return 0;
}

static NSString *RCGroupedValue(RCVCardDocument *document,
                                const RCVCardProperty *property,
                                const char *propertyName)
{
  size_t index;
  if (property->group == NULL) return nil;
  for (index = 0; index < document->propertyCount; index++) {
    RCVCardProperty *candidate = &document->properties[index];
    if (candidate->group != NULL &&
        strcmp(candidate->group, property->group) == 0 &&
        strcasecmp(candidate->name, propertyName) == 0) {
      return RCString(candidate->decodedValue);
    }
  }
  return nil;
}

static NSString *RCPropertyType(const RCVCardProperty *property,
                                NSString *entity)
{
  if ([entity isEqualToString:kRCPhoneEntity]) {
    if (RCParameterContains(property, "TYPE", "CELL") ||
        RCParameterContains(property, "TYPE", "IPHONE")) return @"mobile";
    if (RCParameterContains(property, "TYPE", "PAGER")) return @"pager";
    if (RCParameterContains(property, "TYPE", "FAX")) {
      return RCParameterContains(property, "TYPE", "HOME") ?
          @"home fax" : @"work fax";
    }
  }
  if (RCParameterContains(property, "TYPE", "HOME")) return @"home";
  if (RCParameterContains(property, "TYPE", "WORK")) return @"work";
  return @"other";
}

static NSDate *RCBirthday(const char *value)
{
  int year;
  int month;
  int day;
  char trailing;
  if (value == NULL || sscanf(value, "%d-%d-%d%c", &year, &month, &day,
                              &trailing) != 3 ||
      year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return nil;
  return [NSCalendarDate dateWithYear:year month:month day:day hour:12 minute:0
      second:0 timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
}

static NSString *RCStreet(RCVCardProperty *property)
{
  NSMutableArray *parts = [NSMutableArray array];
  NSString *value;
  int component;
  for (component = 0; component <= 2; component++) {
    value = RCPart(property, component);
    if ([value length] != 0) [parts addObject:value];
  }
  return [parts count] == 0 ? nil : [parts componentsJoinedByString:@"\n"];
}

static int RCPushChild(RCSyncExportContext *context, long long contactIdentifier,
                       NSString *contactSyncIdentifier,
                       RCVCardDocument *document, RCVCardProperty *property,
                       NSString *entity, NSMutableArray *identifiers,
                       NSString **primaryIdentifier, RCError *error)
{
  char *storedIdentifier = NULL;
  NSString *recordIdentifier;
  NSMutableDictionary *record;
  NSString *value;
  NSString *label;

  if(!RCContactPropertyVisible(property)) return 1;
  if (context->propertyIdentities) {
    recordIdentifier=[context->propertyIdentities objectForKey:[NSNumber numberWithInt:property->position]];
  } else {
    if (!RCContactStoreCopyPropertySyncIdentifier(context->store,
        contactIdentifier, property->position, &storedIdentifier, error)) return 0;
    recordIdentifier = RCPrefixedIdentifier(@"property-", storedIdentifier);
    free(storedIdentifier);
  }
  if (recordIdentifier == nil) {
    RCErrorSet(error, 1, "A cached contact property has no sync identity");
    return 0;
  }
  record = [NSMutableDictionary dictionaryWithObjectsAndKeys:
      entity, ISyncRecordEntityNameKey,
      [NSArray arrayWithObject:contactSyncIdentifier], @"contact", nil];
  label = RCGroupedValue(document, property, "X-ABLabel");
  /* Address Book uses the label attribute only for type "other". Keep
     grouped labels (including Apple's localized label tokens) visible. */
  [record setObject:([label length] != 0 ? @"other" :
                    RCPropertyType(property, entity)) forKey:@"type"];
  if ([label length] != 0) [record setObject:label forKey:@"label"];
  if ([entity isEqualToString:kRCURLEntity] && [label isEqualToString:@"_$!<HomePage>!$_"]) {
    [record setObject:@"home page" forKey:@"type"];
    [record removeObjectForKey:@"label"];
  }
  if ([entity isEqual:@"com.apple.contacts.Date"] || [entity isEqual:@"com.apple.contacts.Related Name"]) {
    NSString *type=nil;
    if ([label hasPrefix:@"_$!<"] && [label hasSuffix:@">!$_"]) type=[[label substringWithRange:NSMakeRange(4,[label length]-8)] lowercaseString];
    NSArray *types=[entity isEqual:@"com.apple.contacts.Date"] ? [NSArray arrayWithObject:@"anniversary"] :
      [@"father|mother|parent|child|brother|sister|friend|spouse|partner|assistant|manager" componentsSeparatedByString:@"|"];
    if ([types containsObject:type]) { [record setObject:type forKey:@"type"]; [record removeObjectForKey:@"label"]; }
    else [record setObject:@"other" forKey:@"type"];
    id v=[entity isEqual:@"com.apple.contacts.Date"] ? (id)RCBirthday(property->decodedValue) : RCString(property->decodedValue);
    if (!v) return 1;
    [record setObject:v forKey:@"value"];
  } else if ([entity isEqual:@"com.apple.contacts.IM"]) {
    NSString *raw=RCString(property->decodedValue);
    NSString *legacy=RCLegacyIMService(property->name);
    if(legacy) raw=[NSString stringWithFormat:@"%@:%@",legacy,[raw stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    NSRange colon=[raw rangeOfString:@":"];
    if (colon.location==NSNotFound) return 1;
    NSString *service=[[raw substringToIndex:colon.location] lowercaseString];
    if ([service isEqual:@"xmpp"]) service=@"jabber";
    if (![[ @"aim|jabber|msn|yahoo|icq" componentsSeparatedByString:@"|"] containsObject:service]) return 1;
    [record setObject:service forKey:@"service"];
    [record setObject:[[raw substringFromIndex:colon.location+1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] forKey:@"user"];
  } else if ([entity isEqualToString:kRCAddressEntity]) {
    value = RCStreet(property);
    if ([value length] != 0) [record setObject:value forKey:@"street"];
    value = RCPart(property, 3);
    if ([value length] != 0) [record setObject:value forKey:@"city"];
    value = RCPart(property, 4);
    if ([value length] != 0) [record setObject:value forKey:@"state"];
    value = RCPart(property, 5);
    if ([value length] != 0) [record setObject:value forKey:@"postal code"];
    value = RCPart(property, 6);
    if ([value length] != 0) [record setObject:value forKey:@"country"];
    value = RCGroupedValue(document, property, "X-ABADR");
    if ([value length] != 0) [record setObject:value forKey:@"country code"];
  } else {
    value = RCString(property->decodedValue);
    if ([value length] == 0) return 1;
    if ([entity isEqualToString:kRCURLEntity]) {
      NSURL *url = [NSURL URLWithString:value];
      if (url == nil) return 1;
      [record setObject:url forKey:@"value"];
    } else {
      [record setObject:value forKey:@"value"];
    }
  }
  [context->records setObject:record forKey:recordIdentifier];
  [identifiers addObject:recordIdentifier];
  if (primaryIdentifier != NULL && *primaryIdentifier == nil &&
      RCParameterContains(property, "TYPE", "PREF")) {
    *primaryIdentifier = recordIdentifier;
  }
  context->recordCount++;
  return 1;
}

static int RCExportContact(long long contactIdentifier,
                           const char *storedSyncIdentifier,
                           const unsigned char *rawVCard,
                           size_t rawVCardLength, void *opaqueContext,
                           RCError *error)
{
  if (RCCheckCancellation(error)) return 0;
  RCSyncExportContext *context = (RCSyncExportContext *)opaqueContext;
  RCVCardDocument document;
  NSString *contactSyncIdentifier;
  NSMutableDictionary *contact;
  NSMutableArray *phones = [NSMutableArray array];
  NSMutableArray *emails = [NSMutableArray array];
  NSMutableArray *addresses = [NSMutableArray array];
  NSMutableArray *urls = [NSMutableArray array];
  NSMutableArray *dates=[NSMutableArray array], *related=[NSMutableArray array], *ims=[NSMutableArray array];
  NSString *primaryPhone = nil;
  NSString *primaryEmail = nil;
  NSString *primaryAddress = nil;
  NSString *primaryURL = nil;
  RCVCardProperty *name;
  RCVCardProperty *organization;
  size_t index;

  contactSyncIdentifier = RCPrefixedIdentifier(@"contact-", storedSyncIdentifier);
  if (contactSyncIdentifier == nil) {
    RCErrorSet(error, 1, "A cached contact has no sync identity");
    return 0;
  }
  RCVCardDocumentInit(&document);
  if (!RCVCardParse(rawVCard, rawVCardLength, &document, error)) return 0;
  contact = [NSMutableDictionary dictionaryWithObject:kRCContactEntity
                                               forKey:ISyncRecordEntityNameKey];
  NSData *image=nil;
  NSString *photoHref=context->photoHref, *photoETag=context->photoETag;
  if (context->store && RCContactPhotoURI(&document) && !photoHref) {
    RCWriteJournal j=RCContactStoreWriteJournal(context->store); sqlite3_stmt *q=NULL;
    if (sqlite3_prepare_v2(j.db,"SELECT c.href,c.usable_etag FROM contacts c JOIN collections b ON b.id=c.collection_id WHERE c.id=? AND b.account_id=?",-1,&q,NULL)==SQLITE_OK) {
      sqlite3_bind_int64(q,1,contactIdentifier); sqlite3_bind_int64(q,2,j.account);
      if (sqlite3_step(q)==SQLITE_ROW) {
        photoHref=RCString((const char *)sqlite3_column_text(q,0));
        photoETag=RCString((const char *)sqlite3_column_text(q,1));
      }
    }
    sqlite3_finalize(q);
  }
  if (!RCContactPhotoRead(context->store,&document,photoHref,photoETag,&image,error)) {
    RCVCardDocumentClear(&document); return 0;
  }
  if (image) [contact setObject:image forKey:@"image"];
  name = RCProperty(&document, "N");
  organization = RCProperty(&document, "ORG");
  {
    RCVCardProperty *showAs = RCProperty(&document, "X-ABShowAs");
    NSString *showAsValue = showAs == NULL ? nil :
        RCString(showAs->decodedValue);
    [contact setObject:(showAsValue != nil &&
        [showAsValue caseInsensitiveCompare:@"COMPANY"] == NSOrderedSame ?
        @"company" : @"person") forKey:@"display as company"];
  }
#define RC_SET_STRING(key, stringValue) do { \
    NSString *temporaryValue = (stringValue); \
    if ([temporaryValue length] != 0) [contact setObject:temporaryValue forKey:(key)]; \
  } while (0)
  NSString *phoneticKeys[]={@"first name yomi",@"middle name yomi",@"last name yomi",@"company name yomi"};
  const char *phoneticNames[]={"X-PHONETIC-FIRST-NAME","X-PHONETIC-MIDDLE-NAME","X-PHONETIC-LAST-NAME","X-PHONETIC-ORG"}; int pi;
  for(pi=0;pi<4;pi++) { RCVCardProperty *p=RCProperty(&document,phoneticNames[pi]); if(p) RC_SET_STRING(phoneticKeys[pi],RCString(p->decodedValue)); }
  RC_SET_STRING(@"last name", RCPart(name, 0));
  RC_SET_STRING(@"first name", RCPart(name, 1));
  RC_SET_STRING(@"middle name", RCPart(name, 2));
  RC_SET_STRING(@"title", RCPart(name, 3));
  RC_SET_STRING(@"suffix", RCPart(name, 4));
  RC_SET_STRING(@"company name", RCPart(organization, 0));
  RC_SET_STRING(@"department", RCPart(organization, 1));
  RC_SET_STRING(@"job title", RCString(document.title));
  {
    RCVCardProperty *nickname = RCProperty(&document, "NICKNAME");
    RCVCardProperty *note = RCProperty(&document, "NOTE");
    NSDate *birthday = RCBirthday(document.birthday);
    RC_SET_STRING(@"nickname", nickname == NULL ? nil :
                  RCString(nickname->decodedValue));
    RC_SET_STRING(@"notes", note == NULL ? nil : RCString(note->decodedValue));
    if (birthday != nil) [contact setObject:birthday forKey:@"birthday"];
  }
#undef RC_SET_STRING

  for (index = 0; index < document.propertyCount; index++) {
    RCVCardProperty *property = &document.properties[index];
    NSString *entity = nil;
    NSMutableArray *identifiers = nil;
    NSString **primary = NULL;
    if (strcasecmp(property->name, "TEL") == 0) {
      entity = kRCPhoneEntity; identifiers = phones; primary = &primaryPhone;
    } else if (strcasecmp(property->name, "EMAIL") == 0) {
      entity = kRCEmailEntity; identifiers = emails; primary = &primaryEmail;
    } else if (strcasecmp(property->name, "ADR") == 0) {
      entity = kRCAddressEntity; identifiers = addresses; primary = &primaryAddress;
    } else if (strcasecmp(property->name, "URL") == 0) {
      entity = kRCURLEntity; identifiers = urls; primary = &primaryURL;
    } else if (!strcasecmp(property->name,"X-ABDATE")) {
      entity=@"com.apple.contacts.Date"; identifiers=dates;
    } else if (!strcasecmp(property->name,"X-ABRELATEDNAMES")) {
      entity=@"com.apple.contacts.Related Name"; identifiers=related;
    } else if (!strcasecmp(property->name,"IMPP") || RCLegacyIMService(property->name)) {
      entity=@"com.apple.contacts.IM"; identifiers=ims;
    }
    if (entity != nil && !RCPushChild(context, contactIdentifier,
        contactSyncIdentifier, &document, property, entity, identifiers,
        primary, error)) {
      RCVCardDocumentClear(&document);
      return 0;
    }
  }
#define RC_SET_RELATIONSHIP(key, values) do { \
    if ([(values) count] != 0) [contact setObject:(values) forKey:(key)]; \
  } while (0)
  RC_SET_RELATIONSHIP(@"phone numbers", phones);
  RC_SET_RELATIONSHIP(@"email addresses", emails);
  RC_SET_RELATIONSHIP(@"street addresses", addresses);
  RC_SET_RELATIONSHIP(@"URLs", urls);
  RC_SET_RELATIONSHIP(@"dates",dates); RC_SET_RELATIONSHIP(@"related names",related); RC_SET_RELATIONSHIP(@"IMs",ims);
#undef RC_SET_RELATIONSHIP
  if (primaryPhone != nil) [contact setObject:[NSArray arrayWithObject:primaryPhone]
                                      forKey:@"primary phone number"];
  if (primaryEmail != nil) [contact setObject:[NSArray arrayWithObject:primaryEmail]
                                      forKey:@"primary email address"];
  if (primaryAddress != nil) [contact setObject:[NSArray arrayWithObject:primaryAddress]
                                        forKey:@"primary street address"];
  if (primaryURL != nil) [contact setObject:[NSArray arrayWithObject:primaryURL]
                                    forKey:@"primary URL"];
  [context->records setObject:contact forKey:contactSyncIdentifier];
  context->recordCount++;
  RCVCardDocumentClear(&document);
  return 1;
}

static int RCSyncServicesPushContactsForClient(
    RCContactStore *store, const char *clientDescriptionPath,
    NSString *clientIdentifier, long *recordCount, RCError *error)
{
  NSArray *entities = [NSArray arrayWithObjects:kRCContactEntity, kRCDateEntity,
      kRCEmailEntity, kRCGroupEntity, kRCSmartGroupEntity, kRCIMEntity,
      kRCPhoneEntity, kRCRelatedNameEntity, kRCAddressEntity, kRCURLEntity, nil];
  NSMutableArray *pullEntities = [NSMutableArray array];
  NSString *descriptionPath = RCString(clientDescriptionPath);
  ISyncManager *manager;
  ISyncClient *client;
  ISyncSession *session = nil;
  RCSyncExportContext context;
  long long generation, publishedGeneration;
  int success = 0;

  RCErrorClear(error);
  if (recordCount != NULL) *recordCount = 0;
  if (store == NULL || descriptionPath == nil) {
    RCErrorSet(error, 1, "Sync Services configuration is incomplete");
    return 0;
  }
  @try {
    if (!RCContactStoreGetPublicationState(store, &generation,
                                           &publishedGeneration, error)) return 0;
    if (generation == 0) {
      RCErrorSet(error, 1, "Contact mirror has no complete inventory yet");
      return 0;
    }
    /* Assemble the complete graph before touching Sync Services. A corrupt
       cached body or missing child identity must not publish a partial graph.
       Stable IDs and the unacknowledged generation make interrupted sessions
       replayable, including when the next network attempt fails. */
    memset(&context, 0, sizeof(context));
    context.store = store;
    context.records = [NSMutableDictionary dictionary];
    if (!RCContactStoreForEachAvailableContact(store, RCExportContact,
                                               &context, error)) return 0;
    RCWriteJournal journal=RCContactStoreWriteJournal(store);
    NSDictionary *aliased=RCTwoWayApplyAliases(&journal,context.records,error);
    if (!aliased) return 0;
    [context.records setDictionary:aliased];
    manager = [ISyncManager sharedManager];
    if (![manager isEnabled]) {
      RCErrorSet(error, 1, "Sync Services is disabled or unavailable");
      return 0;
    }
    client = [manager registerClientWithIdentifier:clientIdentifier
        descriptionFilePath:descriptionPath];
    if (client == nil) {
      RCErrorSet(error, 1, "Could not register the Sync Services client");
      return 0;
    }
    [client setEnabled:YES forEntityNames:entities];
    session = RCBeginSession(client,entities);
    if (session == nil) {
      RCErrorSet(error, 1, "Could not begin a Sync Services session");
      return 0;
    }
    /* Address Book's entities form one object graph. Sync Services requires
       related entities to use the same slow/fast mode, even when this client
       has no records for some of those entities. */
    [session clientWantsToPushAllRecordsForEntityNames:entities];
    {
      NSEnumerator *keys = [context.records keyEnumerator];
      NSString *key;
      while ((key = [keys nextObject]) != nil) {
        NSDictionary *record = [context.records objectForKey:key];
        if (![session shouldPushChangesForEntityName:
                [record objectForKey:ISyncRecordEntityNameKey]]) {
          RCErrorSet(error, 1, "Sync Services did not permit the contact push");
          goto finished;
        }
        RCSessionPush(session,record,key);
      }
    }
    {
      NSEnumerator *enumerator = [entities objectEnumerator];
      NSString *entity;
      while ((entity = [enumerator nextObject]) != nil) {
        if ([session shouldPullChangesForEntityName:entity]) {
          [pullEntities addObject:entity];
        }
      }
    }
    /* Push-only sessions must also enter the merge phase and check its result. */
    if (!RCPrepareToPull(session,pullEntities)) {
      RCErrorSet(error, 1, "Sync Services could not merge contact changes");
      goto finished;
    }
    if ([pullEntities count] != 0) {
      {
        NSEnumerator *changes =
            [session changeEnumeratorForEntityNames:pullEntities];
        ISyncChange *change;
        while ((change = [changes nextObject]) != nil) {
          if ([change type] != ISyncChangeTypeDelete) {
            [session clientRefusedChangesForRecordWithIdentifier:
                [change recordIdentifier]];
          }
        }
      }
      [session clientCommittedAcceptedChanges];
    }
    [session finishSyncing];
    session = nil;
    if (!RCContactStoreMarkPublished(store, generation, error)) goto finished;
    if (recordCount != NULL) *recordCount = context.recordCount;
    success = 1;
  }
  @catch (NSException *exception) {
    RCErrorSet(error, 1, "Sync Services exception: %s",
        [[exception name] UTF8String] != NULL ?
        [[exception name] UTF8String] : "unknown error");
  }

finished:
  if (session != nil) {
    @try { [session cancelSyncing]; }
    @catch (NSException *cancelException) {
      RCLogger(RCLogWarning, "Contacts", "Apply", @"Could not cancel Sync Services session: %@", [cancelException name]);
    }
  }
  return success;
}

int RCSyncServicesPushContacts(RCContactStore *store,
                               const char *clientDescriptionPath,
                               long *recordCount, RCError *error)
{
  return RCSyncServicesPushContactsForClient(store, clientDescriptionPath,
      store == NULL ? nil : RCContactSyncClientIdentifier(
          RCString(RCContactStoreSyncIdentifier(store))), recordCount, error);
}

int RCSyncServicesPushTestContacts(RCContactStore *store,
                                   const char *clientDescriptionPath,
                                   long *recordCount, RCError *error)
{
  return RCSyncServicesPushContactsForClient(store, clientDescriptionPath,
      kRCTestClientIdentifier, recordCount, error);
}

int RCSyncServicesUnregisterTestClient(RCError *error)
{
  ISyncManager *manager;
  ISyncClient *client;

  RCErrorClear(error);
  @try {
    manager = [ISyncManager sharedManager];
    if (![manager isEnabled]) {
      RCErrorSet(error, 1, "Sync Services is disabled or unavailable");
      return 0;
    }
    client = [manager clientWithIdentifier:kRCTestClientIdentifier];
    if (client != nil) [manager unregisterClient:client];
  }
  @catch (NSException *exception) {
    const char *reason = [[exception name] UTF8String];
    RCErrorSet(error, 1, "Sync Services exception: %s",
               reason != NULL ? reason : "unknown error");
    return 0;
  }
  return 1;
}

/* Reuse the production forward mapper for two-way comparison and validation. */
NSDictionary *RCContactNativeGraph(RCContactStore *store, long long identifier,
    const char *syncID, NSData *body, RCError *error)
{
  RCSyncExportContext context;
  memset(&context,0,sizeof(context));
  context.store=store; context.records=[NSMutableDictionary dictionary];
  return RCExportContact(identifier,syncID,[body bytes],[body length],&context,error) ? context.records : nil;
}

NSDictionary *RCContactNativeGraphForPaths(NSData *body, NSDictionary *paths, RCError *error)
{
  return RCContactNativeGraphWithPhotoCache(NULL,body,paths,nil,nil,error);
}
NSDictionary *RCContactNativeGraphWithPhotoCache(RCContactStore *store, NSData *body, NSDictionary *paths,
    NSString *href, NSString *etag, RCError *error)
{
  RCSyncExportContext context;
  RCVCardDocument doc;
  NSMutableDictionary *identities=[NSMutableDictionary dictionary], *counts=[NSMutableDictionary dictionary];
  size_t i;
  if (!RCVCardParse([body bytes],[body length],&doc,error)) return nil;
  for(i=0;i<doc.propertyCount;i++) {
    NSString *name=RCContactPathName(doc.properties[i].name);
    if ([name isEqual:@"TEL"] || [name isEqual:@"EMAIL"] || [name isEqual:@"ADR"] || [name isEqual:@"URL"] || [name isEqual:@"X-ABDATE"] || [name isEqual:@"X-ABRELATEDNAMES"] || [name isEqual:@"IMPP"]) {
      int n=[[counts objectForKey:name] intValue];
      NSString *identifier=[paths objectForKey:[NSString stringWithFormat:@"%@:%d",name,n]];
      [counts setObject:[NSNumber numberWithInt:n+1] forKey:name];
      if (identifier) [identities setObject:identifier forKey:[NSNumber numberWithInt:doc.properties[i].position]];
    }
  }
  RCVCardDocumentClear(&doc);
  memset(&context,0,sizeof(context)); context.records=[NSMutableDictionary dictionary]; context.propertyIdentities=identities;
  context.store=store; context.photoHref=href; context.photoETag=etag;
  if (!RCExportContact(0,"validation",[body bytes],[body length],&context,error)) return nil;
  return context.records;
}
