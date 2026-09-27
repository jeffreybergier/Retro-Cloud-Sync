# Test suites

Run commands from the repository root. `make test` selects the Linux business
suite; bare `make` still builds the release application. Existing `test-host`
and `test-mac-*` commands remain supported.

| Suite | Command | Membership |
| --- | --- | --- |
| Linux business logic | `make test-business-linux` | Native C parsing, stores, DAV mirrors/tokens, journals, conflict recovery, resource patching, local HTTP/TLS, photos, status, connection diagnostics, field/receipt policies and calendar projection |
| macOS business integration | `make test-business-mac TEST_HOST=x4-vm` | Logging/status, shutdown, contacts/calendars Sync Services, conflict sessions, full two-way sync (contacts and calendars), plus the dedicated photo/partial-field scenarios |
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
