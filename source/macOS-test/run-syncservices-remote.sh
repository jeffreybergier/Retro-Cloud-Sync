#!/bin/bash
set -euo pipefail
test_host="${TEST_HOST:-x4-vm}"
build_root="${BUILD_ROOT:?BUILD_ROOT is required}"
project_root="${PROJECT_ROOT:?PROJECT_ROOT is required}"
run_name="RetroCloudSync-ContactsTests-$(date +%Y%m%d-%H%M%S)-$$"
remote_relative="Desktop/$run_name"
local_artifacts="$build_root/syncservices-test/$run_name"
mkdir -p "$local_artifacts"
ssh -o LogLevel=ERROR "$test_host" "mkdir -p '$remote_relative'"
scp -o LogLevel=ERROR "$build_root/macOS-daemon/release/RetroCloudSyncDaemon" \
  "$build_root/syncservices-test/RetroCloudSyncSyncServicesVerifier" \
  "$build_root"/syncservices-test/Contacts-*.sqlite \
  "$project_root/source/macOS-app/Resources/SyncClient.plist" \
  "$project_root/source/macOS-test/run-syncservices-tests.command" \
  "$test_host:$remote_relative/"
echo "Contacts test artifacts: $test_host:~/$remote_relative"
ssh -o LogLevel=ERROR "$test_host" "osascript -e 'tell application \"Terminal\" to do script \"cd ~/$remote_relative && /bin/bash ./run-syncservices-tests.command\"'"
for ((attempt=0;attempt<450;attempt++)); do
  if ssh -o LogLevel=ERROR "$test_host" "test -f '$remote_relative/contacts-tests.status'"; then
    scp -o LogLevel=ERROR "$test_host:$remote_relative/*.log" "$test_host:$remote_relative/contacts-tests.status" "$local_artifacts/"
    cat "$local_artifacts/contacts-tests.log"
    echo "Local test logs: $local_artifacts"
    test "$(cat "$local_artifacts/contacts-tests.status")" = 0
    exit $?
  fi
  sleep 2
done
echo "Contacts tests still pending; inspect $test_host:~/$remote_relative/contacts-tests.log" >&2
exit 1
