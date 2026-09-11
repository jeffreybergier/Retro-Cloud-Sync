#ifndef RC_SYNC_CONFLICT_SESSION_H
#define RC_SYNC_CONFLICT_SESSION_H
#import <Foundation/Foundation.h>
#import <SyncServices/SyncServices.h>
#include "RCError.h"

/* Sessions are owned by the worker. Cancellation is never performed by the
   signal handler or a second thread. */
ISyncSession *RCBeginSession(ISyncClient *, NSArray *);
BOOL RCPrepareToPull(ISyncSession *, NSArray *);
void RCSessionCheck(void);
static inline void RCSessionPush(ISyncSession *session, NSDictionary *record, NSString *identifier)
{ RCSessionCheck(); [session pushChangesFromRecord:record withIdentifier:identifier]; }
static inline void RCSessionDelete(ISyncSession *session, NSString *identifier)
{ RCSessionCheck(); [session deleteRecordWithIdentifier:identifier]; }

/* Only pull entities that this client can receive. Unsupported types can
   remain push-only while contacts/events use the same two-way registration. */
static inline NSArray *RCSyncPullableEntities(ISyncClient *client)
{
  NSMutableArray *result=[NSMutableArray array];
  NSEnumerator *it=[[client enabledEntityNames] objectEnumerator]; NSString *entity;
  while ((entity=[it nextObject])) if ([client canPullChangesForEntityName:entity]) [result addObject:entity];
  return result;
}

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
   canonical decision is the receipt stored in the journal. NSNull represents
   a verified resource DELETE or a child removal in a verified parent PUT.
   Returns NO without
   accepting anything if a target has since changed or disappeared, or the engine
   requires a full resync. Repeating after a successful acceptance is safe. */
BOOL RCSyncAcceptConflictResolution(ISyncClient *client,
    NSDictionary *receipt, RCError *error);
/* On a changed receipt, return the post-mingling truth without accepting it.
   The two-way coordinator can durably queue a successor against the verified base. */
BOOL RCSyncAcceptUpload(ISyncClient *, NSDictionary *, NSDictionary **, RCError *);
/* Match only the immutable represented fields. Records with additional local
   edits are deliberately left unaccepted in Sync Services; callers may retire
   the verified server operation while retaining field-level pending state. */
BOOL RCSyncAcceptMappedUpload(ISyncClient *, NSDictionary *, NSDictionary *, NSDictionary **, RCError *);
/* Production fast-session reconciliation of one resource. Missing remote
   records must be backed by an explicit writer GET 404 or mapped child removal.
   Returns canonical truth without accepting any native changes. */
NSDictionary *RCSyncResolveResourceConflict(ISyncClient *, NSDictionary *, NSArray *, RCError *);
#endif
