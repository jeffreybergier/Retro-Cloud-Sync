# Test suites

Run commands from the repository root. `make test` selects the Linux business
suite; bare `make` still builds the release application. Existing `test-host`
and `test-mac-*` commands remain supported.

| Suite | Command | Membership |
| --- | --- | --- |
| Linux business logic | `make test-business-linux` | Native C parsing, stores, DAV mirrors/tokens, journals, conflict recovery, resource patching and local HTTP/TLS |
| macOS business integration | `make test-business-mac TEST_HOST=x4-vm` | Logging/status, shutdown, contacts/calendars Sync Services, conflict sessions, contacts and calendar two-way sync |
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
