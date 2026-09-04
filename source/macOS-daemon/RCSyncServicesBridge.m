#import "RCSyncServicesBridge.h"

#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>

#include "RCVCard.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

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

typedef struct {
  RCContactStore *store;
  ISyncSession *session;
  long recordCount;
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

  if (!RCContactStoreCopyPropertySyncIdentifier(context->store,
      contactIdentifier, property->position, &storedIdentifier, error)) return 0;
  recordIdentifier = RCPrefixedIdentifier(@"property-", storedIdentifier);
  free(storedIdentifier);
  if (recordIdentifier == nil) {
    RCErrorSet(error, 1, "A cached contact property has no sync identity");
    return 0;
  }
  record = [NSMutableDictionary dictionaryWithObjectsAndKeys:
      entity, ISyncRecordEntityNameKey,
      [NSArray arrayWithObject:contactSyncIdentifier], @"contact", nil];
  [record setObject:RCPropertyType(property, entity) forKey:@"type"];
  label = RCGroupedValue(document, property, "X-ABLabel");
  if ([label length] != 0) [record setObject:label forKey:@"label"];
  if ([entity isEqualToString:kRCAddressEntity]) {
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
  [context->session pushChangesFromRecord:record withIdentifier:recordIdentifier];
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
  RCSyncExportContext *context = (RCSyncExportContext *)opaqueContext;
  RCVCardDocument document;
  NSString *contactSyncIdentifier;
  NSMutableDictionary *contact;
  NSMutableArray *phones = [NSMutableArray array];
  NSMutableArray *emails = [NSMutableArray array];
  NSMutableArray *addresses = [NSMutableArray array];
  NSMutableArray *urls = [NSMutableArray array];
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
#undef RC_SET_RELATIONSHIP
  if (primaryPhone != nil) [contact setObject:[NSArray arrayWithObject:primaryPhone]
                                      forKey:@"primary phone number"];
  if (primaryEmail != nil) [contact setObject:[NSArray arrayWithObject:primaryEmail]
                                      forKey:@"primary email address"];
  if (primaryAddress != nil) [contact setObject:[NSArray arrayWithObject:primaryAddress]
                                        forKey:@"primary street address"];
  if (primaryURL != nil) [contact setObject:[NSArray arrayWithObject:primaryURL]
                                    forKey:@"primary URL"];
  [context->session pushChangesFromRecord:contact
                           withIdentifier:contactSyncIdentifier];
  context->recordCount++;
  RCVCardDocumentClear(&document);
  return 1;
}

int RCSyncServicesPushContacts(RCContactStore *store,
                               const char *clientDescriptionPath,
                               long *recordCount, RCError *error)
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
  int success = 0;

  RCErrorClear(error);
  if (recordCount != NULL) *recordCount = 0;
  if (store == NULL || descriptionPath == nil) {
    RCErrorSet(error, 1, "Sync Services configuration is incomplete");
    return 0;
  }
  @try {
    manager = [ISyncManager sharedManager];
    if (![manager isEnabled]) {
      RCErrorSet(error, 1, "Sync Services is disabled or unavailable");
      return 0;
    }
    client = [manager registerClientWithIdentifier:
        @"com.retrocloudsync.contacts.v1"
        descriptionFilePath:descriptionPath];
    if (client == nil) {
      RCErrorSet(error, 1, "Could not register the Sync Services client");
      return 0;
    }
    [client setEnabled:YES forEntityNames:entities];
    session = [ISyncSession beginSessionWithClient:client entityNames:entities
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:60.0]];
    if (session == nil) {
      RCErrorSet(error, 1, "Could not begin a Sync Services session");
      return 0;
    }
    /* Address Book's entities form one object graph. Sync Services requires
       related entities to use the same slow/fast mode, even when this client
       has no records for some of those entities. */
    [session clientWantsToPushAllRecordsForEntityNames:entities];
    memset(&context, 0, sizeof(context));
    context.store = store;
    context.session = session;
    if ([session shouldPushChangesForEntityName:kRCContactEntity] &&
        !RCContactStoreForEachAvailableContact(store, RCExportContact,
                                               &context, error)) goto finished;
    {
      NSEnumerator *enumerator = [entities objectEnumerator];
      NSString *entity;
      while ((entity = [enumerator nextObject]) != nil) {
        if ([session shouldPullChangesForEntityName:entity]) {
          [pullEntities addObject:entity];
        }
      }
    }
    if ([pullEntities count] != 0) {
      if (![session prepareToPullChangesForEntityNames:pullEntities
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:60.0]]) {
        RCErrorSet(error, 1, "Sync Services could not prepare contact changes");
        goto finished;
      }
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
    if (recordCount != NULL) *recordCount = context.recordCount;
    success = 1;
  }
  @catch (NSException *exception) {
    RCErrorSet(error, 1, "Sync Services exception: %s",
        [[exception reason] UTF8String] != NULL ?
        [[exception reason] UTF8String] : "unknown error");
  }

finished:
  if (session != nil) {
    @try { [session cancelSyncing]; }
    @catch (NSException *cancelException) {
      NSLog(@"Could not cancel Sync Services session (%@): %@",
            [cancelException name], [cancelException reason]);
    }
  }
  return success;
}
