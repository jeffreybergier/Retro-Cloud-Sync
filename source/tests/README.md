# Test suites

Run commands from the repository root. `make test` selects the Linux business
suite; bare `make` still builds the release application. Existing `test-host`
and `test-mac-*` commands remain supported.

| Suite | Command | Membership |
| --- | --- | --- |
| Linux business logic | `make test-business-linux` | Native C parsing, stores, DAV mirrors/tokens, journals, conflict recovery, resource patching, local HTTP/TLS, photos, status, connection diagnostics, field/receipt policies and calendar projection |
| macOS business integration | `make test-business-mac TEST_HOST=x4-vm` | Logging/status, shutdown, contacts/calendars Sync Services, conflict sessions, full two-way sync (contacts and calendars), plus the dedicated photo/partial-field scenarios |
| macOS native stores (10.9+) | `make test-mac-native-stores TEST_HOST=x9-local` | AddressBook/EventKit import, edit, journal acknowledgement and owned-record cleanup; synthetic offline fixtures |
| macOS UI | `make test-ui-mac TEST_HOST=x4-vm` | Preferences, Accessibility, validation feedback, Start/Stop and installed service interaction |

Linux tests run synthetic fixtures without credentials or external servers. The
HTTP suite starts an ephemeral loopback TLS server. Use `BUILD_ROOT=/tmp/rc-tests`
for an independent build. Artifacts normally live in `build/tests/host`.

The Mac suites cross-compile PPC/i386 binaries on Linux and execute on the target
Mac. Use a disposable test account, stop the production daemon, and keep the
desktop logged in with Accessibility enabled. Business integration can invoke
system dialogs even though it does not test the application UI. The aggregate
runs native suites sequentially, including when invoked with `make -j`; do not
run another UI/native suite concurrently on the same Mac. Remote artifacts stay
under `~/Desktop`, with collected logs under `build/tests/macOS`.

The full two-way test can pause for native Conflict Resolver review. Resolve only
the contact bearing the current run's `RetroCloudTwoWay-` marker (saved in the
remote `fixture-marker.txt`). If unrelated conflicts are present, filter the
review to the test's Contacts conflict, save that choice, then quit the resolver
without choosing values for unrelated records. The test verifies convergence on
the system's chosen value. Interrupted runs may leave registered test clients;
retain their artifact directory and run `bash run-on-mac.command --cleanup`
there in the logged-in desktop session before retrying. This keeps the test's
Sync Alert helper active during cleanup, which uses that run's marker. Save the
original logs first, since the wrapper writes a new `two-way.log`.

`make test-mac-network` is an opt-in internet/TLS diagnostic. Credentialed iCloud
probes and `compare-host-libicalvcal` are also separate from the three suites.
Offline fixtures do not establish live iCloud compatibility.

## Boundaries

Keep business decisions in production C under `source/shared` and test those same
functions on Linux. Objective-C adapters own Foundation objects, native date
representations, property-list/keyed serialization and Sync Services sessions.
Retain Mac adapter/integration tests when extracting a portable rule. Keychain,
LaunchAgents, Apple framework behavior and Tiger floating-date semantics need
the actual Mac environment.

Tests under `portable` are compiled with the native compiler, never the Apple
cross-compiler. Mac test binaries must not be executed on Linux. The vendored
libical/libvc libraries are built natively from initialized submodules; upstream
library test suites are not included in the application suite.

## Portable coverage and retained adapters

The Linux suite runs 12 programs. The original eight cover parser/store/mirror,
DAV token, write safety and local TLS regressions. Four additional programs run
the extracted production code directly:

| Program | Production code / behavior |
| --- | --- |
| `ConnectionTests` | `RCConnection`: injected DNS, refused connection and timeout diagnostics; also compiled into the Mac logging harness |
| `PolicyTests` | `RCPhotoCodec` binary/base64/media rules; `RCStatusPolicy` account-scoped pending counts and success/error/stopping decisions |
| `CalendarProjectionTests` | `RCCalendarProjection`: finite RDATE/EXRULE sets, leap/boundary dates, authoritative custom DST projections and unsupported-rule rejection |
| `SyncPolicyTests` | `RCSyncPolicy`: supported fields/defaults, ordered vs unordered comparisons, receipt scopes/tombstones and independent-group retry planning |

The Mac daemon calls these same C functions. Record access callbacks borrow
Foundation objects; the Linux policy fixtures supply plain C records. Native
value equality, sound URL normalization, keyed archives, forward/reverse mapper
object construction and Sync Services remain covered by the Mac mapper and
integration tests. `make test-mac-mappers TEST_HOST=x4-vm` runs just those mapper
checks over SSH, without a Sync Services session or desktop automation. The
two-way integration runners also retain these assertions.

Calendar projection receives a native-timezone-offset callback. Linux tests
simulate matching/missing platform rules and compare all 40 occurrences in the
custom DST fixture. Mac tests verify actual Foundation offsets, floating-date
markers, archive round trips, and native calendar publication. No Foundation
replacement or Sync Services emulator is required on Linux.

## Standalone Linux prerequisites

Initialize dependencies with `git submodule update --init --recursive`. On
Debian/Ubuntu the native suite needs `build-essential cmake flex bison perl python3
openssl libsqlite3-dev libxml2-dev libcurl4-openssl-dev` (and Git, tar and patch).
It uses system SQLite/curl headers and libraries and does not need Apple SDKs,
the cross-compilers, or AltivecCore. The Mac suites still require the project's
Altivec cross-toolchain and SDK setup.

## Mavericks native stores

Build `make build-mac-native-tests` in Altivec Intelligence. The harness uses the
modern SDK and the production AddressBook/EventKit adapters. Run
`make test-mac-native-stores TEST_HOST=x9-local` with SSH access to the logged-in
Mac. Alternatively run `TEST_HOST=x9-local python3
source/tests/macOS/native-stores/run-remote.py` on the host after the container
build. No iCloud account or credentials are used and no HTTP requests are made.

The runner installs `rCloud Native Tests.app` under
`~/Desktop/RetroCloudNativeTests`, opens it in the desktop session, and collects
logs in `build/tests/macOS/native-stores`. Approve its Contacts and Calendars
prompts. It creates only disposable records and containers, then removes those
identified by its private ownership journal. Run one native suite at a time and
stop the production daemon first. Keep the run directory if interrupted; never
reset a personal Contacts/Calendar database to recover a test.

Validated on `x9-local` (OS X 10.9.5): one-way creation/update/deletion,
stable native identities, two-way ordinary-event/contact edits and verified
acknowledgements, lossless private-field retention, local creations without
duplicate uploads, and explicit deferral of two-way recurring series. Disposable
native fixtures were removed. Rebuilt apps signed with the same development
identity reused the privacy grants without prompts. The legacy mapper suite and
portable Linux business suite also passed; Apple Silicon runtime behavior and
live iCloud writes were not exercised.

Invitation regressions use synthetic attendees and organizers with RSVP/status
and private parameters, including folded wire lines. They compare the entire
queued `.ics` body after native edits and database reopening, exercise one-way
to two-way switching, verified acknowledgement/replay, remote participant
updates, and a concurrent remote update pinned to the original ETag. Native
invitation deletion must stay pending without queuing a cloud DELETE. Remote
outcomes are simulated in the journal; the portable write-safety suite separately
checks conditional HTTP writes and precondition conflicts.

EXDATE regressions cover all-day and time-zone recurring masters with multiple
folded exclusions. They verify all occurrences appear locally, exact original
wire data survives publication/reopen and remote exclusion updates, and local
series edits/deletions never upload exclusion removal or a cloud DELETE.

Audio regressions cover mixed display/audio alarms, relative/absolute triggers,
system-file and named sounds, custom and absent-attachment fallbacks, one-way
recurring imports, and new local audio alarms. They check exact wire preservation
after alarm reordering, database reopening, event edits and acknowledgement, plus
an explicit local sound edit. Repeating alarms, duplicate fallback projections
and ambiguous simultaneous alarm edits must not produce unsafe uploads. The
fixtures use future trigger dates and never download or play sound attachments.

The Mavericks all-day regression models a seven-day event with a Basso alarm
15 hours before its start. It verifies a single default alarm after publication and recreates
the old duplicate-alarm/pending-save state with the native identifier missing.
Recovery must reuse the sole matching event, retain exact alarm wire data on
later edits, and refuse missing, modified, already owned or multiple candidates without creating
events or queuing uploads. All recovery mutations use disposable fixture stores.

The legacy ordinal-alarm regressions model zero, one or two all-day display reminders plus
Mavericks' automatic Basso reminder. It recreates the old misclassified snapshot
and checks exact receipt repair, stable identities after reorder/reopen, no
implicit-default uploads, and unchanged wire alarms during later title edits.
Changed event fields, alarm triggers or added reminders block legacy repair.
After repair, a newly added local reminder may upload without copying the unchanged automatic default, and a reorder between
queue and acknowledgement must not manufacture a newer edit or another upload.
