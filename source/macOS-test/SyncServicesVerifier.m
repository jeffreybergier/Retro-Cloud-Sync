#import <AddressBook/AddressBook.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>

static NSString * const kRCAlphaName = @"RCSSTestAlpha";
static NSString * const kRCBetaName = @"RCSSTestBeta";

static NSArray *RCMatchingPeople(ABAddressBook *addressBook, NSString *firstName)
{
  NSMutableArray *matches = [NSMutableArray array];
  NSEnumerator *enumerator = [[addressBook people] objectEnumerator];
  ABPerson *person;

  while ((person = [enumerator nextObject]) != nil) {
    if ([[person valueForProperty:kABFirstNameProperty]
            isEqualToString:firstName]) {
      [matches addObject:person];
    }
  }
  return matches;
}

static BOOL RCMultiValueContains(ABPerson *person, NSString *property,
                                 NSString *wantedValue)
{
  ABMultiValue *values = [person valueForProperty:property];
  NSUInteger index;

  if (![values isKindOfClass:[ABMultiValue class]]) return NO;
  for (index = 0; index < [values count]; index++) {
    id value = [values valueAtIndex:index];
    if ([value isEqual:wantedValue] ||
        [[value description] isEqualToString:wantedValue]) return YES;
  }
  return NO;
}

static BOOL RCAddressMatches(ABPerson *person, NSString *street,
                             NSString *city, NSString *state,
                             NSString *postalCode)
{
  ABMultiValue *values = [person valueForProperty:kABAddressProperty];
  NSUInteger index;

  if (![values isKindOfClass:[ABMultiValue class]]) return NO;
  for (index = 0; index < [values count]; index++) {
    NSDictionary *address = [values valueAtIndex:index];
    if ([address isKindOfClass:[NSDictionary class]] &&
        [[address objectForKey:kABAddressStreetKey] isEqualToString:street] &&
        [[address objectForKey:kABAddressCityKey] isEqualToString:city] &&
        [[address objectForKey:kABAddressStateKey] isEqualToString:state] &&
        [[address objectForKey:kABAddressZIPKey]
            isEqualToString:postalCode]) return YES;
  }
  return NO;
}

static BOOL RCVerifyInitial(ABAddressBook *addressBook)
{
  NSArray *alphaMatches = RCMatchingPeople(addressBook, kRCAlphaName);
  NSArray *betaMatches = RCMatchingPeople(addressBook, kRCBetaName);
  ABPerson *alpha;
  ABPerson *beta;

  if ([alphaMatches count] != 1 || [betaMatches count] != 1) return NO;
  alpha = [alphaMatches objectAtIndex:0];
  beta = [betaMatches objectAtIndex:0];
  return [[alpha valueForProperty:kABLastNameProperty]
              isEqualToString:@"Fixture"] &&
      [[alpha valueForProperty:kABOrganizationProperty]
              isEqualToString:@"Retro Cloud Test"] &&
      [[alpha valueForProperty:kABDepartmentProperty]
              isEqualToString:@"Initial"] &&
      [[alpha valueForProperty:kABJobTitleProperty]
              isEqualToString:@"Initial Tester"] &&
      RCMultiValueContains(alpha, kABPhoneProperty, @"+1-555-0101") &&
      RCMultiValueContains(alpha, kABEmailProperty,
                           @"initial-alpha@retrocloudsync.invalid") &&
      RCMultiValueContains(alpha, kABURLsProperty,
                           @"https://initial.invalid/alpha") &&
      RCAddressMatches(alpha, @"1 Static Way", @"Testville", @"CA",
                       @"90001") &&
      RCMultiValueContains(beta, kABEmailProperty,
                           @"beta@retrocloudsync.invalid");
}

static BOOL RCVerifyUpdated(ABAddressBook *addressBook)
{
  NSArray *alphaMatches = RCMatchingPeople(addressBook, kRCAlphaName);
  ABPerson *alpha;

  if ([alphaMatches count] != 1 ||
      [RCMatchingPeople(addressBook, kRCBetaName) count] != 0) return NO;
  alpha = [alphaMatches objectAtIndex:0];
  return [[alpha valueForProperty:kABDepartmentProperty]
              isEqualToString:@"Updated"] &&
      [[alpha valueForProperty:kABJobTitleProperty]
              isEqualToString:@"Updated Tester"] &&
      RCMultiValueContains(alpha, kABPhoneProperty, @"+1-555-0199") &&
      RCMultiValueContains(alpha, kABEmailProperty,
                           @"updated-alpha@retrocloudsync.invalid") &&
      RCMultiValueContains(alpha, kABURLsProperty,
                           @"https://updated.invalid/alpha") &&
      RCAddressMatches(alpha, @"99 Changed Road", @"New Testville", @"NY",
                       @"10001");
}

static BOOL RCVerifyEmpty(ABAddressBook *addressBook)
{
  return [RCMatchingPeople(addressBook, kRCAlphaName) count] == 0 &&
      [RCMatchingPeople(addressBook, kRCBetaName) count] == 0;
}

static BOOL RCWriteBaseline(ABAddressBook *addressBook, NSString *path)
{
  NSMutableArray *identifiers = [NSMutableArray array];
  NSEnumerator *enumerator = [[addressBook people] objectEnumerator];
  ABPerson *person;

  if (!RCVerifyEmpty(addressBook)) return NO;
  while ((person = [enumerator nextObject]) != nil) {
    NSString *identifier = [person uniqueId];
    if (identifier != nil) [identifiers addObject:identifier];
  }
  return [identifiers writeToFile:path atomically:YES];
}

static BOOL RCVerifyBaseline(ABAddressBook *addressBook, NSString *path)
{
  NSArray *identifiers = [NSArray arrayWithContentsOfFile:path];
  NSEnumerator *enumerator;
  NSString *identifier;

  if (identifiers == nil || !RCVerifyEmpty(addressBook)) return NO;
  enumerator = [identifiers objectEnumerator];
  while ((identifier = [enumerator nextObject]) != nil) {
    if ([addressBook recordForUniqueId:identifier] == nil) return NO;
  }
  return YES;
}

int main(int argc, char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  ABAddressBook *addressBook = [ABAddressBook sharedAddressBook];
  NSString *command;
  BOOL success = NO;

  if (argc < 2 || addressBook == nil) {
    fprintf(stderr, "usage: %s initial|updated|empty|snapshot|baseline [FILE]\n",
            argv[0]);
    [pool release];
    return 2;
  }
  command = [NSString stringWithUTF8String:argv[1]];
  if ([command isEqualToString:@"initial"] && argc == 2) {
    success = RCVerifyInitial(addressBook);
  } else if ([command isEqualToString:@"updated"] && argc == 2) {
    success = RCVerifyUpdated(addressBook);
  } else if ([command isEqualToString:@"empty"] && argc == 2) {
    success = RCVerifyEmpty(addressBook);
  } else if ([command isEqualToString:@"snapshot"] && argc == 3) {
    success = RCWriteBaseline(addressBook,
        [NSString stringWithUTF8String:argv[2]]);
  } else if ([command isEqualToString:@"baseline"] && argc == 3) {
    success = RCVerifyBaseline(addressBook,
        [NSString stringWithUTF8String:argv[2]]);
  } else {
    fprintf(stderr, "usage: %s initial|updated|empty|snapshot|baseline [FILE]\n",
            argv[0]);
    [pool release];
    return 2;
  }

  if (!success) fprintf(stderr, "Address Book verification failed: %s\n", argv[1]);
  [pool release];
  return success ? 0 : 1;
}
