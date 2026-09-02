# Retro Cloud Sync

Legacy Mac OS X 10.4+ project. Build from the repository root:

```sh
make release        # app + embedded daemon, ppc/i386
make debug
make analyze        # diagnostics to stdout/stderr
make clean
```

Outputs are in `build/`. Override with `BUILD_ROOT=/path`.

The app is `build/macOS-app/release/RetroCloudSync.app`. Copy it to a Mac and
open it; do not run Mach-O binaries on the Linux build host.

The app embeds `RetroCloudSyncDaemon` in `Contents/Library/LaunchServices`.
Start copies it to `~/Library/Application Support/RetroCloudSync`, writes
`~/Library/LaunchAgents/com.retrocloudsync.daemon.plist`, and runs
`launchctl load`. Stop runs `launchctl unload` and removes the plist. This is a
per-user LaunchAgent, not a LaunchDaemon.

Build or run the native Accessibility test harness with:

```sh
make test-build
make test-analyze
make test-gui TEST_HOST=x4-vm
```

The harness is not shipped. It launches the app, presses Start/Stop, verifies
the status label, process, files, and cleanup, and captures screenshots on
failure. Tiger must have “Enable access for assistive devices” enabled.

Use manual reference counting and Mac OS X 10.5 SDK APIs compatible with the
10.4 deployment target. Remote Mac work must stay under `~/Desktop`.
