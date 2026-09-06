# Conflict recovery

The recovery implementation uses the existing Sync Services server client for
canonical field decisions. It preserves remote-write conflicts in SQLite and
never changes an old operation's ETag to retry its old body.

The production app still runs one-way: local change collection and automatic
outgoing execution (concept phase 4) are not enabled by this change. The recovery
APIs and native adapter are built into the daemon and exercised by an offline
Tiger integration suite. They are the contacts-first integration milestone, not
a claim that general two-way contacts/calendars synchronization is complete.

## Durable operation lifecycle

`RCWriteJournalResolveConflict` atomically creates a successor operation, links
it to the original through `write_resolutions`, and retires the old conflict.
The original base, desired body and observed remote result remain immutable.
The successor uses the conflicting remote body/ETag as its base, and stores the
canonical resolution as an opaque receipt. The published `write_bases` snapshot
is not advanced by this step. Identical replays return the same successor;
different decisions cannot replace a committed resolution.

Choosing the remote version also creates a successor. Its ordinary writer GET
can confirm that the intended bytes already exist, without sending PUT. A later
remote change produces another conflict rather than being overwritten. The
existing writer supplies bounded retries and conditional writes.

`RCConflictRecover` calls the resolver outside SQLite transactions. Create
collisions, edit/delete conflicts, unusable ETags and unsupported mappings become
durable `write_attention` reason codes. A deferred system session leaves the
original conflict intact. `RCWriteJournalRecoveryNext` scans conflicts and
verified successors after a supplied operation ID, so a deferred resource need
not prevent other resources from progressing. Reset the cursor each poll.

`RCConflictComplete` checkpoints the confirmed mirror result and
`mirror_committed` in one SQLite transaction, then invokes local acceptance
outside it. The final journal acknowledgement follows framework acceptance.
If the process dies after either commit, replay resumes from the durable state.
The acceptance callback must recognize an already accepted receipt and must
never accept a different, newer local revision. The native helper defers when
the local record has changed; that operation remains applied and its newer local
change remains pending for the future outgoing coordinator to reconcile.

## Native session adapter

`RCSyncResolveConflictWithIntent` uses the existing client's identifiers and
snapshots. It first verifies that the pending local field values still exist,
then submits the complete remote graph and enters mingling. It reads the
post-mingling snapshot because a remote-winning choice need not appear in the
pull enumerator. Missing targets are deferred, never interpreted as permission
to delete or recreate a resource.

The helper cancels the pull transaction without refusing or accepting changes.
Refusing would suppress changes on subsequent fast syncs. The push/mingling
phase may already have committed; submitting the same remote revision again is
safe while the outgoing local decision remains journaled.

The caller must provide the **complete** graph belonging to that client,
including retained records, since the engine may require a slow sync. It must
serialize all sessions, imports and recovery for the account. Push-only clients
and pull-truth resets are rejected. Changing the production client description
or registering an alternate client to manufacture a conflict is not part of this
implementation.

`RCSyncAcceptConflictResolution` compares the receipt to the current canonical
snapshot before accepting any target. It commits only matching targets and
cancels the remaining pull, preserving unrelated changes. A changed/deleted
target or forced full resync defers acceptance. It does not choose values or
automate the user's Conflict Resolver choices.

## Initial contact mapping

`RCContactRecoverConflict` connects the journal coordinator to the system
session adapter for NOTE, TITLE and NICKNAME value edits. The complete supplied
graph must describe the operation's published contact/child identities; the
adapter substitutes the newer remote text fields. Other mapped properties must
remain unchanged across the base and remote resource. Locally changed unknown
fields, grouped/duplicate text properties, encoding/type changes and multivalue
changes require attention. UID changes are rejected.

The selected values are patched into the latest remote vCard. Unknown remote
properties, photos, parameters and untouched physical lines are preserved.
The completion adapter checks the confirmed server body for mapped changes
before accepting the exact serialized receipt.

Full reverse contact mapping, calendar recurrence/child mapping, explicit
edit/delete resolution, and collecting a new local revision while an older
applied operation awaits completion remain part of the two-way coordinator work.
The generic journal and session helpers are reusable for calendars; automatic
calendar conflict resolution is not enabled.

## Inspection and recovery snapshots

On the Mac, the embedded daemon supports these commands without starting the
service, accessing Keychain, opening a Sync Services session or using the network:

```sh
RetroCloudSyncDaemon --inspect-recovery /path/to/Contacts.sqlite
RetroCloudSyncDaemon --export-recovery /path/to/Contacts.sqlite /path/to/new-snapshot.sqlite
```

Inspection is a read-only diagnostic listing operation IDs, kinds, states and
attention reason codes. It does not print hrefs, account names or record bodies.
Export uses SQLite's backup API to obtain a consistent whole-database snapshot,
including raw data and all three conflict versions. It creates a new file with
mode 0600 and refuses to overwrite an existing destination. Calendar databases
support the same commands. Export is available before bidirectional deletion.

## Verification

```sh
make test-host-writes
make build-mac-conflict-tests
make test-mac-conflicts TEST_HOST=x4-vm
```

Host tests cover interrupted resolution insertion, repeated remote races,
immutable ancestry, exact replay, account isolation, deferred/attention cases,
mirror rollback, crashes after local acceptance, newer local edits, independent
queued work, and recovery snapshot consistency/permissions.

The native test uses two separate synthetic server clients and Apple's Contacts
schema. It exercises the production contact adapter through the journal,
verifies different-field merging, the system's same-field decision, exact and
repeated acceptance, newer local edits, missing intent, edit/delete attention,
and preservation of unknown vCard fields/photos. Remote HTTP outcomes are
synthetic; the framework and its canonical snapshots are real. System policy may
resolve same-field conflicts automatically: the test does not assert that a
Conflict Resolver window must appear or automatically choose a conflict value.

The runner uses the existing contacts Desktop lock, refuses to run with the
production daemon active, snapshots existing Address Book contents, verifies the
baseline after cleanup and retains failure artifacts. It automatically allows
only sync alerts naming "Retro Cloud Conflict Tests". Interrupted runs retain
their journal/fixture marker under Desktop; the harness refuses to reuse an
existing test client until it has been recovered. All remote work stays under
`~/Desktop`; no Mach-O executable runs on Linux.

To recover an interrupted native test, stop the test process, then run
`./ConflictSessionTests --cleanup` in its original Desktop run directory from
Terminal. This reads that run's fixture marker, removes its synthetic record and
unregisters its two test clients. Inspect the Desktop lock's owner/process before
removing a stale lock directory; never start a second suite over an active run.
