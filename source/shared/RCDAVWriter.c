#include "RCDAVWriter.h"
#include <stdlib.h>
#include <string.h>

static int desired(const RCWriteOperation *o, const RCHTTPResponse *r)
{
  return r->statusCode == 200 && RCWriteETagIsStrong(r->etag) && r->body &&
      r->bodyLength == o->desiredLength && o->desiredBody &&
      !memcmp(r->body, o->desiredBody, r->bodyLength);
}
static int record(RCWriteJournal *j, long long id, const char *state,
    const RCHTTPResponse *r, RCError *e)
{
  /* Error documents may contain private data; only retain resource GET bodies. */
  return RCWriteJournalRecordResult(j,id,state,(int)r->statusCode,r->etag,
      r->statusCode == 200 ? r->body : NULL,
      r->statusCode == 200 ? r->bodyLength : 0,e);
}
static int get(RCHTTPClient *c, const char *href, RCHTTPResponse *r, RCError *e)
{
  if (!RCHTTPClientRequest(c,"GET",href,NULL,NULL,NULL,0,r,e)) return 0;
  /* A changed canonical href needs explicit reconciliation, not mutation of
     the old href or adoption of an unrelated redirected resource. */
  if (!r->effectiveURL || strcmp(r->effectiveURL,href)) {
    RCErrorSet(e,1,"Outgoing resource changed its canonical URL"); return 0;
  }
  return 1;
}
int RCDAVWriterAttempt(RCWriteJournal *j, long long id, RCHTTPClient *client,
    const char *type, long long now, RCError *e)
{
  RCWriteOperation o;
  RCHTTPResponse remote, write;
  int ok = 0, deleting, creating;
  RCHTTPResponseInit(&remote); RCHTTPResponseInit(&write);
  if (RCCheckCancellation(e)) return 0;
  if (!RCWriteJournalGet(j,id,&o,e)) return 0;
  deleting = !strcmp(o.kind,"delete"); creating = !strcmp(o.kind,"create");
  if ((!creating && !RCWriteETagIsStrong(o.baseETag)) ||
      (!deleting && (!o.desiredBody || !o.desiredLength))) {
    RCErrorSet(e,1,"Outgoing operation has an invalid durable precondition"); goto done;
  }
  /* This commits before even the verification GET, including after a restart. */
  if (!RCWriteJournalBeginAttempt(j,id,now,e)) goto done;
  if (!get(client,o.href,&remote,e)) goto done;
  if ((deleting && remote.statusCode == 404) || (!deleting && desired(&o,&remote))) {
    ok = record(j,id,"applied",&remote,e); goto done;
  }
  if (remote.statusCode != 200 && remote.statusCode != 404) {
    ok = record(j,id,"uncertain",&remote,e); goto done;
  }
  if ((creating && remote.statusCode != 404) || (!creating &&
      (remote.statusCode != 200 || !remote.etag || strcmp(o.baseETag,remote.etag)))) {
    ok = record(j,id,"conflict",&remote,e); goto done;
  }
  if (!RCHTTPClientConditionalRequest(client,deleting ? "DELETE" : "PUT",o.href,
      type,o.desiredBody,o.desiredLength,creating ? NULL : o.baseETag,creating,&write,e))
    goto done; /* Already uncertain on disk: the server may have accepted it. */
  if (write.statusCode == 412) {
    if (!get(client,o.href,&remote,e)) goto done;
    ok = record(j,id,(remote.statusCode == 200 || remote.statusCode == 404) ?
        "conflict" : "uncertain",&remote,e); goto done;
  }
  if (write.statusCode < 200 || write.statusCode >= 300) {
    ok = record(j,id,"uncertain",&write,e); goto done;
  }
  if (!get(client,o.href,&remote,e)) goto done;
  if ((deleting && remote.statusCode == 404) || (!deleting &&
      (desired(&o,&remote) || (remote.statusCode == 200 && remote.bodyLength &&
       RCWriteETagIsStrong(write.etag) && RCWriteETagIsStrong(remote.etag) &&
       !strcmp(write.etag,remote.etag))))) {
    ok = record(j,id,"applied",&remote,e);
  } else {
    /* Without the write response ETag, changed server serialization cannot be
       distinguished from a concurrent edit. Preserve both versions for review. */
    ok = record(j,id,(remote.statusCode == 200 || remote.statusCode == 404) ?
        "conflict" : "uncertain",&remote,e);
  }
done:
  RCHTTPResponseClear(&remote); RCHTTPResponseClear(&write); RCWriteOperationClear(&o);
  return ok;
}
