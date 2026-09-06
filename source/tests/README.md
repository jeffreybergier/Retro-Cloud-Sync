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
| DAV sync tokens | Pagination, expired/unsupported tokens, durable rollback, account isolation and rolling calendar windows through the real mirrors | Linux, offline; scripted HTTP | `make test-host-sync` |
| App GUI | Preferences, autosave/validation, Start/Stop, installation, logs and loopback mail listeners | Mac desktop with Accessibility; controls the service and local listeners | `make test-mac-app TEST_HOST=x4-vm` |
| Network | A fresh HTTPS image download using the legacy TLS library | Mac command line and internet; no GUI, service or credentials | `make test-mac-network TEST_HOST=x4-vm` |
| Contacts Sync Services | Synthetic records through the production daemon bridge into Sync Services and Address Book; update, identity, recovery and cleanup checks | Mac desktop, offline; production daemon stopped | `make test-mac-contacts-syncservices TEST_HOST=x4-vm` |
| Calendars Sync Services | Synthetic records through the production daemon bridge into Sync Services and iCal; recurrence, updates, retention, registration and cleanup checks | Mac desktop, offline; production daemon stopped | `make test-mac-calendars-syncservices TEST_HOST=x4-vm` |
| vCard on Mac | The same parser regressions compiled against the legacy runtime | Mac command line; offline; manual execution | `make build-mac-vcard-tests` |
| libicalvcal comparison | Production vCard parser versus an unused candidate parser | Linux, offline; optional Mac builds | `make compare-host-libicalvcal` |

`make test-host` runs all four host suites. `make build-mac-tests` builds all
normal Mac test executables and their fixture inputs, including the standalone
network diagnostic. It excludes probes and the parser experiment.

The HTTPS diagnostic now lives in `macOS/network/HTTPSDownloadTest.m`; the daemon
no longer downloads the test image automatically at startup. `test-mac-network`
executes this tool directly over SSH, using the same CA bundle and TLS checks.
It writes its image under the run's Desktop directory.

The app suite snapshots its configuration after establishing a stopped baseline,
uses a blank account with Contacts/Calendars disabled, and restores the original
file bytes after the app exits, on success or failure. A recovery copy is kept
with screenshots in case the harness is interrupted. It does not change Keychain
credentials. Mail preferences and loopback listeners are still exercised.

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
