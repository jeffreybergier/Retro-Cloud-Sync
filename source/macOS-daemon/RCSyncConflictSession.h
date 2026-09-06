#ifndef RC_SYNC_CONFLICT_SESSION_H
#define RC_SYNC_CONFLICT_SESSION_H
#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#include "RCError.h"

/* Use the existing two-way server client and its existing record identities.
   completeRemoteGraph must contain ALL of that client's remote records in the
   enabled entities, including retained unsupported records. It must not contain
   pending local intent disguised as a remote change. The caller serializes all
   sessions for this client and keeps the outgoing operation immutable.

   The returned dictionary maps target IDs to canonical records selected by the
   system engine. Missing targets are an attention condition, never authorization
   to delete a remote resource. The pull transaction is cancelled deliberately:
   successful resolution is not acknowledgement of a remote write. */
NSDictionary *RCSyncResolveConflict(ISyncClient *client,
    NSDictionary *completeRemoteGraph, NSArray *targetIDs, RCError *error);
/* Additionally verify that the journal's local intent still exists before
   publishing a newer remote version. expectedLocal maps record IDs to changed
   properties; NSNull represents an absent property. A mismatch defers recovery. */
NSDictionary *RCSyncResolveConflictWithIntent(ISyncClient *client,
    NSDictionary *completeRemoteGraph, NSArray *targetIDs,
    NSDictionary *expectedLocal, RCError *error);

/* Call only after remote verification and durable mirror completion. The exact
   canonical decision is the receipt stored in the journal. Returns NO without
   accepting anything if a target has since changed or disappeared, or the engine
   requires a full resync. Repeating after a successful acceptance is safe. */
BOOL RCSyncAcceptConflictResolution(ISyncClient *client,
    NSDictionary *receipt, RCError *error);
#endif
