#ifndef RC_CONTACT_CONFLICT_RESOLVER_H
#define RC_CONTACT_CONFLICT_RESOLVER_H
#import "RCSyncConflictSession.h"
#include "RCConflictRecovery.h"

/* First supported reverse mapping: NOTE, TITLE and NICKNAME value changes.
   All other locally changed fields, child graph changes, UID collisions and
   edit/delete conflicts remain durable attention cases. Unknown remote fields
   are preserved verbatim. The graph must be the complete graph for the existing
   two-way client, and recordID must be the contact owned by this operation.
   The caller supplies the graph from its last complete mirror and serializes
   mirror imports, recovery and other sessions for this account. */
int RCContactRecoverConflict(RCWriteJournal *, long long conflictID,
    ISyncClient *, NSDictionary *completeRemoteGraph, NSString *recordID,
    long long *successorID, RCError *);

/* Suitable for the acceptLocal callback in RCConflictComplete after the caller
   has atomically saved the verified result to its mirror. Checks normalization
   against the mapped decision and leaves newer local edits unaccepted. */
int RCContactAcceptConflict(ISyncClient *, const RCWriteOperation *,
    const void *receipt, size_t receiptLength, RCError *);
#endif
