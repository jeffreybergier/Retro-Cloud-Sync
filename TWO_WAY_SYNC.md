# Two-way creation and updates

Select **2-way** for Contacts or Calendars to enable local-to-iCloud uploads.
The default remains unchanged; existing OneWay/Disabled configurations do not
begin uploading after an upgrade. The daemon uses conditional **PUT**, not POST:
`If-None-Match: *` for a new resource, `If-Match` with the retained ETag for edits.
Mail continues independently. Network activity occurs outside Sync Services
sessions and SQLite transactions. Credentials remain in Keychain.

## Supported changes

Contacts support native creation, names, organization/department, notes,
job title, nickname, birthday, company display, and phone/email/address/URL
values, including adding/removing those multivalue entries. Existing labels,
parameters, photos, unknown fields and unedited structured components survive
updates. Changing the label/type or preferred status of an existing entry is
currently deferred when it cannot round-trip exactly. New contacts require
exactly one discovered address book; ambiguous destinations are deferred.

Calendars support edits to event summary, description, location, URL, status,
classification, and start/end dates in the existing date representation.
Existing recurrence sets, exceptions, zones and alarms remain intact when
editing supported event fields. Ordinary timed/all-day events with simple
relative display/audio alarms can be created inside imported iCloud calendars.
Local calendars are not converted into remote collections. New recurring or
scheduled events, recurrence/attendee/alarm structure changes, date-type
conversions, and edits to duration-based events that require date restructuring
are deferred. Calendar moves and tasks are also outside this first coordinator.

Every proposed resource is passed through the production forward mapper and
compared to the intended native graph before it can enter the outgoing queue.
A proposal that would silently lose mapped data is rejected, leaving the local
change pending. Raw remote bodies are patched rather than regenerated for edits.

**Deleting a contact or event locally never sends remote DELETE.** Removing a
phone/email/address/URL entry is an edit to its parent vCard and uses PUT.

## First enable and account isolation

Enabling two-way contacts uploads supported contacts already on the Mac to the
active iCloud account, including contacts created before the first sync. Saved
contact exclusions from earlier versions are cleared automatically for that
account. Existing imported identities are retained so those contacts are edited
rather than uploaded again as new resources. New contacts still require one
unambiguous destination address book.

For calendars, the first two-way session excludes unrelated existing native
roots. Events created inside a known imported iCloud calendar are eligible on
the first successful two-way session, including events made while initialization
was failing. Previously imported calendar resource identities remain excluded
from creation when their mapper is unavailable. Account changes retain separate
journals, calendar exclusions, identities and mirrors. Two-way work requires a
successful download; a locked Keychain or failed fetch never authorizes
collection from an incomplete mirror.

OneWay still imports only, and Disabled pauses work. Switching to OneWay while
there are unresolved outgoing operations defers publication so it cannot discard
the pending native intent. Existing identities survive mode changes.

## Durable completion and attention

The coordinator registers the same account's Sync Services client with a
separate two-way description. On Tiger, the description uses a distinct display
name and an explicit nonempty push-only list to update the existing registration
without unregistering it or resetting record identities. Tasks and smart groups
remain import-only; only pull-capable entities enter the pull phase. It pushes the complete remote graph, lets the
system mingle changes, captures native intentions and journals each whole
resource with its exact receipt in one transaction. It cancels unaccepted pulls
without refusing local changes. The writer then runs outside the session.

A lost response leaves the operation uncertain; a later GET verifies whether
that same operation already succeeded before attempting another PUT. New hrefs
and UIDs are durable and reused on retry. After a successful upload, a successful
mirror download supplies the resource identity for completion. For calendars, a newer remote revision does not block
completion: the coordinator reconstructs the journal's immutable, GET-verified
upload, checks the same UID and exact native receipt, acknowledges that upload,
and then publishes the newer downloaded revision. It sends no replacement PUT.
Native identities are associated with downloaded identities before accepting
changes, and that mapping survives interruption. A repeated completion does not
create another resource or accept an unrelated newer local revision.

A supported newer native edit before acknowledgement becomes a separate durable
update against the GET-verified upload's ETag and body. Retiring the older
operation and saving that successor happen in one transaction. The newer native
change is not accepted until its own upload is verified. A concurrent remote
edit still produces a conditional-write conflict; the coordinator never adopts
a later ETag to force an overwrite.

Unresolved queued, conflicting or applied resources are isolated during fast
publication and collection. Their native records, child records and calendar
containers remain untouched while unrelated resources can sync. A durable
publication checkpoint tracks explicit remote deletions during these partial
sessions. Partial sessions do not mark the full mirror as published or authorize
calendar history pruning. A forced Sync Services reset still requires recovery.
General conflict resolution and unsupported mappings remain attention conditions.

An uploaded resource deleted remotely or omitted by the calendar history window
before acknowledgement can complete from its saved verified bytes and receipt.
The forward mapper validates those bytes using the receipt's native identities;
completion does not require the resource to reappear or issue another PUT.
If its imported identity was not available, a separate checkpoint retains the
verified receipt for alias recovery on a later restoration, without holding the
upload queue open or accepting any later native change.
A resource replaced with a different UID at the same href remains isolated,
as do contact revisions whose child identities cannot be reconciled safely.

Use the daemon's existing `--inspect-recovery DATABASE` command to inspect
operation states and deferred-reason counts without exposing record bodies, and
`--export-recovery DATABASE NEW-SNAPSHOT` to create a consistent private backup.
These commands do not execute writes or resolve conflicts. There is no automatic
fallback to one-way and no blind overwrite/retry with a replacement ETag.

## Validation and live use

`make test-host`, `make release`, and `make analyze` validate the portable code,
legacy builds, and static diagnostics. `make test-mac-two-way TEST_HOST=x4-vm`
uses real Tiger Sync Services with synthetic data and a transport that cannot
reach iCloud. It tests reverse mapping, native creation/updates, identity replay,
conditional writes, interruption recovery and remote-deletion protection.

A logged-in iCloud account can stay logged in while building and running these
offline tests. Stop the production daemon before running native suites. Building
does not install or start the new daemon on the Mac. Live iCloud two-way behavior
has not been validated by these synthetic tests; use disposable data/account for
initial live validation before enabling two-way for valuable data.

The native regression suite begins with existing push-only clients, migrates
them in place, and checks contacts and a calendar event created before
initialization. It also checks automatic recovery of previously excluded
contacts, account-scoped migration, and replay without duplicate uploads. iCal's
local UID/sequence bookkeeping and omitted default event properties do not block
round-trip validation; other unsupported changes remain deferred.

`make test-mac-two-way TEST_HOST=x4-vm TWO_WAY_TEST_MODE=calendars` runs the
calendar subset, including a remote edit between PUT verification and the first
mirror download. It checks that the newer title reaches the original native
record without another PUT or duplicate, and that changed UIDs remain protected. It also covers a second local edit
before acknowledgement and completion when an upload leaves the history window.
Partial publication does not trigger history pruning.

`make test-mac-two-way TEST_HOST=x4-vm TWO_WAY_TEST_MODE=contact-publication`
checks a newer remote note arriving before the original contact creation is
acknowledged. The coordinator uses the journal's GET-verified upload to finish
that acknowledgement, then publishes the newer note on the same native contact
without another PUT. It requires an unchanged UID and child graph; changed or
reordered child records remain deferred rather than acquiring incorrect aliases.

The full offline suite also covers an uploaded contact deleted before its first
mirror download, a second local edit with a journal reopen before the successor
runs, and an unrelated contact uploading while another contact has a conflict.
Mapper regressions cover empty raw TEL/EMAIL/URL fields followed by visible
entries: note edits, field updates, removals and additions preserve the raw
occurrence identities and untouched empty fields.
