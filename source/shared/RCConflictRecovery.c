#include "RCConflictRecovery.h"
#include <stdlib.h>
#include <string.h>

int RCConflictRecover(RCWriteJournal *j, long long id,
    const RCConflictCallbacks *callbacks, long long *successor, RCError *e)
{
  RCWriteOperation o;
  RCConflictDecision decision;
  int disposition, ok=0;
  *successor=0;
  memset(&decision,0,sizeof(decision));
  if (!sqlite3_get_autocommit(j->db) || !callbacks || !callbacks->resolve) {
    RCErrorSet(e,1,"Conflict recovery requires a resolver outside a transaction"); return 0;
  }
  if (!RCWriteJournalGet(j,id,&o,e)) return 0;
  if (strcmp(o.state,"conflict")) {
    RCErrorSet(e,1,"Operation is not awaiting conflict resolution"); goto done;
  }
  if (strcmp(o.kind,"update") || o.httpStatus!=200) {
    ok=RCWriteJournalConflictAttention(j,id,!strcmp(o.kind,"create") ?
        "create-collision" : "edit-delete",e); goto done;
  }
  if (!RCWriteETagIsStrong(o.resultETag) || !o.resultBody || !o.resultLength) {
    ok=RCWriteJournalConflictAttention(j,id,"unusable-remote-revision",e); goto done;
  }
  disposition=callbacks->resolve(callbacks->context,&o,&decision,e);
  if (disposition==RCConflictDeferred) { ok=1; goto done; }
  if (disposition==RCConflictNeedsAttention) {
    ok=RCWriteJournalConflictAttention(j,id,decision.attentionReason ?
        decision.attentionReason : "unsupported-mapping",e); goto done;
  }
  if (disposition!=RCConflictResolved) goto done;
  /* Native deletion decisions need their own verified policy; don't silently
     turn a missing/filtered canonical record into a remote DELETE. */
  if (!decision.kind || strcmp(decision.kind,"update")) {
    ok=RCWriteJournalConflictAttention(j,id,"edit-delete",e); goto done;
  }
  ok=RCWriteJournalResolveConflict(j,id,decision.kind,decision.body,decision.length,
      decision.receipt,decision.receiptLength,successor,e);
done:
  free(decision.kind); free(decision.body); free(decision.receipt);
  RCWriteOperationClear(&o); return ok;
}

int RCConflictComplete(RCWriteJournal *j, long long id,
    const RCConflictCallbacks *callbacks, RCError *e)
{
  RCWriteOperation o;
  void *receipt=NULL;
  size_t length=0;
  int mirrored=0, ok=0;
  if (!sqlite3_get_autocommit(j->db) || !callbacks ||
      !callbacks->saveMirror || !callbacks->acceptLocal) {
    RCErrorSet(e,1,"Conflict completion requires callbacks outside a transaction"); return 0;
  }
  if (!RCWriteJournalGet(j,id,&o,e)) return 0;
  if (!RCWriteJournalResolutionReceipt(j,id,&receipt,&length,&mirrored,e)) goto done;
  if (!strcmp(o.state,"acknowledged")) { ok=1; goto done; }
  if (strcmp(o.state,"applied")) {
    RCErrorSet(e,1,"Resolution has no verified remote success"); goto done;
  }
  if (!mirrored) {
    if (sqlite3_exec(j->db,"BEGIN IMMEDIATE",NULL,NULL,NULL)!=SQLITE_OK) goto sqlError;
    if (!callbacks->saveMirror(callbacks->context,&o,e) ||
        !RCWriteJournalResolutionMirrored(j,id,e)) {
      sqlite3_exec(j->db,"ROLLBACK",NULL,NULL,NULL); goto done;
    }
    if (sqlite3_exec(j->db,"COMMIT",NULL,NULL,NULL)!=SQLITE_OK) {
      sqlite3_exec(j->db,"ROLLBACK",NULL,NULL,NULL); goto sqlError;
    }
  }
  if (!callbacks->acceptLocal(callbacks->context,&o,receipt,length,e)) goto done;
  ok=RCWriteJournalAcknowledge(j,id,e);
  goto done;
sqlError:
  RCErrorSet(e,1,"Conflict completion database error: %s",sqlite3_errmsg(j->db));
done:
  free(receipt); RCWriteOperationClear(&o); return ok;
}
