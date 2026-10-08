#ifndef RC_NATIVE_SYNC_H
#define RC_NATIVE_SYNC_H
#import "RCTwoWaySync.h"
#include "RCContactStore.h"
#include "RCCalendarStore.h"
/* The cutoff is explicit, not inferred from whether Sync Services happens to work. */
BOOL RCUsesNativeStoresForVersion(int major, int minor);
BOOL RCUsesNativeStores(void);
/* Called by the account worker at startup, before credentials or network work.
   Request Calendar first because AddressBook may wait for the user's response. */
void RCNativeRequestAccess(BOOL contacts, BOOL calendars);
/* Wait only while approval is pending; denial fails this service, and shutdown
   interrupts the Calendar wait. No native records are read or written here. */
BOOL RCNativeWaitForAccess(BOOL contacts, RCError *error);
int RCNativeSyncContacts(RCContactStore *, BOOL, long *, RCError *);
int RCNativeSyncCalendars(RCCalendarStore *, BOOL, long *, RCError *);
BOOL RCNativeExchange(RCTwoWayContext *, BOOL, RCError *);
/* One instance per account worker/exchange. All native objects stay on that thread.
   State belongs to this account's existing private SQLite database. */
@interface RCNativeStore : NSObject {
  RCTwoWayContext *context_;
  id book_, events_;
  BOOL contacts_;
}
- (id)initWithContext:(RCTwoWayContext *)context error:(RCError *)error;
- (BOOL)syncContainers:(RCError *)error;
- (NSDictionary *)savedResources:(RCError *)error;
- (NSDictionary *)readResource:(NSDictionary *)saved error:(RCError *)error;
- (BOOL)rememberResource:(NSDictionary *)resource native:(NSDictionary *)saved error:(RCError *)error;
- (NSArray *)untrackedResources:(RCError *)error;
- (BOOL)canPublishResource:(NSDictionary *)resource error:(RCError *)error;
- (BOOL)publishResource:(NSDictionary *)resource error:(RCError *)error;
- (BOOL)removeResource:(NSDictionary *)saved error:(RCError *)error;
- (BOOL)acceptReceipt:(NSDictionary *)receipt scopes:(NSDictionary *)scopes
          newerTruth:(NSDictionary **)newer error:(RCError *)error;
@end
#endif
