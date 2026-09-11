# Retro-Cloud-Sync
Sync iCloud Email, Contacts, Calendars with Retro Macs 10.4+

## Source layout

- `source/macOS-app`: the graphical application and its bundle resources.
- `source/macOS-daemon`: the production background service embedded in the app;
  runs the mail proxy and Contacts/Calendars synchronization.
- `source/shared`: reusable synchronization, parsing, and storage code.
- `source/tests`: portable regressions, Mac integration suites, fixture generators
  and optional experiments. See the [test index](source/tests/README.md).
- `source/probes/macOS`: manual CardDAV/CalDAV diagnostics that read live servers
  into local databases.
- `source/make`: build rules for the application, libraries, and test tools.
- `source/make/scripts`: dependency build and relinking scripts, parser patches,
  and portability helpers.
- `source/deps/libical`: upstream libical Git submodule, pinned to `v3.0.20`.
- `source/deps/libvc`: upstream libvc Git submodule, pinned to `v013`.

Initialize dependencies after cloning (or clone with `--recurse-submodules`):

```sh
git submodule update --init --recursive
```

Build the probes with `make build-mac-carddav-probe` and
`make build-mac-caldav-probe`, with binaries under `build/probes/macOS/carddav` and `build/probes/macOS/caldav` respectively.

## Tests and diagnostics

Run `make help` for the command index or read [source/tests/README.md](source/tests/README.md)
for coverage, runtime requirements, artifacts and compatibility aliases.
`make test-host` runs all normal Linux regressions; `make build-mac-tests` builds
all normal Mac test tools without running them. `test-mac-app` and
`test-mac-network` separately exercise the GUI and the HTTPS diagnostic.

## Daemon status

The **Daemon** pane shows independent Contacts and Calendars status with colored
Font Awesome icons: green for a complete sync, yellow for waiting, work in
progress or pending items, and red for errors. Each service keeps its last
successful sync time and shows its next attempt or pending-item count. **Log** in the
toolbar opens the application's Log pane. Stopped services retain their last
successful times and appear paused.

The daemon owns phase, error and completion decisions and atomically writes
`Status.plist` beside `Configuration.plist`, with mode 0600. The GUI reads it
every two seconds and checks process liveness so a stopped/crashed daemon does
not appear to be syncing. Snapshots contain structured status and a hashed
account identity, not passwords, record bodies or raw error messages. Switching
accounts resets the displayed success history. A cached import after a failed
download does not advance the success time; neither do pending uploads,
unsupported mappings or unresolved local changes. Pending items count journal
operations and attention entries, not unique contacts/events.

## Contacts and Calendars preferences

Open the application and choose **Sync** in the toolbar. Enter the Apple ID
used for iCloud, an app-specific password, select a sync mode for Contacts and
Calendars, and choose the desired sync interval. The password is stored in the user's
login Keychain and is never written to the configuration file or LaunchAgent.
Saving or removing an account restarts an already-running background service
so the new settings take effect.

Contacts and Calendars each support a one-way iCloud mirror and Sync Services
import. Either can run independently; a failure in one does not skip the other.
The configuration stores `ContactsSyncMode` and `CalendarsSyncMode` as
`Disabled`, `OneWay`, or `TwoWay`. Legacy `Enabled` and `CalendarsEnabled`
booleans remain in the plist for compatibility. **2-way** enables conditional
uploads of supported local creations and edits, including contacts already on
the Mac when two-way sync is enabled. Previously excluded local contacts become
eligible automatically. Local contact/event deletions propagate with conditional
DELETE, and supported conflicts reconcile through Sync Services. See [TWO_WAY_SYNC.md](TWO_WAY_SYNC.md) for the supported fields,
first-sync behavior, failure handling, and testing boundaries. Supported fields
can upload while other local fields remain pending; the daemon log identifies
unsynced fields. Embedded contact photos now sync in both directions, including
replacement and removal. New records may be partially created
with their supported fields. Contact labels, preferred entries, phonetic names,
extra dates, related names and IM accounts are supported. Calendars support
reminder edits, recurrence rules, all-day conversion, participants/RSVP, new
local calendar creation and conditional event moves; see the two-way guide for
representation and destination limits.

The shared write-safety foundations now include durable outgoing operations,
published base revisions, conditional DAV writes with interruption recovery,
and edits that preserve unrecognized resource fields. The two-way coordinator connects these APIs to native change collection and
automatic conditional PUTs. See
[WRITE_SAFETY.md](WRITE_SAFETY.md) for the state machine, APIs and tests.
Conflict recovery now has durable successor operations, exact acknowledgement
receipts, a Sync Services adapter and a tested initial contact text-field mapper.
The daemon also provides read-only recovery inspection and consistent database
exports. See [CONFLICT_RECOVERY.md](CONFLICT_RECOVERY.md) for supported cases,
remaining two-way integration work and the native Tiger test command.
Contacts requires schema 4. Calendars uses schema 3 and automatically upgrades
schema 2 while retaining cached data and Sync Services identities. Earlier test
database schemas still require fresh databases.

Sync tokens are used automatically when a collection advertises DAV sync
support. Each database gains a small `dav_sync_state` table without replacing
existing resources or identities. Tokens are scoped to the account and collection
URL and commit in the same transaction as the downloaded data. Failed downloads,
incomplete pages and interrupted processes leave the previous token and mirror
intact. A completed download may advance the token before Sync Services publication;
the existing publication generation handles retrying that local export.

Contacts initially obtain a complete `sync-collection REPORT` inventory, then
request only additions, modifications and explicit deletions since the saved
token. Unmentioned contacts remain present. Reports request pages of 200 changes;
server continuation tokens are followed before committing the account. Expired
tokens trigger an initial resync; unsupported reports fall back to the existing
full ETag inventory. Authentication failures, transport errors and malformed
reports abort the run rather than authorizing deletions. Collection removal also
retires its saved token, so recreation starts with a complete inventory.

Calendars use a sync report to check whether the saved collection changed. An
empty change report preserves the cached window and skips its resource inventory.
Changes, a new UTC history cutoff, or a changed history preference refresh the
server-filtered inventory. This keeps recurrence/window membership on the server
and avoids downloading changed resources outside the selected window. The saved
token is obtained **before** that inventory, so edits during the fetch are checked
again next time. Initial sync and expired-token recovery retain the selected
window. Servers without sync support continue using the existing inventory path.

The implementation follows [WebDAV collection synchronization (RFC 6578)](https://datatracker.ietf.org/doc/html/rfc6578).
Collection discovery still runs each poll. Changed bodies are still fetched
individually; Sync Services still publishes the complete retained graph. Sync
tokens optimize remote discovery of changes, not local publication or two-way sync.

When enabled, the daemon downloads contacts immediately after it starts and
then at the configured interval. Its read-only mirror is stored at:

```text
~/Library/Application Support/RetroCloudSync/Contacts.sqlite
```

Contact download errors do not stop the mail proxy; they are written to the
daemon log and retried at the next interval. Choose **Log** in the application
toolbar to follow that log. It is stored at:

```text
~/Library/Logs/RetroCloudSync/RetroCloudSyncDaemon.log
```

Daemon messages pass through a shared C/Objective-C logger into `NSLog`, retaining
its timestamp and process information. Messages use `INFO`, `WARN`, `ERROR`, or
`DEBUG`, followed by the service and phase. Sync messages include a poll number;
mail connections have separate connection numbers. Download completion, local
application, and verified uploads are reported separately. Counts distinguish DAV
resources from internal Sync Services records.

Normal logging omits discovery and per-resource download chatter. To enable those
details, set `RETROCLOUDSYNC_LOG_LEVEL=DEBUG` in the daemon's environment before
starting it (for a LaunchAgent, use its `EnvironmentVariables` dictionary).
Messages are bounded and flattened to a single line; raw Sync Services exception
reasons and protocol bodies are not included. The GUI displays the last 1 MiB;
this is a display limit, not disk log rotation.

In one-way mode, the daemon submits the last complete contact inventory to
Tiger's Sync Services Contacts schema, even if the latest download or Keychain
access failed. This mode uses a push-only bridge:
it does not upload Address Book edits to iCloud or treat existing local Address
Book cards as CardDAV records. Tiger's Address Book application identifier is
`com.apple.AddressBook`; the separate Sync Services data class is named
`com.apple.Contacts`.

Contacts are scoped by account in SQLite and use a separate stable Sync Services
client per account. Switching accounts pauses publication of the previous
account's cached contacts; it does not remove them from Address Book. Returning
to an account reuses its contact and child identities. Account names compare
case-insensitively. The new contact schema requires a fresh database; there is no
migration from the earlier unscoped schema.

A contact inventory commits atomically after successful home discovery and
complete downloads from every address book. A vanished address book, including
a successfully discovered empty home, retires its contacts only in that account.
Failed or interrupted runs keep the previous complete inventory available.
`accounts.generation` and `published_generation` record durable download and
publication progress; publication is acknowledged only after Sync Services
finishes. A new account with no complete inventory is never published as empty.

Malformed downloaded vCards are retained in `contacts.raw_vcard` with a
`parse_error`. Their last usable body stays in `usable_vcard`, with matching
parsed properties and child identities, so one bad card does not block other
contacts. A malformed new card stays cached until a usable revision arrives.
The daemon log and CardDAV probe report invalid-resource counts. The bridge
builds the complete contact graph before opening a Sync Services session.

When Start installs a changed daemon binary, the app refreshes its login
Keychain access and may request upgrade approval. Ordinary starts preserve the
installed binary and saved access rules. An interrupted upgrade approval is
retried on the next Start; the saved app-specific password is retained.

## Calendar database and iCal import

With Calendars set to **1-way**, the daemon downloads calendars immediately and
at the shared sync interval. The database is:

```text
~/Library/Application Support/RetroCloudSync/Calendar.sqlite
```

In **Sync → Calendar**, **Past events** selects **Last 1 year**, **Last 2 years**
(the default), or **All history**. The rolling cutoff is midnight UTC on today's
date one or two calendar years ago (February 29 clamps to February 28).
All future events are included. The daemon uses a CalDAV `calendar-query REPORT`
to request only matching event resource URLs and ETags, then downloads changed
resources. The server matches recurrence instances and event overlap, so a series
that began years ago but still occurs is included. Matching series are retained
in full, including their old instances, exceptions and time zones; the window
does not truncate their recurrence rules or raw bodies. Limited mode queries
VEVENT resources; **All history** retains the previous full-resource inventory,
including stored tasks.

Events outside the selected window leave the app's one-way iCal projection;
their originals remain in iCloud. After successful Sync Services publication,
the daemon clears excluded cached bodies and parsed rows and compacts SQLite
when substantial free space has accumulated. Small identity records remain so
widening the window downloads older resources using the same identities.
Unresolved outgoing operations protect their cached resources. Filtering only
at the Sync Services stage would not reduce the mirror database, so history is
limited at fetch time instead.

Failed, incomplete, or rejected queries preserve the previous committed scope
and are logged/retried; they do not trigger an automatic full-history download.
The preference is stored as `Contacts.CalendarHistoryYears`: `0`, `1`, or `2`;
existing configurations without the key also default to two years. The CalDAV
probe accepts `--history-years 0|1|2` and defaults to two years. It does not publish
to iCal or run the post-publication cache cleanup.

`calendars` and `events` contain readable fields. `calendar_resources` retains
original `.ics` bytes and the last successfully exported body for retained resources. Ordered
`ical_components`, `ical_properties`, and `ical_parameters` retain additional
properties. SQL views expose available events, recurrence, participants, alarms,
and time zones. Newly created files use a format readable by Tiger's `sqlite3`:

```sql
SELECT calendar_name, summary, start_value, start_kind, start_tzid,
       end_value, recurrence_id, export_status
FROM available_events;
```

Dates retain their original date-only, UTC, zoned, or floating meaning. The view
contains recurring masters and overrides, not expanded occurrences. Raw bytes
are retained even when parsing fails; `parse_error` identifies stale normalized
rows. A failed/incomplete DAV run rolls back instead of treating absent rows as
remote deletions. Each account has separate state and Sync Services identity.
Changing accounts preserves the previous account's cached/local calendars.

The Tiger mapper supports ordinary and all-day events, daily/weekly/monthly/
yearly recurrence within Apple's schema, exclusions, moved/cancelled instances,
participants, and display/audio alarms. Floating timed events, unsupported
recurrence forms (including RDATE, subdaily rules and ranged exceptions), and
recurring zones that differ from Tiger's rules remain in SQLite with an export
explanation. A previously exported series is retained if its replacement cannot
be represented. Tasks, unknown extensions, and unsupported alarm actions are
stored but not exported. Calendar color is stored but is not a Tiger schema field.

iCal creates ordinary local calendars with a stable short suffix in their names
to distinguish equal remote calendar names. In one-way mode, local edits are never uploaded to
iCloud and may be replaced by a later import. Two-way mode uploads the supported
changes described in [TWO_WAY_SYNC.md](TWO_WAY_SYNC.md). The daemon checks completion of
Sync Services' merge phase before recording a successful export. System sync
confirmation dialogs, when required, must be available in the logged-in desktop
session; the app's per-user LaunchAgent runs there.

Build the non-shipped CalDAV probe and offline tests with:

```sh
make build-mac-caldav-probe
make test-host-calendars
make build-mac-calendars-syncservices-tests
make test-mac-calendars-syncservices TEST_HOST=x4-vm
```

The probe is `build/probes/macOS/caldav/release/RetroCloudCalDAVProbe` and accepts
the same arguments as the CardDAV probe below, defaulting to
`https://caldav.icloud.com`. It prompts for the app-specific password and performs
no remote writes or Sync Services import.

Calendar integration tests run synthetic data through the real Tiger framework
and verify iCal using AppleScript. They also register and remove a client using
the production identifier format and a synthetic account ID, catching Tiger's
encoded filename length limit without publishing records. Production calendar
clients use `com.retrocloudsync.cal.v1.` plus the full account sync ID.
The import tests use a separate test client, preserve a
baseline of existing calendar/event identifiers, exercise repeated imports,
updates/deletion and malformed/unsupported replacements, and clean up their
records. The remote runner opens a Terminal session because an SSH bootstrap
session cannot reliably reach Tiger's Sync Services confirmation UI. With native
Accessibility enabled, the harness confirms only dialogs naming its separate
"Retro Cloud Calendar Tests" client. All remote
artifacts remain under `~/Desktop`. Stop the production daemon before testing.

The build uses libical 3.0.20 from the HTTPS Git submodule at
`source/deps/libical` and needs CMake, Perl, Python 3, and Git on the Linux host.
It builds only the C library for PPC/i386 and native tests. Preparation copies
the checkout into `build/dependencies` (or `BUILD_ROOT/dependencies`) and applies
the GCC 4.2 diagnostic-only patches there, leaving the submodule unchanged.
`RetroCloudSync.zip` contains only `RetroCloudSync.app` at the archive root.
Runtime time-zone data and a copy of the MPL 2.0 license are included inside
the app; build-only time-zone files are excluded. The dependency build script's
`prepare-archive` mode can prepare a source archive without a Git checkout.
See [CALENDAR_DESIGN.md](CALENDAR_DESIGN.md) for the
original proposal and deferred work.

## Read-only CardDAV probe

Build the non-shipped PowerPC/Intel diagnostic tool with:

```sh
make build-mac-carddav-probe
make test-host-contacts
```

Copy `build/probes/macOS/carddav/release/RetroCloudCardDAVProbe` and
`build/macOS-app/release/RetroCloudSync.app/Contents/Resources/cacert.pem` to
a Mac under `~/Desktop`, then run:

```sh
./RetroCloudCardDAVProbe \
  --username "name@icloud.com" \
  --database "$HOME/Desktop/RetroCloudContacts.sqlite" \
  --ca "$HOME/Desktop/cacert.pem"
```

The password is read from an interactive prompt. The probe performs CardDAV
discovery and read-only contact downloads; it never sends `PUT` or `DELETE`.
Downloaded vCards are stored both as their original bodies and as normalized
contact, property, parameter, and structured-value rows.

### vCard parser

Contacts use libvc 013 through `RCVCardParse()`. Libvc parses content lines,
groups and parameters; the adapter unfolds input, decodes escaped text and
structured values, and fills the existing contact model. Original downloaded
bodies remain unchanged in the database. Comma-separated parameters can become
multiple parameter rows with the same name. Parsing uses an in-memory stream
and serializes access to libvc's global parser state.

`source/make/libvc.mk` builds native, PPC and i386 static libraries. It needs
Flex, Bison and patch on the Linux host. Following the libical pattern,
preparation copies sources into `build/dependencies/libvc-source` and applies
`source/make/scripts/libvc-parser.patch` there. The patch fixes group token
ownership, quoted parameters, empty values, and malformed-input cleanup/reset.
A portability shim supplies Tiger's missing `getline` and the missing
`strings.h` include. The submodule itself stays unchanged.

`make test-host-contacts` includes exact-value, group, parameter, malformed-input,
long-value and concurrent parsing checks. `make build-mac-vcard-tests` builds the
same checks for PPC/i386; the PPC executable has also passed on Tiger.
The app includes a copy of the libvc license. Debug and release ZIPs contain
only `RetroCloudSync.app`, with no enclosing folder or companion sources.
Copy the `.app` to the Mac for installation.

### Legacy libicalvcal compatibility check

The libical submodule also contains the older `libicalvcal` / `VObject` parser.
It is not used by the application: testing version 3.0.20 found that it rejects
quoted parameter values, splits escaped surname separators, inserts spaces at
line folds, drops leading value spaces, and consumes the next property after
an empty value. The current `RCVCard` parser passes these same cases.

Reproduce the comparison or build its non-shipped Mac executables with:

```sh
make compare-host-libicalvcal      # native comparison; exits nonzero on incompatibility
make build-libicalvcal-comparison  # builds host, PPC and i386 executables
```

Outputs are in `build/tests/experiments/libicalvcal-comparison/`
(or the corresponding `BUILD_ROOT` directory). The comparison
currently reports 7 failures in 11 cases for libicalvcal, and none for RCVCard.
Mac executables must be copied to a Mac under `~/Desktop` to run them.

## Offline contacts Sync Services test

Build the non-shipped test tools and synthetic contact databases with:

```sh
make build-mac-contacts-syncservices-tests
make analyze-mac-contacts-syncservices-tests
```

Run the end-to-end test on a Tiger host with:

```sh
make test-mac-contacts-syncservices TEST_HOST=x4-vm
```

The test refuses to run while the production daemon is active. It uses the
separate Sync Services client identifier
`com.retrocloudsync.contacts.test.v1` and never reads the login Keychain,
loads the service configuration, initializes the network stack, or contacts
iCloud. The runner copies the tools with SCP and starts them through Terminal
in the logged-in desktop session. Enable Accessibility on Tiger so the harness
can confirm Sync Services dialogs naming only its "Retro Cloud Contacts Tests"
client, as the calendar harness does.

The verifier checks both Address Book and Sync Services truth: exact contact
and child counts, values, Unicode names/notes, birthday, company display,
labels, preferred phone/email entries, relationship back-references, stable
contact identities, and removal of old child records. Fixtures exercise repeat
exports, reordered vCard properties, updates/contact deletion, and removal of
all optional fields. Corrupt usable cached vCards and missing child identities must fail
without publishing a partial export; a valid replay must then succeed. Additional
fixtures check that malformed remote replacements retain the previous graph,
failed inventories can replay the complete cache, and a never-completed mirror
cannot remove existing records. The verifier also registers and removes a
synthetic account client using the production identifier format, checking
Tiger's encoded filename limit without publishing any records.

`make test-host-contacts` includes deterministic CardDAV tests for account switching
with identical URLs and UIDs, mismatched credentials, deleted/reappearing
collections, empty homes, invalid new/replacement cards, partial DAV failures,
publication acknowledgements, and process termination during a transaction.

Before exporting, the harness snapshots existing people and groups, including
property contents, images, multivalue labels/identities and group membership
(excluding modification timestamps). It checks that baseline after each phase
and cleanup. Cleanup always attempts an empty export, verifies that test
contacts and previously observed child records are gone, and only then
unregisters the test client. Cleanup failures fail the run and retain the client
for recovery. A Desktop lock prevents overlapping contacts harnesses; after an
interrupted run, inspect its `owner` file and running processes before removing
a stale `~/Desktop/.RetroCloudSync-ContactsTests.lock` directory.

Remote tools, logs and failure screenshots remain under
`~/Desktop/RetroCloudSync-ContactsTests-*`. Completed-run logs and exit status
are also copied to `build/tests/macOS/contacts-syncservices/RetroCloudSync-ContactsTests-*`
(or the corresponding `BUILD_ROOT`).
