#import "RCRecordGraph.h"
#import "RCMacNativeBackend.h"
#import "RCNativeSystemStore.h"
#import "RCAutorelease.h"
#import "RCLogger.h"
#import "RCSyncFieldScope.h"
#import "RCCalendarTime.h"
#if defined(__LP64__)
#import <EventKit/EventKit.h>
#import <AddressBook/AddressBook.h>
#include <openssl/sha.h>
@interface RCMacNativeStore : RCNativeSystemStore { id book_; }
@end


/* Only modern slices use EventKit. Ask once while permission is pending;
   repeated store initialization with the deprecated 10.8 initializer queues
   repeated dialogs on Mavericks. Never inspect an unauthorized empty store. */
static EKEventStore *eventRequester=nil;
static BOOL eventRequested=NO;
static BOOL RCEventAccess(RCError *error)
{
  EKAuthorizationStatus status=[EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
  if(status==EKAuthorizationStatusAuthorized) return YES;
  if(status==EKAuthorizationStatusNotDetermined) {
    @synchronized([EKEventStore class]) {
      if(!eventRequested) {
        eventRequested=YES;
        eventRequester=[[EKEventStore alloc] init];
        @try {
          [eventRequester requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted,NSError *failure) {
            (void)granted; (void)failure;
            @synchronized([EKEventStore class]) { [eventRequester release]; eventRequester=nil; }
          }];
        } @catch(NSException *exception) {
          [eventRequester release]; eventRequester=nil; @throw;
        }
      }
    }
  }
  RCErrorSet(error,1,"Calendar access is pending or denied; allow rCloud in Privacy > Calendars");
  return NO;
}
BOOL RCMacNativeWaitForAccess(BOOL contacts,RCError *error)
{
  RCErrorClear(error);
  if(RCCheckCancellation(error)) return NO;
  if(!RCUsesNativeStores()) return YES;
  @try {
    if(contacts) {
      if([ABAddressBook addressBook]) return !RCCheckCancellation(error);
      RCErrorSet(error,1,"Contacts access is unavailable; allow rCloud in Privacy > Contacts");
      return NO;
    }
    for(;;) {
      if(RCCheckCancellation(error)) return NO;
      RCErrorClear(error);
      if(RCEventAccess(error)) return YES;
      BOOL pending;
      @synchronized([EKEventStore class]) { pending=eventRequester!=nil; }
      // A completed denial or failed request is not retried in a tight loop.
      if(!pending) {
        // Approval may have arrived between the status read and callback check.
        if([EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent]==EKAuthorizationStatusAuthorized) {
          RCErrorClear(error); return YES;
        }
        return NO;
      }
      // This runs on the account worker; the daemon's main run loop stays live.
      [NSThread sleepForTimeInterval:0.1];
    }
  } @catch(NSException *exception) {
    (void)exception; RCErrorSet(error,1,"Could not request native privacy access"); return NO;
  }
}
void RCMacNativeRequestAccess(BOOL contacts,BOOL calendars)
{
  if(!RCUsesNativeStores() || RCStopRequested) return;
  RCError error; RCErrorClear(&error);
  @try {
    if(calendars) {
      RCLogger(RCLogInfo,"Calendars","Access",@"Checking Calendar access at startup");
      RCEventAccess(&error);
    }
    if(contacts && !RCStopRequested) {
      RCLogger(RCLogInfo,"Contacts","Access",@"Checking Contacts access at startup");
      if(!RCMacNativeWaitForAccess(YES,&error) && !RCStopRequested)
        RCLogger(RCLogWarning,"Contacts","Access",@"%s",error.message);
    }
  } @catch(NSException *exception) {
    (void)exception;
    RCLogger(RCLogWarning,"Account","Access",@"Native permission request failed; each service will check access before downloading");
  }
}
static void Put(NSMutableDictionary *record,NSString *key,id value)
{
  if(value) [record setObject:value forKey:key]; else [record removeObjectForKey:key];
}
static NSString *ABLabel(NSDictionary *record)
{
  if([[record objectForKey:@"label"] length]) return [record objectForKey:@"label"];
  NSString *type=[record objectForKey:@"type"] ?: @"other";
  NSDictionary *labels=[NSDictionary dictionaryWithObjectsAndKeys:kABHomeLabel,@"home",kABWorkLabel,@"work",
      kABOtherLabel,@"other",kABPhoneMobileLabel,@"mobile",kABPhoneHomeFAXLabel,@"home fax",
      kABPhoneWorkFAXLabel,@"work fax",kABPhonePagerLabel,@"pager",kABHomePageLabel,@"home page",nil];
  return [labels objectForKey:type] ?: [NSString stringWithFormat:@"_$!<%@>!$_",[type capitalizedString]];
}
static void ABReadLabel(NSMutableDictionary *record,NSString *label)
{
  NSDictionary *types=[NSDictionary dictionaryWithObjectsAndKeys:@"home",kABHomeLabel,@"work",kABWorkLabel,
      @"other",kABOtherLabel,@"mobile",kABPhoneMobileLabel,@"home fax",kABPhoneHomeFAXLabel,
      @"work fax",kABPhoneWorkFAXLabel,@"pager",kABPhonePagerLabel,@"home page",kABHomePageLabel,nil];
  NSString *type=[types objectForKey:label ?: @""];
  if(!type && [label hasPrefix:@"_$!<"] && [label hasSuffix:@">!$_"])
    type=[[label substringWithRange:NSMakeRange(4,[label length]-8)] lowercaseString];
  [record setObject:type ?: @"other" forKey:@"type"];
  if(!type && [label length]) [record setObject:label forKey:@"label"];
}
static NSArray *ABFields(void)
{
  return [@"first name|last name|middle name|title|suffix|nickname|company name|department|job title|notes|birthday|first name yomi|last name yomi|middle name yomi" componentsSeparatedByString:@"|"];
}
static NSArray *ABProperties(void)
{
  return [NSArray arrayWithObjects:kABFirstNameProperty,kABLastNameProperty,kABMiddleNameProperty,kABTitleProperty,
      kABSuffixProperty,kABNicknameProperty,kABOrganizationProperty,kABDepartmentProperty,kABJobTitleProperty,
      kABNoteProperty,kABBirthdayProperty,kABFirstNamePhoneticProperty,kABLastNamePhoneticProperty,kABMiddleNamePhoneticProperty,nil];
}
static NSArray *ABRelations(void) { return [@"phone numbers|email addresses|street addresses|URLs|dates|related names|IMs|IMs|IMs|IMs|IMs" componentsSeparatedByString:@"|"]; }
static NSArray *ABMultiProperties(void)
{
  return [NSArray arrayWithObjects:kABPhoneProperty,kABEmailProperty,kABAddressProperty,kABURLsProperty,kABOtherDatesProperty,
      kABRelatedNamesProperty,kABAIMInstantProperty,kABJabberInstantProperty,kABMSNInstantProperty,kABYahooInstantProperty,kABICQInstantProperty,nil];
}
static NSArray *ABEntities(void) { return [@"Phone Number|Email Address|Street Address|URL|Date|Related Name|IM|IM|IM|IM|IM" componentsSeparatedByString:@"|"]; }
static NSArray *ABServices(void) { return [@"aim|jabber|msn|yahoo|icq" componentsSeparatedByString:@"|"]; }
static NSArray *ABAddressKeys(void) { return [@"street|city|state|postal code|country|country code" componentsSeparatedByString:@"|"]; }
static NSArray *ABAddressProperties(void) { return [NSArray arrayWithObjects:kABAddressStreetKey,kABAddressCityKey,kABAddressStateKey,kABAddressZIPKey,kABAddressCountryKey,kABAddressCountryCodeKey,nil]; }
static NSDictionary *ABRead(ABPerson *person,NSString *root,NSDictionary *ids)
{
  if(!person) return [NSDictionary dictionary];
  NSMutableDictionary *graph=[NSMutableDictionary dictionary], *record=[NSMutableDictionary dictionaryWithObject:@"com.apple.contacts.Contact" forKey:RCRecordEntityNameKey];
  NSArray *keys=ABFields(),*properties=ABProperties(); NSUInteger i,k;
  for(i=0;i<[keys count];i++) Put(record,[keys objectAtIndex:i],[person valueForProperty:[properties objectAtIndex:i]]);
  [record setObject:([[person valueForProperty:kABPersonFlags] intValue]&kABShowAsMask)==kABShowAsCompany ? @"company" : @"person" forKey:@"display as company"];
  Put(record,@"image",[person imageData]);
  for(k=0;k<[ABMultiProperties() count];k++) {
    NSString *property=[ABMultiProperties() objectAtIndex:k],*relation=[ABRelations() objectAtIndex:k];
    ABMultiValue *values=[person valueForProperty:property];
    NSMutableArray *children=[NSMutableArray arrayWithArray:[record objectForKey:relation] ?: [NSArray array]];
    for(i=0;i<[values count];i++) {
      NSString *native=[NSString stringWithFormat:@"%@/%@",property,[values identifierAtIndex:i]],*childID=nil;
      NSEnumerator *it=[ids keyEnumerator]; NSString *key;
      while((key=[it nextObject])) if([[ids objectForKey:key] isEqual:native]) { childID=key; break; }
      if(!childID) childID=[NSString stringWithFormat:@"%@/%@",root,native];
      NSMutableDictionary *child=[NSMutableDictionary dictionaryWithObjectsAndKeys:
          [@"com.apple.contacts." stringByAppendingString:[ABEntities() objectAtIndex:k]],RCRecordEntityNameKey,
          [NSArray arrayWithObject:root],@"contact",nil];
      ABReadLabel(child,[values labelAtIndex:i]);
      id value=[values valueAtIndex:i];
      if(k==2) { NSUInteger n; for(n=0;n<[ABAddressKeys() count];n++) Put(child,[ABAddressKeys() objectAtIndex:n],[value objectForKey:[ABAddressProperties() objectAtIndex:n]]); }
      else if(k>=6) { Put(child,@"user",value); Put(child,@"service",[ABServices() objectAtIndex:k-6]); }
      else Put(child,@"value",k==3 ? [NSURL URLWithString:value] : value);
      [children addObject:childID]; [graph setObject:child forKey:childID];
      if(k<4 && [[values primaryIdentifier] isEqual:[values identifierAtIndex:i]])
        [record setObject:[NSArray arrayWithObject:childID] forKey:[[@"primary phone number|primary email address|primary street address|primary URL" componentsSeparatedByString:@"|"] objectAtIndex:k]];
    }
    if([children count]) [record setObject:children forKey:relation];
  }
  [graph setObject:record forKey:root]; return graph;
}
static BOOL ABWrite(ABPerson *person,NSDictionary *resource,NSMutableDictionary *ids,RCError *error)
{
  NSString *root=[resource objectForKey:@"root"]; NSDictionary *graph=[resource objectForKey:@"graph"], *record=[graph objectForKey:root];
  NSArray *keys=ABFields(),*properties=ABProperties(); NSUInteger i,k; BOOL ok=YES;
  for(i=0;i<[keys count];i++) {
    id value=[record objectForKey:[keys objectAtIndex:i]];
    if(value) ok=[person setValue:value forProperty:[properties objectAtIndex:i]] && ok;
    else if([person valueForProperty:[properties objectAtIndex:i]]) ok=[person removeValueForProperty:[properties objectAtIndex:i]] && ok;
  }
  int flags=[[person valueForProperty:kABPersonFlags] intValue];
  flags=(flags&~kABShowAsMask)|([[record objectForKey:@"display as company"] isEqual:@"company"] ? kABShowAsCompany : kABShowAsPerson);
  ok=[person setValue:[NSNumber numberWithInt:flags] forProperty:kABPersonFlags] && ok;
  if([record objectForKey:@"image"] || [person imageData]) ok=[person setImageData:[record objectForKey:@"image"]] && ok;
  [ids removeAllObjects]; [ids setObject:[person uniqueId] forKey:root];
  for(k=0;k<[ABMultiProperties() count];k++) {
    NSString *property=[ABMultiProperties() objectAtIndex:k];
    ABMutableMultiValue *values=[[[ABMutableMultiValue alloc] init] autorelease];
    NSMutableArray *childIDs=[NSMutableArray array];
    NSEnumerator *it=[[record objectForKey:[ABRelations() objectAtIndex:k]] objectEnumerator]; NSString *key;
    while((key=[it nextObject])) {
      NSDictionary *child=[graph objectForKey:key]; id value=[child objectForKey:@"value"];
      if(k==2) { NSMutableDictionary *address=[NSMutableDictionary dictionary]; NSUInteger n;
        for(n=0;n<[ABAddressKeys() count];n++) Put(address,[ABAddressProperties() objectAtIndex:n],[child objectForKey:[ABAddressKeys() objectAtIndex:n]]); value=address; }
      if(k==3) value=RCTwoWayString(value);
      if(k>=6) { if(![[child objectForKey:@"service"] isEqual:[ABServices() objectAtIndex:k-6]]) continue; value=[child objectForKey:@"user"]; }
      if(!value) { ok=NO; continue; }
      NSString *native=[values addValue:value withLabel:ABLabel(child)];
      if(!native) { ok=NO; continue; }
      [childIDs addObject:key];
      [ids setObject:[NSString stringWithFormat:@"%@/%@",property,native] forKey:key];
      if(k<4 && [[record objectForKey:[[@"primary phone number|primary email address|primary street address|primary URL" componentsSeparatedByString:@"|"] objectAtIndex:k]] containsObject:key]) [values setPrimaryIdentifier:native];
    }
    // Preserve native multivalue identities when only another field changed.
    // Replacing unchanged child rows makes older AddressBook instances fault.
    ABMultiValue *existing=[person valueForProperty:property];
    BOOL same=[existing count]==[values count];
    for(i=0;same && i<[values count];i++) {
      same=[[existing valueAtIndex:i] isEqual:[values valueAtIndex:i]] &&
          [[existing labelAtIndex:i] isEqual:[values labelAtIndex:i]];
    }
    if(same && [values primaryIdentifier])
      same=[existing indexForIdentifier:[existing primaryIdentifier]]==[values indexForIdentifier:[values primaryIdentifier]];
    if(same) {
      for(i=0;i<[values count];i++) [ids setObject:[NSString stringWithFormat:@"%@/%@",property,[existing identifierAtIndex:i]] forKey:[childIDs objectAtIndex:i]];
      continue;
    }
    if([values count]) ok=[person setValue:values forProperty:property] && ok;
    else if([person valueForProperty:property]) ok=[person removeValueForProperty:property] && ok;
  }
  if(!ok) RCErrorSet(error,1,"AddressBook rejected a mapped contact field");
  return ok;
}
@implementation RCMacNativeStore
- (BOOL)openContacts:(RCError *)error {
  book_=[[ABAddressBook addressBook] retain];
  if(!book_) RCErrorSet(error,1,"Contacts access is unavailable; allow rCloud in Privacy > Contacts");
  return book_!=nil;
}
- (BOOL)calendarAccess:(RCError *)error { return RCEventAccess(error); }
- (void)dealloc { [book_ release]; [super dealloc]; }
- (id)contactForIdentifier:(NSString *)identifier { return identifier ? [book_ recordForUniqueId:identifier] : nil; }
- (id)groupForIdentifier:(NSString *)identifier { return [self contactForIdentifier:identifier]; }
- (NSString *)contactIdentifier:(id)person { return [person uniqueId]; }
- (id)createGroup:(NSString *)title error:(RCError *)error {
  ABGroup *group=[[[ABGroup alloc] init] autorelease];
  if([group setValue:title forProperty:kABGroupNameProperty] && [book_ addRecord:group] && [book_ save]) return group;
  RCErrorSet(error,1,"Could not create managed Contacts group"); return nil;
}
- (id)makeContact:(RCError *)error {
  ABPerson *person=[[[ABPerson alloc] init] autorelease];
  if([book_ addRecord:person]) return person;
  RCErrorSet(error,1,"Could not create managed contact"); return nil;
}
- (NSArray *)groupMembers:(id)group error:(RCError *)error { (void)error; return [group members]; }
- (BOOL)addContact:(id)person toGroup:(id)group error:(RCError *)error {
  if([[group members] containsObject:person] || [group addMember:person]) return YES;
  RCErrorSet(error,1,"Could not add managed contact to group"); return NO;
}
- (BOOL)saveContacts:(RCError *)error {
  if([book_ save]) return YES; RCErrorSet(error,1,"Could not save managed contacts"); return NO;
}
- (BOOL)removeContact:(id)person error:(RCError *)error {
  if([book_ removeRecord:person]) return [self saveContacts:error];
  RCErrorSet(error,1,"Could not remove managed contact"); return NO;
}
- (NSDictionary *)readContact:(id)person root:(NSString *)root identifiers:(NSDictionary *)ids error:(RCError *)error {
  (void)error; return ABRead(person,root,ids);
}
- (BOOL)writeContact:(id)person resource:(NSDictionary *)resource identifiers:(NSMutableDictionary *)ids error:(RCError *)error {
  return ABWrite(person,resource,ids,error);
}
@end

id<RCNativeStore> RCCreateMacNativeStore(RCTwoWayContext *context,RCError *error)
{ return [[RCMacNativeStore alloc] initWithContext:context error:error]; }
#else
void RCMacNativeRequestAccess(BOOL contacts,BOOL calendars) { (void)contacts; (void)calendars; }
BOOL RCMacNativeWaitForAccess(BOOL contacts,RCError *error)
{ (void)contacts; RCErrorClear(error); return !RCCheckCancellation(error); }
id<RCNativeStore> RCCreateMacNativeStore(RCTwoWayContext *context,RCError *error)
{ (void)context; RCErrorSet(error,1,"Mac native stores require the 64-bit application slice"); return nil; }
#endif
