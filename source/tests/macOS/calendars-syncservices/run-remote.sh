#!/bin/bash
set -euo pipefail
test_host="${TEST_HOST:-x4-vm}"
build_root="${BUILD_ROOT:?BUILD_ROOT is required}"
project_root="${PROJECT_ROOT:?PROJECT_ROOT is required}"
run_name="RetroCloudSync-CalendarTests-$(date +%Y%m%d-%H%M%S)-$$"
remote_relative="Desktop/$run_name"
ssh -o LogLevel=ERROR "$test_host" "mkdir -p '$remote_relative'"
scp -o LogLevel=ERROR "$build_root/macOS-daemon/release/rcloudd" \
    "$build_root/tests/macOS/calendars-syncservices/RetroCloudCalendarSyncServicesVerifier" \
    "$build_root/tests/macOS/calendars-syncservices/RetroCloudCalendarFixtureGenerator" \
    "$build_root/tests/macOS/calendars-syncservices/RetroCloudCalendarClientRegistrationTests" \
    "$project_root/source/macOS-app/Resources/CalendarSyncClient.plist" \
    "$project_root/source/tests/macOS/calendars-syncservices/run-on-mac.command" \
    "$test_host:$remote_relative/"
ssh -o LogLevel=ERROR "$test_host" "osascript -e 'tell application \"Terminal\" to do script \"cd ~/$remote_relative && /bin/bash ./run-on-mac.command\"'"
# The desktop script confirms only alerts naming its synthetic-data test client.
for ((attempt=0;attempt<180;attempt++)); do
  if ssh -o LogLevel=ERROR "$test_host" "test -f '$remote_relative/calendar-tests.status'"; then
    ssh -o LogLevel=ERROR "$test_host" "cat '$remote_relative/calendar-tests.log'; test \"\$(cat '$remote_relative/calendar-tests.status')\" = 0"
    echo "Calendar test artifacts: $test_host:~/$remote_relative"
    exit 0
  fi
  sleep 2
done
echo "Calendar test is still pending; see $test_host:~/$remote_relative/calendar-tests.log" >&2
exit 1
