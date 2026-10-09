#ifndef RC_NATIVE_SYSTEM_STORE_H
#define RC_NATIVE_SYSTEM_STORE_H
#import <TargetConditionals.h>
#import "RCNativeStore.h"
#if defined(__LP64__) || TARGET_OS_IPHONE
/* Durable ownership, receipts and EventKit publication are shared; each target
   supplies its own Contacts API and access policy. */
@interface RCNativeSystemStore : NSObject <RCNativeStore> {
@protected
  RCTwoWayContext *context_;
  id events_;
  BOOL contacts_;
}
- (id)initWithContext:(RCTwoWayContext *)context error:(RCError *)error;
@end
@interface RCNativeSystemStore (Platform)
- (BOOL)openContacts:(RCError *)error;
- (BOOL)calendarAccess:(RCError *)error;
- (id)contactForIdentifier:(NSString *)identifier;
- (id)groupForIdentifier:(NSString *)identifier;
- (NSString *)contactIdentifier:(id)person;
- (id)createGroup:(NSString *)title error:(RCError *)error;
- (id)makeContact:(RCError *)error;
- (NSArray *)groupMembers:(id)group error:(RCError *)error;
- (BOOL)addContact:(id)person toGroup:(id)group error:(RCError *)error;
- (BOOL)saveContacts:(RCError *)error;
- (BOOL)removeContact:(id)person error:(RCError *)error;
- (NSDictionary *)readContact:(id)person root:(NSString *)root identifiers:(NSDictionary *)ids error:(RCError *)error;
- (BOOL)writeContact:(id)person resource:(NSDictionary *)resource identifiers:(NSMutableDictionary *)ids error:(RCError *)error;
@end
#endif
#endif
