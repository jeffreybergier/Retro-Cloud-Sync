#ifndef RC_WRITE_JOURNAL_H
#define RC_WRITE_JOURNAL_H

#include "RCError.h"
#include <AltivecCore/sqlite3.h>
#include <stddef.h>

/* Borrowed connection, confined to the owning account worker. Network operations
   must run outside SQLite and Sync Services transactions. */
typedef struct { sqlite3 *db; long long account; } RCWriteJournal;
typedef struct {
  long long id, localRevision, retryAt;
  int attempts, httpStatus;
  char *changeID, *resourceKey, *href, *kind, *state, *baseETag, *resultETag;
  unsigned char *baseBody, *desiredBody, *resultBody;
  size_t baseLength, desiredLength, resultLength;
} RCWriteOperation;

int RCWriteJournalInitialize(sqlite3 *, RCError *);
/* Called in the same transaction as publication acknowledgement. Missing or
   weak ETags may be retained, but cannot authorize a conditional write. */
int RCWriteJournalSetBase(RCWriteJournal *, const char *resourceKey,
    const char *href, const char *etag, const void *body, size_t length,
    long long localRevision, RCError *);
/* Stable changeID makes replay idempotent. One unacknowledged operation per
   resource/href. Updates/deletes require the exact published localRevision;
   creates require revision zero, no base, and a caller-chosen stable href.
   kind is create/update/delete; body is NULL only for delete. */
int RCWriteJournalEnqueue(RCWriteJournal *, const char *changeID,
    const char *resourceKey, const char *href, const char *kind,
    long long localRevision, const void *body, size_t length,
    long long *operationID, RCError *);
int RCWriteJournalGet(RCWriteJournal *, long long, RCWriteOperation *, RCError *);
void RCWriteOperationClear(RCWriteOperation *);
/* Returns 0 in operationID when there is no due work. Conflicts/applied writes
   require caller attention and are deliberately excluded. */
int RCWriteJournalNext(RCWriteJournal *, long long now, long long *operationID,
    RCError *);
int RCWriteJournalBeginAttempt(RCWriteJournal *, long long, long long now, RCError *);
/* Result bodies are private database data, never protocol log messages. */
int RCWriteJournalRecordResult(RCWriteJournal *, long long, const char *state,
    int httpStatus, const char *etag, const void *body, size_t length, RCError *);
/* Only after the caller has committed the confirmed result to its mirror and
   accepted the corresponding local change. May join that caller transaction. */
int RCWriteJournalAcknowledge(RCWriteJournal *, long long, RCError *);
int RCWriteJournalCancel(RCWriteJournal *, long long, RCError *);
/* A resolver must retain its canonical result/record identities in receipt.
   Atomically retire a conflict and create a successor pinned to the observed
   remote revision, WITHOUT changing the published base or original operation.
   kind is update/delete for an existing remote resource, or create for a 404.
   Even choosing the remote version creates a verification-only successor.
   Replaying the exact decision returns the same successor; a different decision
   is rejected. This API does not authorize automatic edit/delete resolution. */
int RCWriteJournalResolveConflict(RCWriteJournal *, long long conflictID,
    const char *kind, const void *body, size_t length,
    const void *receipt, size_t receiptLength, long long *successorID, RCError *);
/* Attention is a durable diagnostic reason code, never a body or exception.
   NULL clears attention after an explicit retry request. */
int RCWriteJournalConflictAttention(RCWriteJournal *, long long, const char *, RCError *);
/* Select unresolved conflicts, excluding those requiring manual attention. */
int RCWriteJournalNextConflict(RCWriteJournal *, long long *operationID, RCError *);
/* Recovery scans advance afterID even when a record is deferred, allowing other
   resources to progress. Pass 0 at the beginning of each account's poll. */
int RCWriteJournalRecoveryNext(RCWriteJournal *, long long afterID,
    long long *operationID, RCError *);
/* Copy the immutable receipt associated with a successor (caller frees).
   mirrorCommitted is persisted with the mirror transaction. */
int RCWriteJournalResolutionReceipt(RCWriteJournal *, long long successorID,
    void **receipt, size_t *length, int *mirrorCommitted, RCError *);
/* Must join the transaction that saves the verified remote result to the mirror.
   Subsequent local acceptance must compare the exact receipt, never blindly
   acknowledge a new local edit. Final Acknowledge requires this checkpoint. */
int RCWriteJournalResolutionMirrored(RCWriteJournal *, long long successorID, RCError *);
/* Consistent full-database recovery export, including raw resources, immutable
   intentions and receipts. Creates a new 0600 file; never overwrites a path. */
int RCWriteJournalBackup(sqlite3 *, const char *destination, RCError *);
int RCWriteETagIsStrong(const char *);

#endif
