# Two-way sync

Select **2-way** for Contacts or Calendars to enable local-to-iCloud uploads.
The default remains unchanged; existing OneWay/Disabled configurations do not
begin uploading after an upgrade. The daemon uses conditional **PUT** for creation/edits and **DELETE** for removal:
`If-None-Match: *` for a new resource, `If-Match` with the retained ETag for edits and deletions.
Mail continues independently. Network activity occurs outside Sync Services
sessions and SQLite transactions. Credentials remain in Keychain.

## Supported changes

Contacts support native creation, names (including phonetic first/middle/last
and company names), organization/department, notes, job title, nickname,
birthday, company display, photos, phone/email/address/URL values, anniversaries
and custom dates, related names, and Tiger IM accounts. Child entries can be
added, edited and removed. Existing labels/types, address country codes and
preferred phone/email/address/URL selections can change. Custom labels on
ungrouped properties receive a separate vCard group to avoid relabelling other
entries. Unknown parameters are preserved; unsafe or ambiguous representations
remain pending. IM import supports IMPP and legacy X-AIM/X-JABBER/X-MSN/X-YAHOO/
X-ICQ. Service changes convert legacy properties to IMPP in place, retaining
identity and unrelated parameters. New IM entries use IMPP.
New contacts require
exactly one discovered address book; ambiguous destinations are deferred.

Embedded vCard `PHOTO;ENCODING=b` data maps to the native `image` field.
Creation, replacement and removal are supported without image transcoding;
untouched photo bytes and unrelated properties remain intact. The writer folds
base64 lines and identifies JPEG, PNG, GIF and TIFF when possible. URI photos on
the account’s HTTPS iCloud hosts are fetched with the account HTTP client before
native sessions. Images are cached by account, contact href,
ETag and photo URI; a card GET after the image download confirms that version.
Successful upload versions are cached before later downloads can supersede them.
Unavailable images remain pending rather than being interpreted as removals.
Malformed or repeated photos remain opaque during unrelated edits; replacing an ambiguous repeated photo stays pending. Image data must be
binary (`NSData`).

Calendars support edits to event summary, description, location, URL, status,
classification and start/end dates, including conversion between timed and
all-day events. Display/audio reminders can be added, removed or edited,
including relative/absolute triggers and repeat intervals. Recurring events
can be created and their rules edited or removed using the daily/weekly/monthly/
yearly rules representable by Tiger's schema. Attendee and organizer fields,
including RSVP and participation status, can be created and edited. These
changes are conditional calendar resource writes; server scheduling policy and
permissions still determine invitation delivery. Offline tests do not verify
iCloud invitation delivery.

Structural edits clone the affected components, retain unrepresented extensions,
and pass the production forward mapper before entering the outbox. Untouched
components retain their physical bytes. Floating dates retain their native
floating marker and upload without a Z suffix or TZID. Zoned date edits use the
original resource's timezone rules, including for exclusions and new detached
instances, rather than looking up the same name in Tiger's timezone database.

Finite RDATE/EXRULE and differing-timezone series can be imported through the
bounded projections described in README.md. Their synthesized recurrence/date
structure is protected from local structural edits. Ordinary text edits can
upload when the complete projected graph round-trips; for a differing-zone
series with synthesized instances, this includes consistent whole-series notes.
An edit to only a synthesized occurrence remains pending. Original RRULE,
RDATE/EXRULE and VTIMEZONE bytes are retained on upload. Email alarms, tasks and
other unsupported structures remain pending.

New writable local calendars created after the first feature-enabled sync can
be created remotely when one calendar home is unambiguous. Existing local and
subscription calendars are not automatically migrated. A persistent creation
marker and PROPFIND verification recover an uncertain MKCALENDAR response.
Events can move between imported calendars on the same host using conditional
MOVE with `Overwrite: F`. The move is verified at both source and destination
before updating the mirror, retaining the event's local identities. Occupied
destinations and changed source versions remain conflicts. Pending collection
operations protect local records and prevent a switch to one-way publication
from discarding the pending edit. Recovery inspection lists their state.

The coordinator projects local changes onto each encoder's supported fields,
then validates the resulting resource through the production forward mapper.
Existing raw bodies are patched, preserving unknown properties, parameters,
unedited photos and components. Unknown native fields are not placed in the represented
upload graph and are not treated as synchronized. Their field names are stored
in `two_way_pending_fields` and reported in the daemon log when that set changes;
the actual values remain in Sync Services. Previously observed opaque fields
that become absent retain a pending deletion marker until a mapper can
represent them; absence alone does not prove their remote data was deleted.

An unsupported contact field or an unfamiliar event field does not block a note,
phone value or event text edit. Unrepresentable fields remain pending while independent edits proceed. Changes to
unrepresentable recurrence structure or all-day dates also defer dependent date and
exception edits, preventing a partial update from mixing incompatible temporal
representations. If the wire format prevents an otherwise supported edit (for
example, a legacy-encoded note or DURATION-based dates), independent field groups
are retried against the original raw resource. Only groups that pass the strict
mapper enter the receipt; the failed group stays pending. Identity changes and
ambiguous destinations still fail safely.

New contacts and ordinary events may be created with supported fields while
other fields remain pending locally. This is partial creation, not an assertion
that every field uploaded. Recurrence and scheduling children must round-trip
as part of the created event; unsupported structures are never silently
simplified to ordinary events.

Each outgoing operation atomically saves its represented graph and immutable
field scope in `two_way_field_scopes`. Verification still checks the complete
represented graph against the server result. Completion compares native truth
only within that saved scope, so a newer supported edit queues a conditional
successor but an unsupported edit does not cause duplicate PUTs. Sync Services
accepts whole records, so records with any additional local differences are
left unaccepted there even after the verified server operation completes.
Unrelated native fields are never accepted using a fabricated full receipt.
Older journal entries without scopes retain exact whole-record acceptance.
Server verification of pre-photo receipts excludes newly mapped images that
were absent from both the saved graph and scope. Photos represented by an
upload still require exact verification.

**Deleting a contact or event locally propagates to iCloud in 2-way mode.**
The coordinator requires an explicit Sync Services deletion change for a known
resource, a strong ETag, and disappearance of its whole native graph. Removing
just a recurrence instance or leaving live child records does not authorize a
whole-resource deletion. Missing records, failed downloads, history-window
exclusion and forced resets do not authorize DELETE. Removing a
phone/email/address/URL entry remains an edit to its parent vCard and uses PUT.

A deletion is journaled with its exact native tombstones and resource identities.
The writer verifies absence with GET, including after a lost DELETE response.
Completion waits for the successful mirror to omit the resource and accepts only
those tombstones. A newer native restoration remains pending for attention;
stale mirror bytes cannot be published over it while deletion completion is open.

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
Unsupported mappings remain attention conditions.

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
operation states, deferred-reason counts and pending field names without exposing
record bodies, and
`--export-recovery DATABASE NEW-SNAPSHOT` to create a consistent private backup.
These commands do not execute writes or resolve conflicts. There is no automatic
fallback to one-way and no blind overwrite/retry with a replacement ETag.

## Conflict resolution

Production contacts and calendars now reconcile write conflicts through their
existing Sync Services client. A fast session publishes only the conflicted
resource's GET-observed remote revision, keeping unrelated pending resources
and calendar containers isolated. Sync Services chooses canonical field values;
system policy may merge different fields or decide a same-field conflict
without displaying a Conflict Resolver window. The coordinator does not choose
an unconditional local-wins or remote-wins policy.

The existing reverse mapper validates the canonical result, so conflict recovery
supports the same editable fields as ordinary updates. The chosen body, exact
native receipt and resource identity are saved atomically with a new conditional
operation; the original operation and its ETag are immutable. Choosing existing
remote bytes still queues verification, which can finish without PUT. A second
remote race produces another conflict. Newer local changes are captured in the
canonical receipt and are never acknowledged as an older upload.

Edit/delete conflicts also pass through Sync Services. A writer GET 404 is the
only evidence that permits presenting a whole-resource remote deletion. A
canonical local survivor can be recreated at the same href with
`If-None-Match: *`; a canonical deletion is verified before acknowledgement.
A canonical local deletion against a changed remote resource uses that
conflict revision's ETag, never an unconditional DELETE.

Changed UIDs, ambiguous contact child identities (including remote child edits
or reordering), unsupported canonical structures and forced full resets remain
attention conditions. Recovery does not guess identities or drop unsupported
data. Older operations without a saved resource graph are recovered only when
the existing projector can reconstruct their identity safely.

## Validation and live use

`make test-host`, `make release`, and `make analyze` validate the portable code,
legacy builds, and static diagnostics. `make test-mac-two-way TEST_HOST=x4-vm`
uses real Tiger Sync Services with synthetic data and a transport that cannot
reach iCloud. It tests reverse mapping, native creation/updates, identity replay,
conditional writes, interruption recovery, local deletion propagation and conflict isolation.

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

The native recovery tests cover contact deletion with a lost response and a
reopened journal, contact different-field and same-field conflicts, a local
contact edit racing remote deletion, calendar field conflicts, event deletion,
and a remote event edit racing local deletion. They compare canonical native
values and require all successors to complete without duplicate mutations.
`TWO_WAY_TEST_MODE=recovery` runs these with the existing upload-recovery cases;
`TWO_WAY_TEST_MODE=edit-delete` isolates the contact edit/delete case.

`TWO_WAY_TEST_MODE=fields` exercises field-scoped uploads against real Sync
Services using synthetic contacts: image-plus-note edits, creation with
photos and address/homepage children, iCloud-style URI photo conversion, removal,
versioned photo caches, journal reopen, newer supported edits and replay
without duplicate PUTs. Mapper fixtures also cover unknown fields and calendar
date dependencies while checking preservation of untouched wire properties.
