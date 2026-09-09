# Tests and diagnostics

Run `make help` from the repository root for the command index. All builds run
on the Linux build host. `test-host*` also executes there; `test-mac-*` builds
and transfers tools to `TEST_HOST` (default `x4-vm`) and runs them on the Mac.
`build-*` never runs Mac executables. Nothing under `source/tests` or
`source/probes` is shipped in the application bundle.

## Suites

| Suite | What it checks | Runtime and requirements | Command |
| --- | --- | --- | --- |
| Contacts | vCard parsing, SQLite storage, identities, account isolation, mirror rollback and recovery | Linux, offline; simulated HTTP | `make test-host-contacts` |
| Calendars | iCalendar codec, SQLite storage, discovery, inventory and failure handling | Linux, offline; simulated HTTP | `make test-host-calendars` |
| Write safety | Durable outgoing operations, crash recovery, conflicts, base revisions, loss-preserving edits and production HTTP preconditions/TLS | Linux; synthetic fixtures and local TLS server; Python 3, OpenSSL CLI, native libcurl | `make test-host-writes` |
| Two-way sync | Production reverse mappers and real Sync Services collection, conditional PUT/DELETE through a synthetic transport, verified acceptance, creation identity, replay, conditional deletion and conflict resolution | Mac desktop, offline; daemon stopped; separate synthetic clients | `make test-mac-two-way TEST_HOST=x4-vm` |
| Conflict recovery | Journal-to-Sync Services contact reconciliation, exact acknowledgement, newer local edits, field preservation and cleanup | Mac desktop, offline; production daemon stopped; separate synthetic clients | `make test-mac-conflicts TEST_HOST=x4-vm` |
| DAV sync tokens | Pagination, expired/unsupported tokens, durable rollback, account isolation and rolling calendar windows through the real mirrors | Linux, offline; scripted HTTP | `make test-host-sync` |
| Daemon logging | Real NSLog output: severity, UTF-8, bounded single-line messages, errno, concurrent contexts; injected DNS/socket failures | Mac command line; no account, GUI, or external network | `make test-mac-logging TEST_HOST=x4-vm` |
| App GUI | Preferences, autosave/validation, Start/Stop, installation, logs and loopback mail listeners | Mac desktop with Accessibility; controls the service and local listeners | `make test-mac-app TEST_HOST=x4-vm` |
| Network | A fresh HTTPS image download using the legacy TLS library | Mac command line and internet; no GUI, service or credentials | `make test-mac-network TEST_HOST=x4-vm` |
| Contacts Sync Services | Synthetic records through the production daemon bridge into Sync Services and Address Book; update, identity, recovery and cleanup checks | Mac desktop, offline; production daemon stopped | `make test-mac-contacts-syncservices TEST_HOST=x4-vm` |
| Calendars Sync Services | Synthetic records through the production daemon bridge into Sync Services and iCal; recurrence, updates, retention, registration and cleanup checks | Mac desktop, offline; production daemon stopped | `make test-mac-calendars-syncservices TEST_HOST=x4-vm` |
| vCard on Mac | The same parser regressions compiled against the legacy runtime | Mac command line; offline; manual execution | `make build-mac-vcard-tests` |
| libicalvcal comparison | Production vCard parser versus an unused candidate parser | Linux, offline; optional Mac builds | `make compare-host-libicalvcal` |

`make test-host` runs all four host suites. `make build-mac-tests` builds all
normal Mac test executables and their fixture inputs, including the standalone
network diagnostic. It excludes probes and the parser experiment.

`make build-mac-conflict-tests` builds the separate conflict harness. It uses the
production recovery/session adapters with synthetic HTTP outcomes and the real
Contacts schema. The runner verifies the pre-test Address Book baseline after
cleanup, shares the contacts Desktop lock and saves journals/logs under Desktop.
Same-field choices belong to system policy/UI; the harness never selects a
conflict value automatically. See [conflict recovery](../../CONFLICT_RECOVERY.md).

The HTTPS diagnostic now lives in `macOS/network/HTTPSDownloadTest.m`; the daemon
no longer downloads the test image automatically at startup. `test-mac-network`
executes this tool directly over SSH, using the same CA bundle and TLS checks.
It writes its image under the run's Desktop directory.

The app suite snapshots its configuration after establishing a stopped baseline,
uses a blank account with Contacts/Calendars disabled, and restores the original
file bytes after the app exits, on success or failure. A recovery copy is kept
with screenshots in case the harness is interrupted. It does not change Keychain
credentials. Mail preferences and loopback listeners are still exercised.
The Sync panel check verifies that both account fields are enabled for Save or
both disabled for Reset. It does not press either credential button.

For credential testing on a Mac, use a disposable account and keychain entry:

- Save an Apple ID and password: the Apple ID is read back, both fields disable,
  the password field clears, and the bottom-right button becomes Reset.
- Reopen the app and Sync panel, then restart the daemon (including with a new
  daemon build): the GUI must not query the keychain or modify access rules.
  A replaced daemon may require Reset and Save to establish its new access.
- Reset: the entry is deleted and both fields enable with a Save button. Repeat
  after deleting the item externally; Reset must still succeed. A failed or
  cancelled deletion must leave the fields disabled.
- Type another Apple ID and leave the field: this must not access the keychain
  or commit the new account until Save. Failed saves must leave the form editable.
- Verify the daemon still reads credentials on its first and subsequent sync
  cycles. Reset does not cancel a sync cycle already using a copied password.

The GUI remembers the saved Apple ID in the `RCKeychainSavedAppleID` preference;
no password is stored there. Older installations initialize this state from the
configured Apple ID without querying the keychain. An externally deleted item
can therefore still appear saved until Reset is pressed.


Sync Services tests are offline, but they create/update/remove synthetic local
contacts or calendars. They use separate test clients, check cleanup and preserve
baselines of existing data. They need the logged-in Tiger desktop and “Enable
access for assistive devices” for the test client's confirmation dialogs.

## Source layout and roles

- `portable/ContactStoreTests.c`: vCard-to-SQLite storage and export identities.
- `portable/VCardParserTests.c`: exact values, escaping, groups, malformed input,
  recovery, long values and concurrent parsing. Also compiled for PPC/i386.
- `portable/CardDAVMirrorTests.c`: real mirror/store logic with simulated HTTP.
- `portable/CalendarCodecStoreTests.c`: calendar parsing and database regressions.
- `portable/CalDAVMirrorTests.c`: real calendar mirror logic with simulated HTTP,
  history REPORT shape, old recurring series/future/overlapping events, failed
  scope changes, window expansion, publication-gated cache cleanup, account and
  pending-write retention, and actual SQLite file compaction.
- `macOS/app/`: `AppGUITestRunner` and its command-line entry point.
- `macOS/network/`: standalone `HTTPSDownloadTest.m` and its remote runner.
- `macOS/contacts-syncservices/`: `ContactsSyncServicesVerifier.m` and runners.
- `macOS/calendars-syncservices/`: `CalendarSyncServicesVerifier.m`,
  `CalendarClientRegistrationTests.m` and runners.
- `fixtures/contacts/ContactsFixtureGenerator.c`: runs on Linux to generate
  synthetic databases transferred to the Mac; it is not a test runner.
- `fixtures/calendars/CalendarFixtures.c`: shared synthetic data/population code
  used by the host tests and the Mac `CalendarFixtureGenerator.c` executable.
- `experiments/libicalvcal-comparison/`: optional parser evaluation. Its known
  candidate failures intentionally produce a nonzero exit status; they do not
  indicate a failure of the normal production regression suite.

In each Mac suite, `run-remote.sh` runs on Linux and transfers/launches the tools.
For Sync Services, `run-on-mac.command` runs in Terminal on the Mac desktop.
The app runner launches its native Accessibility harness directly through SSH.
The network runner launches a standalone command-line executable through SSH.
Run the Mac suites sequentially: they share the desktop and installed service.

`portable/DAVSyncTests.c` exercises the shared sync-token parser and both real
mirrors using scripted HTTP. It verifies escaped opaque tokens, explicit member
deletions, pagination and token cycles, expired-token recovery, unsupported-server
fallback, failed-page/download rollback, process termination before commit,
account isolation, collection recreation, and calendar cutoff changes. Initial
and unchanged fetches assert the expected request sequence, catching accidental
full inventories or downloads. The executable is
`build/tests/host/sync/RetroCloudDAVSyncTests`.

## Outputs

All paths below are relative to `BUILD_ROOT` (default `build/`). Old command
aliases use these new locations too; old build directories are not migrated.

| Output directory | Contents |
| --- | --- |
| `tests/host/contacts/` | Contact store, vCard parser and CardDAV mirror test executables |
| `tests/host/calendars/` | Calendar codec/store and CalDAV mirror test executables |
| `tests/macOS/app/release/` | `RetroCloudAppGUITests`, a PPC/i386 universal executable |
| `tests/macOS/app/remote-artifacts/` | App failure screenshots and configuration recovery copy from the Mac |
| `tests/macOS/network/` | `RetroCloudHTTPSDownloadTest` and returned network logs |
| `tests/macOS/contacts-syncservices/` | Universal verifier, Linux fixture generator, synthetic SQLite databases and returned run logs |
| `tests/macOS/calendars-syncservices/` | Universal verifier, fixture generator and client-registration test |
| `tests/macOS/vcard/` | `vcard-ppc` and `vcard-i386` for manual Mac execution |
| `tests/experiments/libicalvcal-comparison/` | Host/PPC/i386 parser comparison binaries |
| `probes/macOS/carddav/release/` | `RetroCloudCardDAVProbe` |
| `probes/macOS/caldav/release/` | `RetroCloudCalDAVProbe` |

Remote transfers, logs, snapshots and failure artifacts stay in timestamped
`~/Desktop/RetroCloudSync-*` directories. Runners print the exact locations.
Contacts logs are copied back automatically; calendar logs remain on the Mac
and are printed at completion. App screenshots are copied back on failure. Network logs are captured locally.
Never run Mach-O executables on Linux.

## Manual live-server probes

Probe sources live separately in `source/probes/macOS/{carddav,caldav}`. Build with
`make build-mac-carddav-probe` or `make build-mac-caldav-probe`, then copy the
binary and the app's `cacert.pem` to the Mac under `~/Desktop`.

Both accept `--username ADDRESS --database PATH --ca PATH`, optionally `--url URL`,
and prompt for an app-specific password. They read real iCloud data into the
specified local SQLite database without writing to the remote server or
importing into Address Book/iCal. They are manual diagnostics, not pass/fail
regression suites. See the root README for invocation examples.

## Compatibility commands

| Existing command | Preferred command |
| --- | --- |
| `test-shared` | `test-host-contacts` |
| `test-calendar` | `test-host-calendars` |
| `test-build` / `test-debug` | `build-mac-app-tests` / `build-mac-app-tests-debug` |
| `test-analyze` | `analyze-mac-app-tests` |
| `test-gui` | `test-mac-app` |
| `test-syncservices` | `test-mac-contacts-syncservices` |
| `test-syncservices-build` | `build-mac-contacts-syncservices-tests` |
| `test-syncservices-analyze` | `analyze-mac-contacts-syncservices-tests` |
| `test-calendar-syncservices` | `test-mac-calendars-syncservices` |
| `test-calendar-build` | `build-mac-calendars-syncservices-tests` |
| `test-calendar-client-build` | `build-mac-calendar-client-tests` |
| `test-vcard-build` | `build-mac-vcard-tests` |
| `test-vcal-compat` | `compare-host-libicalvcal` |
| `test-vcal-compat-build` | `build-libicalvcal-comparison` |
| `carddav-probe` / `carddav-probe-debug` | `build-mac-carddav-probe` / `build-mac-carddav-probe-debug` |
| `caldav-probe` | `build-mac-caldav-probe` |

The `analyze-*` targets run Clang static analysis on Linux against the Mac SDK;
they do not execute tests. Make fragments use the same subjects: host contacts,
host calendars, Mac app, Mac contacts Sync Services, Mac calendars Sync Services,
Mac network diagnostics, and the libicalvcal experiment. `source/make/tests.mk` owns aggregates and aliases.

## Two-way integration tests

`make build-mac-two-way-tests` builds `tests/macOS/two-way/TwoWaySyncTests`.
`make test-mac-two-way TEST_HOST=x4-vm` runs it from a fresh Desktop directory.
Its HTTP functions are replaced at link time with an in-memory fixture that
rejects every non-fixture URL and every method other than GET/PUT. It cannot
contact iCloud and never reads Keychain. Tests exercise both real Contacts and
Calendars schemas, keep baseline snapshots, and clean up only marked fixtures.
Contact cases cover first-sync uploads, recovery of saved exclusions, and replay
without duplicate uploads. A fixture-only encoder delegates marked contacts to
the production mapper and keeps unrelated desktop contacts out of the synthetic
account. Only sync alerts naming "Retro Cloud Two Way Tests" are allowed automatically.
The production daemon must be stopped, and Mac suites must run sequentially.

`TwoWaySyncTests --mappers` runs the production reverse-mapping checks without
opening any Sync Services session. Run it in a fresh Desktop directory; it
creates synthetic databases there. The remote runner runs these checks too.
The mapper regressions cover timezone components before, after and around
VEVENTs, preserving untouched wire bytes; detached exception creation, editing
and removal; EXDATE updates; invitation metadata; and audio sound round trips.
`TWO_WAY_TEST_MODE=calendar-exceptions` runs only the new calendar integration
cases (also included in the full calendar suite). They check that a new exception
uses the master's conditional PUT, with exact acknowledgement and replay without
duplicate writes, and that sound URLs survive native collection and replay.
Tiger date comparisons normalize unordered dates before hashing because equal
NSCalendarDate values can have different hashes across timezone representations.

Tiger's `com.apple.ical.sound` is an NSURL and maps to the AUDIO alarm's
single URI `ATTACH` property. Sound edits preserve existing parameters and
unrelated alarm bytes; embedded or multiple attachments remain protected.
Leopard's `sound` field contains a system sound name; it maps to
`file:///System/Library/Sounds/<name>.aiff`. Equivalent name/URL pairs compare
as one selection, including during validation and acknowledgement. Conflicting
pairs and unsafe names are refused. Mapper fixtures cover name-only selections,
equivalent pairs, name edits and conflicts on both OS versions.
Matching relative URL/name pairs such as NSURL `Basso` plus string `Basso`
retain the original `ATTACH;VALUE=URI:Basso` bytes. Regression coverage includes
unrelated event edits, import acknowledgement, replay and conflicting names.
No sound files are read or uploaded. Invitation identifiers, sequences and
timestamps remain native bookkeeping. Unsupported recurrence-rule changes, scheduling changes,
and edits to retained cancelled components still fail closed.

Empty strings, empty URLs and absent optional values compare equally. Empty
audio sound selections omit ATTACH while retaining ACTION:AUDIO; the mapper
does not substitute Basso or any other sound. Field-specific defaults also
compare equally when omitted or empty: event title/all-day/status/classification,
attendee RSVP/role/status/user type, contact person display, and contact child
type "other". Real nondefault changes are still detected. Missing records,
required dates and alarm triggers are not treated as optional defaults.
Clearing an event title omits SUMMARY and uses the forward mapper's existing
"Untitled event" fallback; an empty SUMMARY is rejected by the legacy codec.
The mapper-only tests cover these cases, including import/replay, untouched
wire bytes, and rejection of actual attendee or label changes. They can run
alongside the daemon because they use synthetic databases and no sync session;
the Sync Services integration suites still require the daemon to be stopped.

An interrupted integration test can be recovered with `./TwoWaySyncTests --cleanup`
in its original Desktop directory. Preserve the marker and baseline files.

The `TWO_WAY_TEST_MODE=contact-publication` two-way subset covers a server-side
note edit before initial upload acknowledgement, changed-UID rejection, and
replay without duplicate uploads. It runs contact mapper checks and verifies
the pre-existing Address Book baseline without running the calendar suite.

The offline two-way regression suite also verifies consecutive native edits
before acknowledgement (including a journal reopen), uploads deleted or excluded
by the history window before mirror download, and continued unrelated uploads,
downloads and remote deletions while a record is conflicted. Empty raw contact
fields retain their positions through note edits, value changes, removals and
additions. Its replacement HTTP transport accepts only `fixture.invalid`;
it neither obtains Keychain credentials nor contacts iCloud.

`make test-mac-two-way TEST_HOST=x4-vm TWO_WAY_TEST_MODE=recovery` skips the
first-enable policy scenarios and runs contact/calendar write recovery, conflict
resolution and deletion regressions with the same offline transport and baseline
checks. The full suite includes these cases too.

`TWO_WAY_TEST_MODE=edit-delete` isolates a contact edit racing a verified remote
deletion. It exercises the system's canonical decision, conditional recreation
or deletion verification, exact acceptance and replay.
