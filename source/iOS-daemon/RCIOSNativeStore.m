#import "RCIOSNativeBackend.h"
#import "RCIOSAccess.h"
#import "RCNativeSystemStore.h"
#import "RCRecordGraph.h"
/* ABRecord is a CF object, not a Mac ABPerson. Keep CF ownership explicit. */
@interface RCIOSRecord : NSObject { @public ABRecordRef record; }
+ (id)record:(ABRecordRef)value;
@end
@implementation RCIOSRecord
+ (id)record:(ABRecordRef)value {
  if(!value) return nil;
  RCIOSRecord *r=[[[self alloc] init] autorelease]; r->record=CFRetain(value); return r;
}
- (void)dealloc { if(record) CFRelease(record); [super dealloc]; }
@end
static ABRecordRef Record(RCIOSRecord *item) { return item ? item->record : NULL; }
static id Value(ABRecordRef record,ABPropertyID property) {
  return record ? [(id)ABRecordCopyValue(record,property) autorelease] : nil;
}
static void Put(NSMutableDictionary *d,NSString *key,id value) { if(value) [d setObject:value forKey:key]; }
static BOOL Set(ABRecordRef record,ABPropertyID property,id value) {
  return value ? ABRecordSetValue(record,property,(CFTypeRef)value,NULL) : ABRecordRemoveValue(record,property,NULL);
}
static NSArray *Fields(void) { return [@"first name|last name|middle name|title|suffix|nickname|company name|department|job title|notes|birthday|first name yomi|last name yomi|middle name yomi" componentsSeparatedByString:@"|"]; }
static void Properties(ABPropertyID *p) {
  ABPropertyID values[]={kABPersonFirstNameProperty,kABPersonLastNameProperty,kABPersonMiddleNameProperty,kABPersonPrefixProperty,
      kABPersonSuffixProperty,kABPersonNicknameProperty,kABPersonOrganizationProperty,kABPersonDepartmentProperty,kABPersonJobTitleProperty,
      kABPersonNoteProperty,kABPersonBirthdayProperty,kABPersonFirstNamePhoneticProperty,kABPersonLastNamePhoneticProperty,kABPersonMiddleNamePhoneticProperty};
  memcpy(p,values,sizeof(values));
}
static NSArray *Relations(void) { return [@"phone numbers|email addresses|street addresses|URLs|dates|related names|IMs" componentsSeparatedByString:@"|"]; }
static NSArray *Entities(void) { return [@"Phone Number|Email Address|Street Address|URL|Date|Related Name|IM" componentsSeparatedByString:@"|"]; }
static void MultiProperties(ABPropertyID *p) {
  ABPropertyID values[]={kABPersonPhoneProperty,kABPersonEmailProperty,kABPersonAddressProperty,kABPersonURLProperty,kABPersonDateProperty,kABPersonRelatedNamesProperty,kABPersonInstantMessageProperty};
  memcpy(p,values,sizeof(values));
}
static NSArray *AddressKeys(void) { return [@"street|city|state|postal code|country|country code" componentsSeparatedByString:@"|"]; }
static NSArray *AddressProperties(void) { return [NSArray arrayWithObjects:(id)kABPersonAddressStreetKey,(id)kABPersonAddressCityKey,(id)kABPersonAddressStateKey,(id)kABPersonAddressZIPKey,(id)kABPersonAddressCountryKey,(id)kABPersonAddressCountryCodeKey,nil]; }
static NSDictionary *Labels(void) {
  return [NSDictionary dictionaryWithObjectsAndKeys:(id)kABHomeLabel,@"home",(id)kABWorkLabel,@"work",(id)kABOtherLabel,@"other",
      (id)kABPersonPhoneMobileLabel,@"mobile",(id)kABPersonPhoneHomeFAXLabel,@"home fax",(id)kABPersonPhoneWorkFAXLabel,@"work fax",
      (id)kABPersonPhonePagerLabel,@"pager",(id)kABPersonHomePageLabel,@"home page",nil];
}
static NSString *Label(NSDictionary *child) {
  if([[child objectForKey:@"label"] length]) return [child objectForKey:@"label"];
  NSString *type=[child objectForKey:@"type"] ?: @"other";
  return [Labels() objectForKey:type] ?: [NSString stringWithFormat:@"_$!<%@>!$_",[type capitalizedString]];
}
static void ReadLabel(NSMutableDictionary *child,NSString *label) {
  NSString *type=nil;
  for(NSString *key in Labels()) if([[Labels() objectForKey:key] isEqual:label]) { type=key; break; }
  if(!type && [label hasPrefix:@"_$!<"] && [label hasSuffix:@">!$_"]) type=[[label substringWithRange:NSMakeRange(4,[label length]-8)] lowercaseString];
  Put(child,@"type",type ?: @"other"); if(!type && [label length]) Put(child,@"label",label);
}
static NSDictionary *Services(void) {
  return [NSDictionary dictionaryWithObjectsAndKeys:(id)kABPersonInstantMessageServiceAIM,@"aim",(id)kABPersonInstantMessageServiceJabber,@"jabber",
      (id)kABPersonInstantMessageServiceMSN,@"msn",(id)kABPersonInstantMessageServiceYahoo,@"yahoo",(id)kABPersonInstantMessageServiceICQ,@"icq",
      (id)kABPersonInstantMessageServiceSkype,@"skype",(id)kABPersonInstantMessageServiceGoogleTalk,@"google talk",nil];
}
@interface RCIOSNativeStore : RCNativeSystemStore { ABAddressBookRef book_; ABRecordRef source_; }
@end
@implementation RCIOSNativeStore
- (BOOL)openContacts:(RCError *)error {
  if(!RCIOSWaitForAccess(YES,error)) return NO;
  book_=RCIOSCreateAddressBook(NULL);
  if(book_) {
    CFArrayRef sources=ABAddressBookCopyArrayOfAllSources(book_);
    for(CFIndex n=0;sources && n<CFArrayGetCount(sources);n++) {
      ABRecordRef source=CFArrayGetValueAtIndex(sources,n);
      if([Value(source,kABSourceTypeProperty) intValue]==kABSourceTypeLocal) {
        if(source_) { CFRelease(sources); RCErrorSet(error,1,"Multiple local Contacts sources; refusing ambiguous ownership"); return NO; }
        source_=CFRetain(source);
      }
    }
    if(sources) CFRelease(sources);
  }
  if(!book_ || !source_) { RCErrorSet(error,1,"Local Contacts source is unavailable"); return NO; }
  return YES;
}
- (BOOL)calendarAccess:(RCError *)error { return RCIOSWaitForAccess(NO,error); }
- (void)dealloc { if(source_) CFRelease(source_); if(book_) CFRelease(book_); [super dealloc]; }
- (NSString *)contactIdentifier:(id)item {
  ABRecordID rid=ABRecordGetRecordID(Record(item));
  return rid==kABRecordInvalidID ? nil : [NSString stringWithFormat:@"%d",(int)rid];
}
- (id)contactForIdentifier:(NSString *)identifier {
  return identifier ? [RCIOSRecord record:ABAddressBookGetPersonWithRecordID(book_,[identifier intValue])] : nil;
}
- (id)groupForIdentifier:(NSString *)identifier {
  return identifier ? [RCIOSRecord record:ABAddressBookGetGroupWithRecordID(book_,[identifier intValue])] : nil;
}
- (BOOL)saveContacts:(RCError *)error {
  if(!RCIOSWaitForAccess(YES,error)) return NO;
  if(ABAddressBookSave(book_,NULL)) return YES;
  RCErrorSet(error,1,"AddressBook could not save managed contacts"); return NO;
}
- (id)createGroup:(NSString *)title error:(RCError *)error {
  ABRecordRef group=ABGroupCreateInSource(source_); id result=nil;
  if(group && Set(group,kABGroupNameProperty,title) && ABAddressBookAddRecord(book_,group,NULL) && [self saveContacts:error]) result=[RCIOSRecord record:group];
  if(group) CFRelease(group);
  if(!result && !error->code) RCErrorSet(error,1,"Could not create managed Contacts group"); return result;
}
- (id)makeContact:(RCError *)error {
  ABRecordRef person=ABPersonCreateInSource(source_); id result=nil;
  if(person && ABAddressBookAddRecord(book_,person,NULL)) result=[RCIOSRecord record:person];
  if(person) CFRelease(person);
  if(!result) RCErrorSet(error,1,"Could not create managed contact"); return result;
}
- (NSArray *)groupMembers:(id)group error:(RCError *)error {
  if(!group) return [NSArray array];
  if(!RCIOSWaitForAccess(YES,error)) return nil;
  CFArrayRef members=ABGroupCopyArrayOfAllMembers(Record(group));
  /* iOS 8 returns NULL for a newly saved empty group. Recheck access and
     group identity before accepting that empty membership projection. */
  if(!members) {
    if(!RCIOSWaitForAccess(YES,error)) return nil;
    ABRecordID identifier=ABRecordGetRecordID(Record(group));
    if(identifier==kABRecordInvalidID || !ABAddressBookGetGroupWithRecordID(book_,identifier)) {
      RCErrorSet(error,1,"Managed Contacts group is unavailable"); return nil;
    }
    return [NSArray array];
  }
  NSMutableArray *result=[NSMutableArray array];
  for(CFIndex n=0;n<CFArrayGetCount(members);n++) [result addObject:[RCIOSRecord record:CFArrayGetValueAtIndex(members,n)]];
  CFRelease(members); return result;
}
- (BOOL)addContact:(id)person toGroup:(id)group error:(RCError *)error {
  NSArray *members=[self groupMembers:group error:error]; if(!members) return NO;
  for(id member in members) if(Record(member)==Record(person) || [[self contactIdentifier:member] isEqual:[self contactIdentifier:person]]) return YES;
  if(ABGroupAddMember(Record(group),Record(person),NULL)) return YES;
  RCErrorSet(error,1,"Could not add managed contact to group"); return NO;
}
- (BOOL)removeContact:(id)person error:(RCError *)error {
  if(ABAddressBookRemoveRecord(book_,Record(person),NULL)) return [self saveContacts:error];
  RCErrorSet(error,1,"Could not remove managed contact"); return NO;
}
- (NSDictionary *)readContact:(id)item root:(NSString *)root identifiers:(NSDictionary *)ids error:(RCError *)error {
  if(!RCIOSWaitForAccess(YES,error)) return nil;
  ABRecordRef person=Record(item); if(!person) return [NSDictionary dictionary];
  ABPropertyID properties[14],multi[7]; Properties(properties); MultiProperties(multi);
  NSMutableDictionary *graph=[NSMutableDictionary dictionary], *record=[NSMutableDictionary dictionaryWithObject:@"com.apple.contacts.Contact" forKey:RCRecordEntityNameKey];
  for(NSUInteger n=0;n<14;n++) Put(record,[Fields() objectAtIndex:n],Value(person,properties[n]));
  Put(record,@"display as company",[Value(person,kABPersonKindProperty) isEqual:(id)kABPersonKindOrganization] ? @"company" : @"person");
  CFDataRef photo=ABPersonCopyImageData(person); if(photo) { Put(record,@"image",(id)photo); CFRelease(photo); }
  for(NSUInteger k=0;k<7;k++) {
    ABMultiValueRef values=ABRecordCopyValue(person,multi[k]); NSMutableArray *children=[NSMutableArray array];
    for(CFIndex n=0;values && n<ABMultiValueGetCount(values);n++) {
      NSString *native=[NSString stringWithFormat:@"%d/%d",(int)multi[k],(int)ABMultiValueGetIdentifierAtIndex(values,n)], *key=nil;
      for(NSString *candidate in ids) if([[ids objectForKey:candidate] isEqual:native]) { key=candidate; break; }
      if(!key) key=[NSString stringWithFormat:@"%@/%@",root,native];
      NSMutableDictionary *child=[NSMutableDictionary dictionaryWithObjectsAndKeys:[@"com.apple.contacts." stringByAppendingString:[Entities() objectAtIndex:k]],RCRecordEntityNameKey,[NSArray arrayWithObject:root],@"contact",nil];
      CFStringRef label=ABMultiValueCopyLabelAtIndex(values,n); ReadLabel(child,(id)label); if(label) CFRelease(label);
      CFTypeRef value=ABMultiValueCopyValueAtIndex(values,n);
      if(k==2) for(NSUInteger a=0;a<6;a++) Put(child,[AddressKeys() objectAtIndex:a],[(id)value objectForKey:[AddressProperties() objectAtIndex:a]]);
      else if(k==6) {
        Put(child,@"user",[(id)value objectForKey:(id)kABPersonInstantMessageUsernameKey]);
        NSString *service=[(id)value objectForKey:(id)kABPersonInstantMessageServiceKey],*name=nil;
        for(NSString *candidate in Services()) if([[Services() objectForKey:candidate] isEqual:service]) { name=candidate; break; }
        Put(child,@"service",name ?: [service lowercaseString]);
      } else Put(child,@"value",k==3 ? [NSURL URLWithString:(id)value] : (id)value);
      if(value) CFRelease(value); [children addObject:key]; [graph setObject:child forKey:key];
    }
    if(values) CFRelease(values);
    if([children count]) Put(record,[Relations() objectAtIndex:k],children);
  }
  [graph setObject:record forKey:root]; return graph;
}
- (BOOL)writeContact:(id)item resource:(NSDictionary *)resource identifiers:(NSMutableDictionary *)ids error:(RCError *)error {
  ABRecordRef person=Record(item); NSString *root=[resource objectForKey:@"root"];
  NSDictionary *graph=[resource objectForKey:@"graph"], *record=[graph objectForKey:root];
  ABPropertyID properties[14],multi[7]; Properties(properties); MultiProperties(multi); BOOL ok=YES;
  for(NSUInteger n=0;n<14;n++) {
    id value=[record objectForKey:[Fields() objectAtIndex:n]];
    if(value || Value(person,properties[n])) ok=Set(person,properties[n],value) && ok;
  }
  ok=Set(person,kABPersonKindProperty,[[record objectForKey:@"display as company"] isEqual:@"company"] ? (id)kABPersonKindOrganization : (id)kABPersonKindPerson) && ok;
  NSData *image=[record objectForKey:@"image"];
  if(image) ok=ABPersonSetImageData(person,(CFDataRef)image,NULL) && ok;
  else if(ABPersonHasImageData(person)) ok=ABPersonRemoveImageData(person,NULL) && ok;
  [ids removeAllObjects];
  for(NSUInteger k=0;k<7;k++) {
    ABPropertyType type=k==2 || k==6 ? kABMultiDictionaryPropertyType : k==4 ? kABMultiDateTimePropertyType : kABMultiStringPropertyType;
    ABMutableMultiValueRef values=ABMultiValueCreateMutable(type); NSMutableArray *keys=[NSMutableArray array];
    for(NSString *key in [record objectForKey:[Relations() objectAtIndex:k]]) {
      NSDictionary *child=[graph objectForKey:key]; id value=[child objectForKey:@"value"];
      if(k==2) {
        NSMutableDictionary *address=[NSMutableDictionary dictionary];
        for(NSUInteger a=0;a<6;a++) Put(address,[AddressProperties() objectAtIndex:a],[child objectForKey:[AddressKeys() objectAtIndex:a]]); value=address;
      } else if(k==3) value=RCTwoWayString(value);
      else if(k==6) {
        NSString *service=[Services() objectForKey:[child objectForKey:@"service"]];
        if(!service || ![child objectForKey:@"user"]) { ok=NO; continue; }
        value=[NSDictionary dictionaryWithObjectsAndKeys:service,(id)kABPersonInstantMessageServiceKey,[child objectForKey:@"user"],(id)kABPersonInstantMessageUsernameKey,nil];
      }
      ABMultiValueIdentifier identifier;
      if(!value || !ABMultiValueAddValueAndLabel(values,(CFTypeRef)value,(CFStringRef)Label(child),&identifier)) { ok=NO; continue; }
      [keys addObject:key];
    }
    ABMultiValueRef old=ABRecordCopyValue(person,multi[k]);
    BOOL same=(!old ? 0 : ABMultiValueGetCount(old))==ABMultiValueGetCount(values);
    for(CFIndex n=0;same && n<ABMultiValueGetCount(values);n++) {
      CFTypeRef a=ABMultiValueCopyValueAtIndex(old,n),b=ABMultiValueCopyValueAtIndex(values,n);
      CFStringRef al=ABMultiValueCopyLabelAtIndex(old,n),bl=ABMultiValueCopyLabelAtIndex(values,n);
      same=a && b && CFEqual(a,b) && (al==bl || (al && bl && CFEqual(al,bl)));
      if(a) CFRelease(a); if(b) CFRelease(b); if(al) CFRelease(al); if(bl) CFRelease(bl);
    }
    ABMultiValueRef selected=same ? old : values;
    if(!same) ok=Set(person,multi[k],ABMultiValueGetCount(values) ? (id)values : nil) && ok;
    for(NSUInteger n=0;n<[keys count];n++) [ids setObject:[NSString stringWithFormat:@"%d/%d",(int)multi[k],(int)ABMultiValueGetIdentifierAtIndex(selected,n)] forKey:[keys objectAtIndex:n]];
    if(old) CFRelease(old); CFRelease(values);
  }
  if(!ok) RCErrorSet(error,1,"iOS AddressBook rejected a mapped contact field"); return ok;
}
@end
id<RCNativeStore> RCCreateIOSNativeStore(RCTwoWayContext *context,RCError *error) {
  return [[RCIOSNativeStore alloc] initWithContext:context error:error];
}
