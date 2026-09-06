# Remote write foundations

Contacts and Calendars still run one-way. The daemon records publication bases,
but does not collect local edits, enqueue writes, or run the outgoing writer.
The shared APIs provide durable state, conditional transport, recovery and value
editing for the future two-way coordinator. Fresh databases are required:
Contacts schema 4 and Calendars schema 2. There is no migration.

## Publication bases

Both databases contain account-scoped `write_bases`: resource key, exact href,
ETag, raw body and `local_revision` (the published inventory generation). Bases
commit with successful Sync Services publication, after the session finishes.
A download alone does not advance them. Failed publication preserves old bases.

Contacts retain `usable_etag` beside `usable_vcard`; Calendars retain
`export_etag` beside `export_ical`. If a malformed or unsupported replacement
causes an older body to be published, its base retains that older body's ETag.
An older body must never authorize an update with a newer replacement's ETag.
Keys are the contact's `sync_record_id`, or `resource-<id>` for a whole calendar
resource, including its recurrence exceptions.

## Outgoing operations

`RCContactStoreWriteJournal()` and `RCCalendarStoreWriteJournal()` return borrowed
account/connection handles. Use them from the owning account worker. The caller
must serialize writers for an account and supply matching DAV credentials.
Network work runs outside SQLite and Sync Services transactions.

`RCWriteJournalEnqueue()` commits an immutable operation with a stable local
change ID, resource key, href, create/update/delete kind, local revision, base
ETag/body and intended replacement body. It also tracks state, attempts, next
retry time, HTTP status and confirmed/conflicting remote ETag/body.

Updates/deletes require a strong ETag and the exact published revision. Creates
require revision zero and a caller-chosen stable href reused on every retry.
Replaying identical input with the same change ID returns the same operation,
even after acknowledgement. Reusing its ID with different input fails. Only one
unresolved operation per resource key or href is allowed in an account. Later
downloads/publications cannot change a queued operation's base or intended body.

## Editing retained bodies

`RCResourceEnqueueEdits()` patches the published base and queues an update:

```c
RCWriteJournal journal = RCContactStoreWriteJournal(store);
RCResourceEdit edit = { 0, "NOTE", NULL, 0, "Updated note\\nSecond line" };
long long operationID;
int ok = RCResourceEnqueueEdits(&journal, stableLocalChangeID,
    contactSyncRecordID, publishedGeneration, RCResourceVCard,
    &edit, 1, &operationID, &error);
```

Selectors address the immutable base: component number in BEGIN order, property
name, optional vCard group, and occurrence within that component. Occurrence -1
appends; a NULL value deletes an existing property. All edits address the original
input, so deleting repeated properties does not shift subsequent selectors.
Values must already be encoded for vCard/iCalendar. Literal newlines are rejected;
output lines are folded without splitting UTF-8 characters.

Only supported contact/event/alarm value fields can change. Structural/identity
properties such as UID, VERSION and RECURRENCE-ID cannot change. Parameters on
edited properties are retained; untouched physical lines are copied verbatim,
including unknown extensions, photos, VTIMEZONE, other alarms and detached
instances. Both input and output must parse. Missing/overlapping selectors fail.

This is a value-editing primitive, not a complete reverse Sync Services mapper.
Parameter/value-type changes (such as date-only to timed events), mapping native
creations and identifying which fields changed still require that mapper.

## Execution and recovery

`RCWriteJournalNext()` finds due queued/uncertain operations.
`RCDAVWriterAttempt()` commits `uncertain` and a bounded exponential retry time
before network work, then GETs the fixed resource href:

- Exact desired bytes with a strong ETag mean create/update is already applied.
  A 404 means delete is already applied. Neither needs another mutation.
- Otherwise update/delete can proceed only against the original base ETag;
  create can proceed only if the resource is absent.
- A changed version or create collision becomes `conflict`, retaining the remote
  version alongside the base and local intent.

PUT uses `If-Match` for updates and `If-None-Match: *` for creates; DELETE uses
`If-Match`. A 412 is followed by GET and retained as a conflict. There is no blind
overwrite or automatic merge. Transport failures and unsuccessful HTTP responses
remain uncertain for retry. Conditional requests never follow redirects, and a
changed canonical GET href is not automatically adopted as a mutation target.

After a successful mutation, GET confirms the result. Matching the successful
PUT response ETag to the GET ETag can identify a server-normalized body. If that
response was lost and remote bytes differ, the writer conservatively records a
conflict: normalization cannot be distinguished from a concurrent edit.

`applied` means verified remote success was recorded, not local acknowledgement.
The future coordinator must commit the confirmed result to its mirror and accept
the corresponding Sync Services change before calling
`RCWriteJournalAcknowledge()`. This call can join the mirror transaction and only
accepts applied operations. Applied records survive crashes so local completion
can be replayed. Queued/conflicting operations can be explicitly cancelled;
uncertain operations cannot be silently discarded. History is retained.
Conflict merge policy, local acknowledgement coordination and history pruning
remain future work.

## Tests

`make test-host-writes`, also in `make test-host`, covers process termination
after remote create/update/delete, lost responses, conditional-write races,
normalization, later remote edits, retries, account isolation, immutable bases,
idempotent replay, publication snapshots and field preservation. A local TLS
fixture exercises the production HTTP client with conditional headers, redirects,
disallowed hosts, hostname mismatch and untrusted certificates. This uses the
Linux curl runtime; Mac runtime/network validation remains separate.

Tests require native dependencies, libcurl development files, Python 3 and the
OpenSSL command-line tool. Fixtures are synthetic and temporary. They do not use
iCloud credentials or contact iCloud.
