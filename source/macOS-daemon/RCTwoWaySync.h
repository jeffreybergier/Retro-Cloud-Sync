#ifndef RC_TWO_WAY_SYNC_H
#define RC_TWO_WAY_SYNC_H
#import <Foundation/Foundation.h>
#import "RCRecordGraph.h"
#include "RCWriteJournal.h"
#include "RCHTTPClient.h"

/* Resource dictionaries contain key/href/etag/body/revision, a complete graph,
   root identifier and stable path -> record identifier mapping. Encoders return
   a replacement dictionary with body/graph/paths, or fail without losing intent.
   A nil resource asks the encoder to create the supplied native root. */
typedef NSMutableDictionary *(*RCTwoWayEncoder)(void *, NSDictionary *,
    NSDictionary *, NSString *, RCError *);
/* Reconstruct an immutable, verified upload using the current resource's
   identity. Return nil if the href now identifies a different logical object.
   With detachedReceipt=YES, validate the saved body against the supplied native
   graph/paths without requiring a currently imported resource identity. */
typedef NSDictionary *(*RCTwoWayVerifiedProjector)(void *, NSDictionary *, NSData *, RCError *);
typedef struct {
  RCWriteJournal journal;
  NSString *clientIdentifier;
  NSString *descriptionPath;
  NSString *rootEntity;
  NSArray *resources;
  NSDictionary *graph;
  RCTwoWayEncoder encode;
  void *context;
  BOOL didPublish;
  RCTwoWayVerifiedProjector projectVerified;
  BOOL didPublishAll; /* Partial fast publication must not checkpoint/prune the full mirror. */
} RCTwoWayContext;

/* Project supported edits through the strict mapper; return durable fieldScopes
   and pendingFields alongside the represented body/graph. */
NSMutableDictionary *RCTwoWayEncodeFields(RCTwoWayEncoder, void *, NSDictionary *,
    NSDictionary *, NSString *, RCError *);

BOOL RCTwoWayInitialize(RCWriteJournal *, RCError *);
typedef BOOL (*RCBackendExchange)(RCTwoWayContext *, BOOL, RCError *);
/* Only called in TwoWay mode, with this account's credentials. No sessions or
   SQLite transactions are open while requests run. Returns number attempted. */
int RCTwoWayRunWrites(RCWriteJournal *, RCHTTPClient *, const char *, RCError *);
NSDictionary *RCTwoWayApplyAliases(RCWriteJournal *, NSDictionary *, RCError *);
NSDictionary *RCTwoWayRemap(NSDictionary *, NSDictionary *);
BOOL RCTwoWayGraphsEqual(NSDictionary *, NSDictionary *);
BOOL RCTwoWayRecordsEqual(NSDictionary *, NSDictionary *);
NSDictionary *RCTwoWaySubgraph(NSDictionary *, NSArray *);
NSString *RCTwoWayNewIdentifier(void);
NSString *RCTwoWayEscape(NSString *);
NSString *RCTwoWayString(id);
BOOL RCTwoWaySQL(RCWriteJournal *, RCError *, const char *, ...);
#endif
