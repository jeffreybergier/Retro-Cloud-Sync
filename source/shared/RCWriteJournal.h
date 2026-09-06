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
int RCWriteETagIsStrong(const char *);

#endif
