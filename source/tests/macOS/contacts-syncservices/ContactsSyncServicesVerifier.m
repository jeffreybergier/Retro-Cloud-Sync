#import <AddressBook/AddressBook.h>
#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#import "../../../macOS-daemon/RCContactSyncClient.h"
#include <stdio.h>
#include <string.h>

static NSString * const kRCTestClient = @"com.retrocloudsync.contacts.test.v1";
static NSString * const kRCAlpha = @"RCSSTestAlpha";
static NSString * const kRCBeta = @"RCSSTestBeta";
#define CHECK(condition, message) do { if (!(condition)) { \
  fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); return NO; \
} } while (0)

static BOOL IsTestName(id name)
{
  return [name isEqual:kRCAlpha] || [name isEqual:kRCBeta];
}
static NSString *Entity(NSString *name)
{
  return [@"com.apple.contacts." stringByAppendingString:name];
}
static NSArray *Entities(void)
{
  return [NSArray arrayWithObjects:Entity(@"Contact"), Entity(@"Phone Number"),
      Entity(@"Email Address"), Entity(@"Street Address"), Entity(@"URL"), nil];
}
static NSDictionary *Records(ISyncRecordSnapshot *snapshot, NSString *entity)
{
  return [snapshot recordsWithMatchingAttributes:
      [NSDictionary dictionaryWithObject:entity forKey:ISyncRecordEntityNameKey]];
}
static NSDictionary *People(ABAddressBook *book)
{
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  NSEnumerator *iterator = [[book people] objectEnumerator];
  ABPerson *person;
  while ((person = [iterator nextObject])) {
    NSString *name = [person valueForProperty:kABFirstNameProperty];
    if (IsTestName(name)) {
      if ([result objectForKey:name]) return nil;
      [result setObject:person forKey:name];
    }
  }
  return result;
}
static BOOL EqualValue(id actual, id expected)
{
  if (!expected) return !actual || ([actual respondsToSelector:@selector(length)] && ![actual length]);
  if ([actual isKindOfClass:[NSURL class]]) actual = [actual absoluteString];
  return [actual isEqual:expected];
}
static BOOL Field(ABPerson *person, NSString *key, id expected)
{
  if (EqualValue([person valueForProperty:key], expected)) return YES;
  fprintf(stderr, "FAIL: Address Book field %s differs\n", [key UTF8String]);
  return NO;
}
static BOOL Values(ABPerson *person, NSString *key, NSArray *expected)
{
  ABMultiValue *values = [person valueForProperty:key];
  NSMutableSet *remaining = [NSMutableSet setWithArray:expected];
  NSUInteger i;
  CHECK([values count] == [expected count], "Address Book child count (stale or duplicate value)");
  for (i = 0; i < [values count]; ++i) {
    id value = [values valueAtIndex:i];
    if ([value isKindOfClass:[NSURL class]]) value = [value absoluteString];
    CHECK([remaining containsObject:value], "Address Book unexpected/duplicate child value");
    [remaining removeObject:value];
  }
  return [remaining count] == 0;
}
static BOOL Birthday(id value)
{
  NSCalendarDate *date;
  CHECK([value isKindOfClass:[NSDate class]], "Birthday missing");
  date = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:[value timeIntervalSinceReferenceDate]];
  [date setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
  CHECK([date yearOfCommonEra] == 2001 && [date monthOfYear] == 2 &&
        [date dayOfMonth] == 3, "Birthday date changed");
  return YES;
}
static BOOL VerifyPeople(NSDictionary *people, NSString *phase)
{
  BOOL initial = [phase isEqual:@"initial"] || [phase isEqual:@"reordered"];
  BOOL empty = [phase isEqual:@"empty"];
  BOOL stripped = [phase isEqual:@"stripped"];
  ABPerson *alpha = [people objectForKey:kRCAlpha];
  ABPerson *beta = [people objectForKey:kRCBeta];
  NSArray *none = [NSArray array];
  CHECK(people != nil && [people count] == (empty ? 0 : initial ? 2 : 1), "Synthetic person count");
  if (empty) return YES;
  CHECK(alpha && Field(alpha, kABLastNameProperty, @"Fixture"), "Alpha identity");
  CHECK(Field(alpha, kABMiddleNameProperty, initial ? @"Renée" : nil) &&
      Field(alpha, kABTitleProperty, initial ? @"Dr." : nil) &&
      Field(alpha, kABSuffixProperty, initial ? @"Jr." : nil) &&
      Field(alpha, kABNicknameProperty, initial ? @"Étoile" : nil) &&
      Field(alpha, kABNoteProperty, initial ? @"Première ligne\n東京" : nil),
      "Names/Unicode/removed scalar fields");
  CHECK(Field(alpha, kABOrganizationProperty, stripped ? nil : @"Retro Cloud Test") &&
      Field(alpha, kABDepartmentProperty, stripped ? nil : initial ? @"Initial" : @"Updated") &&
      Field(alpha, kABJobTitleProperty, stripped ? nil : initial ? @"Initial Tester" : @"Updated Tester"),
      "Organization fields");
  CHECK(stripped ? Field(alpha, kABBirthdayProperty, nil) : Birthday([alpha valueForProperty:kABBirthdayProperty]), "Birthday");
  CHECK(Values(alpha, kABPhoneProperty, stripped ? none : initial ?
      [NSArray arrayWithObjects:@"+1-555-0102", @"+1-555-0101", nil] :
      [NSArray arrayWithObject:@"+1-555-0199"]), "Phone values");
  CHECK(Values(alpha, kABEmailProperty, stripped ? none : initial ?
      [NSArray arrayWithObjects:@"second-alpha@retrocloudsync.invalid", @"initial-alpha@retrocloudsync.invalid", nil] :
      [NSArray arrayWithObject:@"updated-alpha@retrocloudsync.invalid"]), "Email values");
  CHECK(Values(alpha, kABURLsProperty, stripped ? none : [NSArray arrayWithObject:
      initial ? @"https://initial.invalid/alpha" : @"https://updated.invalid/alpha"]), "URL values");
  {
    ABMultiValue *addresses = [alpha valueForProperty:kABAddressProperty];
    CHECK([addresses count] == (stripped ? 0 : 1), "Street address count");
    if (!stripped) {
      NSDictionary *address = [addresses valueAtIndex:0];
      CHECK(EqualValue([address objectForKey:kABAddressStreetKey], initial ? @"1 Static Way" : @"99 Changed Road") &&
          EqualValue([address objectForKey:kABAddressCityKey], initial ? @"Testville" : @"New Testville") &&
          EqualValue([address objectForKey:kABAddressStateKey], initial ? @"CA" : @"NY") &&
          EqualValue([address objectForKey:kABAddressZIPKey], initial ? @"90001" : @"10001") &&
          EqualValue([address objectForKey:kABAddressCountryKey], @"USA"), "Street address components");
      if (initial) CHECK(EqualValue([address objectForKey:kABAddressCountryCodeKey], @"us"), "Country code");
    }
  }
  CHECK(([[alpha valueForProperty:kABPersonFlags] intValue] & kABShowAsMask) == kABShowAsPerson, "Person display flag");
  if (initial) {
    CHECK(beta && Field(beta, kABOrganizationProperty, @"Retro Cloud Test Company") &&
        Values(beta, kABEmailProperty, [NSArray arrayWithObject:@"beta@retrocloudsync.invalid"]), "Beta company");
    CHECK(([[beta valueForProperty:kABPersonFlags] intValue] & kABShowAsMask) == kABShowAsCompany, "Company display flag");
  }
  return YES;
}

/* Record ownership before assertions, so failure cleanup can still detect
   children orphaned by a partially imported or malformed graph. */
static BOOL TrackRecords(ISyncRecordSnapshot *snapshot, NSString *path)
{
  NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:path];
  NSMutableDictionary *history;
  NSMutableSet *records, *owners;
  NSDictionary *contacts = Records(snapshot, Entity(@"Contact"));
  NSEnumerator *iterator = [contacts keyEnumerator];
  NSString *identifier;
  NSArray *relations = [NSArray arrayWithObjects:@"phone numbers", @"email addresses", @"street addresses", @"URLs", nil];
  CHECK(![[NSFileManager defaultManager] fileExistsAtPath:path] || old != nil, "Unreadable truth history");
  history = [NSMutableDictionary dictionaryWithDictionary:old ?: [NSDictionary dictionary]];
  records = [NSMutableSet setWithArray:[old objectForKey:@"records"] ?: [NSArray array]];
  owners = [NSMutableSet setWithArray:[old objectForKey:@"contacts"] ?: [NSArray array]];
  while ((identifier = [iterator nextObject])) {
    NSDictionary *contact = [contacts objectForKey:identifier];
    if (IsTestName([contact objectForKey:@"first name"])) {
      NSEnumerator *r = [relations objectEnumerator]; NSString *relation;
      [owners addObject:identifier]; [records addObject:identifier];
      while ((relation = [r nextObject])) [records addObjectsFromArray:[contact objectForKey:relation] ?: [NSArray array]];
    }
  }
  [history setObject:[records allObjects] forKey:@"records"];
  [history setObject:[owners allObjects] forKey:@"contacts"];
  CHECK([history writeToFile:path atomically:YES], "Save observed truth identities");
  return YES;
}

/* Compare both sides of every exported relationship against Address Book,
   including exact cardinality, types, labels and preferred entries. Keep the
   IDs seen in earlier phases so deleted contacts/children cannot become orphans. */
static BOOL VerifyTruth(ISyncRecordSnapshot *snapshot, NSDictionary *people,
                        NSString *phase, NSString *historyPath)
{
  NSDictionary *contacts = Records(snapshot, Entity(@"Contact"));
  NSMutableSet *active = [NSMutableSet set];
  NSMutableSet *names = [NSMutableSet set];
  NSMutableSet *owners = [NSMutableSet set];
  NSDictionary *history = [NSDictionary dictionaryWithContentsOfFile:historyPath];
  NSMutableDictionary *identities = [NSMutableDictionary dictionaryWithDictionary:[history objectForKey:@"identities"] ?: [NSDictionary dictionary]];
  NSMutableSet *previous = [NSMutableSet setWithArray:[history objectForKey:@"records"] ?: [NSArray array]];
  NSMutableSet *previousOwners = [NSMutableSet setWithArray:[history objectForKey:@"contacts"] ?: [NSArray array]];
  NSArray *relations = [NSArray arrayWithObjects:@"phone numbers", @"email addresses", @"street addresses", @"URLs", nil];
  NSArray *primaries = [NSArray arrayWithObjects:@"primary phone number", @"primary email address", @"primary street address", @"primary URL", nil];
  NSArray *childEntities = [NSArray arrayWithObjects:Entity(@"Phone Number"), Entity(@"Email Address"), Entity(@"Street Address"), Entity(@"URL"), nil];
  NSArray *properties = [NSArray arrayWithObjects:kABPhoneProperty, kABEmailProperty, kABAddressProperty, kABURLsProperty, nil];
  NSArray *scalarKeys = [NSArray arrayWithObjects:@"first name", @"last name", @"middle name", @"title", @"suffix", @"nickname", @"notes", @"company name", @"department", @"job title", nil];
  NSArray *scalarProperties = [NSArray arrayWithObjects:kABFirstNameProperty, kABLastNameProperty, kABMiddleNameProperty, kABTitleProperty, kABSuffixProperty, kABNicknameProperty, kABNoteProperty, kABOrganizationProperty, kABDepartmentProperty, kABJobTitleProperty, nil];
  NSEnumerator *iterator = [contacts keyEnumerator];
  NSString *identifier;
  BOOL initial = [phase isEqual:@"initial"] || [phase isEqual:@"reordered"];
  while ((identifier = [iterator nextObject])) {
    NSDictionary *contact = [contacts objectForKey:identifier];
    NSString *name = [contact objectForKey:@"first name"];
    ABPerson *person;
    NSUInteger i, j;
    if (!IsTestName(name)) continue;
    person = [people objectForKey:name];
    CHECK(person != nil && ![names containsObject:name], "Unexpected/duplicate synthetic contact in truth");
    [names addObject:name];
    {
      NSArray *identity = [NSArray arrayWithObjects:identifier, [person uniqueId], nil];
      CHECK(![identities objectForKey:name] || [[identities objectForKey:name] isEqual:identity], "Synthetic contact identity changed across exports");
      [identities setObject:identity forKey:name];
    }
    [owners addObject:identifier];
    [active addObject:identifier];
    for (i = 0; i < [scalarKeys count]; ++i)
      CHECK(EqualValue([contact objectForKey:[scalarKeys objectAtIndex:i]],
          [person valueForProperty:[scalarProperties objectAtIndex:i]]), "Truth scalar differs from Address Book");
    if ([person valueForProperty:kABBirthdayProperty]) CHECK(Birthday([contact objectForKey:@"birthday"]), "Truth birthday");
    else CHECK(![contact objectForKey:@"birthday"], "Removed birthday remains in truth");
    CHECK(EqualValue([contact objectForKey:@"display as company"], [name isEqual:kRCBeta] ? @"company" : @"person"), "Truth display flag");
    for (i = 0; i < [relations count]; ++i) {
      NSArray *ids = [contact objectForKey:[relations objectAtIndex:i]];
      ABMultiValue *values = [person valueForProperty:[properties objectAtIndex:i]];
      NSMutableSet *matched = [NSMutableSet set];
      CHECK([ids count] == [values count], "Truth relationship cardinality");
      for (j = 0; j < [ids count]; ++j) {
        NSString *childID = [ids objectAtIndex:j];
        NSDictionary *child = [[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:childID]] objectForKey:childID];
        NSUInteger k;
        BOOL found = NO;
        CHECK(![active containsObject:childID], "Duplicate/shared synthetic child");
        [active addObject:childID];
        CHECK(EqualValue([child objectForKey:ISyncRecordEntityNameKey], [childEntities objectAtIndex:i]) &&
            [[child objectForKey:@"contact"] isEqual:[NSArray arrayWithObject:identifier]], "Child entity/back-reference");
        for (k = 0; k < [values count]; ++k) {
          id value = [values valueAtIndex:k];
          NSNumber *index = [NSNumber numberWithUnsignedInt:(unsigned int)k];
          NSString *type;
          NSString *label;
          NSString *abLabel;
          if ([matched containsObject:index]) continue;
          if (i == 2) {
            if (!EqualValue([child objectForKey:@"street"], [value objectForKey:kABAddressStreetKey])) continue;
            CHECK(EqualValue([child objectForKey:@"city"], [value objectForKey:kABAddressCityKey]) &&
                EqualValue([child objectForKey:@"state"], [value objectForKey:kABAddressStateKey]) &&
                EqualValue([child objectForKey:@"postal code"], [value objectForKey:kABAddressZIPKey]) &&
                EqualValue([child objectForKey:@"country"], [value objectForKey:kABAddressCountryKey]), "Truth street components");
            if (initial) CHECK(EqualValue([child objectForKey:@"country code"], @"us"), "Truth country code");
          } else if (!EqualValue([child objectForKey:@"value"], value)) continue;
          type = (i == 0) ? ([value isEqual:@"+1-555-0102"] ? @"home" : @"mobile") :
              (i == 1 && ([name isEqual:kRCBeta] || [value hasPrefix:@"second-"])) ? @"home" : @"work";
          label = initial && i == 0 && [value isEqual:@"+1-555-0101"] ? @"Test Mobile" : nil;
          if (label) type = @"other";
          CHECK(EqualValue([child objectForKey:@"type"], type), "Truth child type");
          CHECK(EqualValue([child objectForKey:@"label"], label), "Truth custom label");
          abLabel = label ? label : ([type isEqual:@"home"] ? kABHomeLabel :
              [type isEqual:@"mobile"] ? kABPhoneMobileLabel : kABWorkLabel);
          if (!EqualValue([values labelAtIndex:k], abLabel))
            NSLog(@"Synthetic %@ value %@: expected label %@, got %@", [properties objectAtIndex:i], value, abLabel, [values labelAtIndex:k]);
          CHECK(EqualValue([values labelAtIndex:k], abLabel), "Address Book label");
          if ([name isEqual:kRCAlpha] && i < 2 &&
              ((i == 0 && ![value isEqual:@"+1-555-0102"]) || (i == 1 && ![value hasPrefix:@"second-"]))) {
            CHECK([[contact objectForKey:[primaries objectAtIndex:i]] isEqual:[NSArray arrayWithObject:childID]], "Truth preferred child");
            CHECK(EqualValue([values primaryIdentifier], [values identifierAtIndex:k]), "Address Book preferred child");
          }
          [matched addObject:index]; found = YES; break;
        }
        CHECK(found, "Truth contains a stale/unexpected child value");
      }
      if (![ids count]) CHECK(![[contact objectForKey:[primaries objectAtIndex:i]] count], "Dangling primary relationship");
    }
  }
  CHECK([owners count] == [people count], "Truth synthetic contact count");
  [previousOwners unionSet:owners];
  {
    NSUInteger i;
    for (i = 0; i < [childEntities count]; ++i) {
      NSDictionary *children = Records(snapshot, [childEntities objectAtIndex:i]);
      iterator = [children keyEnumerator];
      while ((identifier = [iterator nextObject])) {
        NSArray *parents = [[children objectForKey:identifier] objectForKey:@"contact"];
        NSEnumerator *p = [parents objectEnumerator]; NSString *parent;
        while ((parent = [p nextObject])) if ([previousOwners containsObject:parent])
          CHECK([active containsObject:identifier], "Orphaned synthetic child in truth");
      }
    }
  }
  iterator = [previous objectEnumerator];
  while ((identifier = [iterator nextObject])) if (![active containsObject:identifier])
    CHECK(![[snapshot recordsWithIdentifiers:[NSArray arrayWithObject:identifier]] objectForKey:identifier], "Deleted synthetic record remains in truth");
  [previous unionSet:active];
  CHECK(([[NSDictionary dictionaryWithObjectsAndKeys:[previous allObjects], @"records",
      [previousOwners allObjects], @"contacts", identities, @"identities", nil] writeToFile:historyPath atomically:YES]), "Save truth identity history");
  return YES;
}

/* Preserve property contents, multivalue IDs/labels/primary selections, images,
   and group membership. Modification timestamps are bookkeeping, not content. */
static id PropertyValue(id value)
{
  if ([value isKindOfClass:[ABMultiValue class]]) {
    NSMutableArray *items = [NSMutableArray array]; NSUInteger i;
    for (i = 0; i < [value count]; ++i)
      [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:
          PropertyValue([value valueAtIndex:i]), @"value", [value labelAtIndex:i] ?: @"", @"label",
          [value identifierAtIndex:i], @"identifier", nil]];
    return [NSDictionary dictionaryWithObjectsAndKeys:items, @"items", [value primaryIdentifier] ?: @"", @"primary", nil];
  }
  return value;
}
static NSDictionary *Baseline(ABAddressBook *book)
{
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  NSMutableArray *records = [NSMutableArray arrayWithArray:[book people]];
  NSEnumerator *iterator; ABRecord *record;
  [records addObjectsFromArray:[book groups]];
  iterator = [records objectEnumerator];
  while ((record = [iterator nextObject])) {
    NSMutableDictionary *content = [NSMutableDictionary dictionary];
    NSEnumerator *properties = [[[record class] properties] objectEnumerator]; NSString *key;
    if ([record isKindOfClass:[ABPerson class]] && IsTestName([record valueForProperty:kABFirstNameProperty])) continue;
    while ((key = [properties nextObject])) {
      id value = [record valueForProperty:key];
      if (value && ![key isEqual:kABModificationDateProperty]) [content setObject:PropertyValue(value) forKey:key];
    }
    if ([record isKindOfClass:[ABPerson class]]) {
      NSData *image = [(ABPerson *)record imageData];
      if (image) [content setObject:image forKey:@"test:image"];
    } else {
      NSMutableArray *members = [NSMutableArray array], *groups = [NSMutableArray array];
      NSEnumerator *items = [[(ABGroup *)record members] objectEnumerator]; ABRecord *item;
      while ((item = [items nextObject])) [members addObject:[item uniqueId]];
      items = [[(ABGroup *)record subgroups] objectEnumerator];
      while ((item = [items nextObject])) [groups addObject:[item uniqueId]];
      [content setObject:[members sortedArrayUsingSelector:@selector(compare:)] forKey:@"test:members"];
      [content setObject:[groups sortedArrayUsingSelector:@selector(compare:)] forKey:@"test:subgroups"];
    }
    [result setObject:content forKey:[record uniqueId]];
  }
  return result;
}
static void Diagnose(ISyncRecordSnapshot *snapshot, NSDictionary *people)
{
  NSDictionary *contacts = Records(snapshot, Entity(@"Contact"));
  NSEnumerator *it = [contacts keyEnumerator]; NSString *identifier;
  NSLog(@"Synthetic Address Book people: %@", [people allKeys]);
  while ((identifier = [it nextObject])) {
    NSDictionary *record = [contacts objectForKey:identifier];
    if (IsTestName([record objectForKey:@"first name"])) {
      NSLog(@"Synthetic truth %@: %@", identifier, record);
      ABPerson *person = [people objectForKey:[record objectForKey:@"first name"]];
      NSLog(@"Synthetic Address Book phones=%@ emails=%@ addresses=%@ URLs=%@",
          [person valueForProperty:kABPhoneProperty], [person valueForProperty:kABEmailProperty],
          [person valueForProperty:kABAddressProperty], [person valueForProperty:kABURLsProperty]);
    }
  }
}
static BOOL VerifyAccountClient(NSString *description)
{
  NSString *account = @"00000000000000000000000000000001";
  NSString *identifier = RCContactSyncClientIdentifier(account);
  ISyncManager *manager = [ISyncManager sharedManager];
  ISyncClient *client = nil;
  BOOL ok = NO;
  CHECK([identifier hasSuffix:account] && [identifier length] * 4 <= 255 &&
      ![identifier isEqual:RCContactSyncClientIdentifier(@"00000000000000000000000000000002")],
      "Production contact client must be account-specific and fit Tiger's filename limit");
  CHECK([manager clientWithIdentifier:identifier] == nil,
      "Refusing to replace an existing synthetic account client");
  @try {
    client = [manager registerClientWithIdentifier:identifier descriptionFilePath:description];
    ok = client != nil && [manager clientWithIdentifier:identifier] != nil;
  } @finally {
    if (client != nil) [manager unregisterClient:client];
  }
  return ok && [manager clientWithIdentifier:identifier] == nil;
}

int main(int argc, char **argv)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  BOOL ok = NO;
  @try {
    ABAddressBook *book = [ABAddressBook sharedAddressBook];
    ISyncManager *manager = [ISyncManager sharedManager];
    NSString *command = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
    if (!book || ![manager isEnabled]) {
      fprintf(stderr, "Address Book/Sync Services unavailable\n");
      [pool release]; return 1;
    }
    if (argc == 2 && [command isEqual:@"unregistered"]) ok = [manager clientWithIdentifier:kRCTestClient] == nil;
    else if (argc == 3 && [command isEqual:@"client-registration"])
      ok = VerifyAccountClient([NSString stringWithUTF8String:argv[2]]);
    else if (argc == 3 && ([command isEqual:@"snapshot"] || [command isEqual:@"baseline"])) {
      NSString *path = [NSString stringWithUTF8String:argv[2]];
      NSDictionary *current = Baseline(book);
      if ([command isEqual:@"snapshot"]) ok = [current writeToFile:path atomically:YES];
      else {
        NSDictionary *before = [NSDictionary dictionaryWithContentsOfFile:path];
        NSEnumerator *it = [before keyEnumerator]; NSString *identifier;
        ok = before != nil;
        while ((identifier = [it nextObject])) if (![[before objectForKey:identifier] isEqual:[current objectForKey:identifier]]) {
          fprintf(stderr, "FAIL: Pre-existing Address Book record changed or disappeared\n"); ok = NO;
        }
      }
    } else if (argc == 3 && [[NSArray arrayWithObjects:@"initial", @"reordered", @"updated", @"stripped", @"empty", @"diagnose", nil] containsObject:command]) {
      ISyncRecordSnapshot *snapshot = [manager snapshotOfRecordsInTruthWithEntityNames:Entities() usingIdentifiersForClient:nil];
      NSDictionary *people = People(book);
      if (snapshot) ok = [command isEqual:@"diagnose"] ||
          (TrackRecords(snapshot, [NSString stringWithUTF8String:argv[2]]) &&
           VerifyPeople(people, command) && VerifyTruth(snapshot, people, command, [NSString stringWithUTF8String:argv[2]]));
      if (!ok || [command isEqual:@"diagnose"]) Diagnose(snapshot, people);
    } else fprintf(stderr, "usage: %s initial|reordered|updated|stripped|empty|diagnose HISTORY | snapshot|baseline FILE | unregistered\n", argv[0]);
  } @catch (NSException *exception) {
    fprintf(stderr, "Verifier exception: %s\n", [[exception reason] UTF8String]);
    ok = NO;
  }
  [pool release];
  return ok ? 0 : 1;
}
