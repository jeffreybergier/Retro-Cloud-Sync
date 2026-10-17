#ifndef RC_NATIVE_STORE_H
#define RC_NATIVE_STORE_H
#import "RCTwoWaySync.h"
/* Per-exchange, account-owned store. Objects stay on their owning worker.
   Implementations preserve durable IDs, pending saves and exact receipts;
   unavailable/unauthorized stores must fail, never appear empty. */
@protocol RCNativeStore <NSObject>
- (BOOL)syncContainers:(RCError *)error;
- (NSDictionary *)savedResources:(RCError *)error;
- (NSDictionary *)readResource:(NSDictionary *)saved error:(RCError *)error;
/* Returns nil for a verified series, or a borrowed reason string.
   native-series-open-ended means only the saved master matches: the caller
   may quietly retain an identical cloud body, never replace or upload it. */
- (NSString *)seriesAttention:(NSDictionary *)saved error:(RCError *)error;
- (BOOL)rememberResource:(NSDictionary *)resource native:(NSDictionary *)saved error:(RCError *)error;
- (NSArray *)untrackedResources:(RCError *)error;
- (BOOL)canPublishResource:(NSDictionary *)resource error:(RCError *)error;
- (BOOL)publishResource:(NSDictionary *)resource error:(RCError *)error;
- (BOOL)removeResource:(NSDictionary *)saved error:(RCError *)error;
/* Capture the exact native readback in the enqueue transaction, before HTTP.
   Acknowledgement checkpoints only these represented fields; newer local
   edits remain differences against that snapshot. Owner-thread only. */
- (BOOL)captureReceipt:(NSDictionary *)receipt operation:(long long)operation
    scopes:(NSDictionary *)scopes resource:(NSDictionary *)resource
    error:(RCError *)error;
- (BOOL)acceptReceipt:(NSDictionary *)receipt operation:(long long)operation scopes:(NSDictionary *)scopes
          newerTruth:(NSDictionary **)newer error:(RCError *)error;
@end
/* Factory returns a retained per-exchange store. The coordinator creates it
   after journal initialization and releases it on success, error or exception. */
typedef id<RCNativeStore> (*RCCreateNativeStore)(RCTwoWayContext *,RCError *);
BOOL RCNativeExchange(RCTwoWayContext *, BOOL, RCCreateNativeStore, RCError *);
#endif
