#!/bin/bash
set -euo pipefail
test_host="${TEST_HOST:-x4-vm}"
case "${TWO_WAY_TEST_MODE:-full}" in
  full) test_arg= ;;
  calendars) test_arg=--calendars ;;
  calendar-exceptions) test_arg=--calendar-exceptions ;;
  calendar-time) test_arg=--calendar-time ;;
  fields) test_arg=--fields ;;
  conflict-replay) test_arg=--conflict-replay ;;
  recovery) test_arg=--recovery ;;
  edit-delete) test_arg=--edit-delete ;;
  contact-publication) test_arg=--contact-publication ;;
  *) echo 'TWO_WAY_TEST_MODE must be full, calendars, calendar-exceptions, calendar-time, fields, recovery, conflict-replay, edit-delete, or contact-publication' >&2; exit 1 ;;
esac
run_name="RetroCloudSync-TwoWayTests-$(date +%Y%m%d-%H%M%S)-$$"
remote="Desktop/$run_name"
local_artifacts="${BUILD_ROOT:?}/tests/macOS/two-way/$run_name"
mkdir -p "$local_artifacts"
ssh -o LogLevel=ERROR "$test_host" "mkdir -p '$remote'"
scp -o LogLevel=ERROR "$BUILD_ROOT/tests/macOS/two-way/TwoWaySyncTests" \
  "$BUILD_ROOT/tests/macOS/contacts-syncservices/RetroCloudContactsSyncServicesVerifier" \
  "${PROJECT_ROOT:?}/source/tests/macOS/two-way/run-on-mac.command" \
  "$PROJECT_ROOT/source/macOS-app/Resources/SyncClient.plist" \
  "$PROJECT_ROOT/source/macOS-app/Resources/CalendarSyncClient.plist" \
  "$test_host:$remote/"
echo "Two-way tests: $test_host:~/$remote"
ssh -o LogLevel=ERROR "$test_host" "osascript -e 'tell application \"Terminal\" to do script \"cd ~/$remote && bash run-on-mac.command $test_arg\"'"
for ((attempt=0;attempt<900;attempt++)); do
  if ssh -o LogLevel=ERROR "$test_host" "test -f '$remote/status'"; then
    scp -o LogLevel=ERROR "$test_host:$remote/*.log" "$test_host:$remote/status" "$local_artifacts/"
    cat "$local_artifacts/two-way.log"
    echo "Logs: $local_artifacts"
    test "$(cat "$local_artifacts/status")" = 0
    exit $?
  fi
  sleep 2
done
echo "Two-way tests pending; inspect $test_host:~/$remote/two-way.log" >&2
exit 1
