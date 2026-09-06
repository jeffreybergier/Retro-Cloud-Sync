Retro Cloud Sync uses libvc 013, commit 723397cb79f302b54c2e9a1dac080c1dd9a90617.
Upstream: https://github.com/libvc/libvc
License: LGPL 2.1 or later; see COPYING.LIB.

The original source archive, build scripts, portability shim, parser patch,
and daemon relinking inputs are included here. The patch fixes ownership of
group tokens, quoted parameters, empty values, and cleanup/reset after invalid
input. No generated files or patches are written into the Git submodule.

Rebuild or modify the library on the Linux build host with Bash, tar, patch,
Flex, Bison and the project's legacy OS X cross toolchain:

  bash build-libvc.sh prepare-archive "$PWD"
  # Make desired changes in libvc-source/ after preparation.
  bash build-libvc.sh ppc "$PWD" /osxcross/legacy/target
  bash build-libvc.sh i386 "$PWD" /osxcross/legacy/target
  bash relink-libvc-daemon.sh "$PWD" /osxcross/legacy/target

The resulting RetroCloudSyncDaemon can replace the embedded daemon in the
app's Contents/Library/LaunchServices before installation/start. Run Mach-O
executables only on a Mac. Keep remote Mac work under ~/Desktop.
