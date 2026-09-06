#!/bin/bash
set -euo pipefail
test_host="${TEST_HOST:-x4-vm}"
run_name="RetroCloudSync-ConflictTests-$(date +%Y%m%d-%H%M%S)-$$"
remote="Desktop/$run_name"
local_artifacts="${BUILD_ROOT:?}/tests/macOS/conflicts/$run_name"
mkdir -p "$local_artifacts"
ssh -o LogLevel=ERROR "$test_host" "mkdir -p '$remote'"
scp -o LogLevel=ERROR "$BUILD_ROOT/tests/macOS/conflicts/ConflictSessionTests" \
  "$BUILD_ROOT/tests/macOS/contacts-syncservices/RetroCloudContactsSyncServicesVerifier" \
  "${PROJECT_ROOT:?}/source/tests/macOS/contacts-syncservices/run-conflicts-on-mac.command" \
  "$test_host:$remote/"
echo "Conflict tests: $test_host:~/$remote"
ssh -o LogLevel=ERROR "$test_host" "osascript -e 'tell application \"Terminal\" to do script \"cd ~/$remote && bash run-conflicts-on-mac.command\"'"
for ((attempt=0;attempt<450;attempt++)); do
  if ssh -o LogLevel=ERROR "$test_host" "test -f '$remote/status'"; then
    scp -o LogLevel=ERROR "$test_host:$remote/*.log" "$test_host:$remote/status" "$local_artifacts/"
    cat "$local_artifacts/conflict.log"
    echo "Logs: $local_artifacts"
    test "$(cat "$local_artifacts/status")" = 0
    exit $?
  fi
  sleep 2
done
echo "Conflict tests pending; inspect $test_host:~/$remote/conflict.log" >&2
exit 1
