#ifndef RC_TWO_WAY_INTERNAL_H
#define RC_TWO_WAY_INTERNAL_H
#import "RCTwoWaySync.h"
/* Shared journal primitives. Backends must preserve transaction boundaries,
   exact receipts and publication generations when using these helpers. */
typedef BOOL (*RCSyncAcceptReceipt)(void *, NSDictionary *, NSDictionary *, BOOL,
    NSDictionary **, RCError *);
BOOL RCTwoWayComplete(RCTwoWayContext *, NSDictionary *, NSMutableDictionary *,
    RCSyncAcceptReceipt, void *, RCError *);
id RCTwoWayUnarchive(sqlite3_stmt *q, int col);
BOOL RCTwoWaySaveIntent(RCWriteJournal *j, long long operation, NSDictionary *receipt,
                       NSDictionary *paths, NSDictionary *scopes, RCError *error);
BOOL RCTwoWaySaveResource(RCWriteJournal *j, long long operation, NSDictionary *resource, RCError *error);
NSMutableDictionary *RCTwoWayDeletion(NSDictionary *resource, NSDictionary *truth);
NSDictionary *RCTwoWayPublishedGraph(RCWriteJournal *j, RCError *error);
BOOL RCTwoWaySavePublished(RCWriteJournal *j, NSDictionary *graph, RCError *error);
NSMutableDictionary *RCTwoWayAliases(RCWriteJournal *j, RCError *error);
NSDictionary *RCTwoWayMapResource(NSDictionary *resource, NSDictionary *aliases);
BOOL RCTwoWayAttention(RCWriteJournal *j, NSString *root, const char *reason, RCError *error);
BOOL RCTwoWaySavePendingFields(RCWriteJournal *j, NSString *root, NSDictionary *desired, RCError *error);
#endif
