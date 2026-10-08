#ifndef RC_NATIVE_SYNC_H
#define RC_NATIVE_SYNC_H
#import "RCTwoWaySync.h"
#include "RCContactStore.h"
#include "RCCalendarStore.h"
/* The cutoff is explicit, not inferred from whether Sync Services happens to work. */
BOOL RCUsesNativeStoresForVersion(int major, int minor);
BOOL RCUsesNativeStores(void);
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
