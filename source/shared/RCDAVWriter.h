#ifndef RC_DAV_WRITER_H
#define RC_DAV_WRITER_H
#include "RCWriteJournal.h"
#include "RCHTTPClient.h"
/* Perform one due attempt, including read-after-write verification. A return of
   1 means the result was journaled, not that a write succeeded: inspect state.
   No Sync Services acknowledgement is performed here. A single account worker
   must own execution; callers must not run concurrent writers for an account.
   Supply a client authenticated for this journal's account. */
int RCDAVWriterAttempt(RCWriteJournal *, long long operationID, RCHTTPClient *,
    const char *contentType, long long now, RCError *);
#endif
