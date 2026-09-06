#ifndef RC_CONFLICT_RECOVERY_H
#define RC_CONFLICT_RECOVERY_H
#include "RCWriteJournal.h"
#include "RCDAVWriter.h"

typedef enum {
  RCConflictDeferred = 0,
  RCConflictResolved = 1,
  RCConflictNeedsAttention = 2
} RCConflictDisposition;

typedef struct {
  /* Owned output, freed by the coordinator. Receipt identifies the exact
     canonical decision, including deletions; it must survive process restart. */
  char *kind;
  void *body, *receipt;
  size_t length, receiptLength;
  const char *attentionReason; /* static diagnostic code, no private content */
} RCConflictDecision;

typedef struct {
  void *context;
  /* No SQLite transaction is open. Leave local changes unaccepted. A deferred
     result (user UI unavailable/cancelled) must leave the intent replayable. */
  int (*resolve)(void *, const RCWriteOperation *, RCConflictDecision *, RCError *);
  /* Runs inside the journal's transaction. Save verified remote bytes/ETag
     and identities, but do not call Sync Services or perform network requests. */
  int (*saveMirror)(void *, const RCWriteOperation *, RCError *);
  /* No SQLite transaction. Accept only the receipt's exact canonical revision,
     after checking server normalization is representable. Must be idempotent:
     a crash can happen after framework acceptance but before journal completion.
     A newer local edit must remain pending. Return 0 to defer completion. */
  int (*acceptLocal)(void *, const RCWriteOperation *, const void *receipt,
                     size_t receiptLength, RCError *);
} RCConflictCallbacks;

/* Resolve one conflict without network writes. Ineligible create collisions and
   edit/delete cases are kept for explicit review. Returns 1 for a durably handled
   decision or deferral; inspect successor (0 means no upload was queued).
   Eligible update/update decisions are produced by the canonical schema resolver. */
int RCConflictRecover(RCWriteJournal *, long long conflictID,
    const RCConflictCallbacks *, long long *successor, RCError *);
/* Complete a verified successor. Its original decision remains available even
   if the process dies during either store's acknowledgement. */
int RCConflictComplete(RCWriteJournal *, long long successorID,
    const RCConflictCallbacks *, RCError *);
#endif
