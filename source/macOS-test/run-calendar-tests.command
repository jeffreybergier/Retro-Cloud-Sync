#!/bin/bash
# Run in the logged-in GUI session. SSH's bootstrap namespace cannot host
# SyncServices' data-change confirmation UI on Tiger.
set -eu
cd "$(dirname "$0")"
exec > calendar-tests.log 2>&1
export_status=1
alert_helper_pid=
# Scope automatic confirmation to this harness's separate synthetic-data client.
sed 's/Retro Cloud Sync Calendars/Retro Cloud Calendar Tests/' CalendarSyncClient.plist > CalendarTestSyncClient.plist
/usr/bin/osascript <<'APPLESCRIPT' &
repeat 900 times
  tell application "System Events"
    if exists process "syncuid" then
      tell process "syncuid"
        if exists window "Sync Alert" then
          set alertText to value of every static text of window "Sync Alert"
          if (alertText as text) contains "Retro Cloud Calendar Tests" then
            click button "Allow" of window "Sync Alert"
          end if
        end if
      end tell
    end if
  end tell
  delay 1
end repeat
APPLESCRIPT
alert_helper_pid=$!
push_calendar() {
  attempts=0
  until ./RetroCloudSyncDaemon --test-calendar-syncservices Calendar-active.sqlite CalendarTestSyncClient.plist; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then return 1; fi
    echo 'Sync Services is busy; retrying the synthetic export.'
    sleep 2
  done
}
wait_for_phase() {
  attempts=0
  until ./RetroCloudCalendarVerifier "$1"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 15 ]; then return 1; fi
    sleep 1
  done
}
finish() {
  original_status=$?
  trap - EXIT
  set +e
  ./RetroCloudCalendarFixtures empty Calendar-active.sqlite
  push_calendar
  wait_for_phase empty
  cleanup_status=$?
  if [ "$cleanup_status" -eq 0 ]; then
    ./RetroCloudSyncDaemon --unregister-calendar-test-client
  fi
  if [ "$original_status" -ne 0 ] || [ "$cleanup_status" -ne 0 ]; then export_status=1; fi
  kill "$alert_helper_pid" 2>/dev/null || true
  echo "$export_status" > calendar-tests.status
  exit "$export_status"
}
trap finish EXIT
if ps -axww -o command | grep '/Library/Application Support/RetroCloudSync/RetroCloudSyncDaemon --config' | grep -v grep >/dev/null; then
  echo 'Stop the production daemon before running offline calendar tests.'
  trap - EXIT
  kill "$alert_helper_pid" 2>/dev/null || true
  echo 1 > calendar-tests.status
  exit 1
fi
open -a iCal
export_phase() {
  ./RetroCloudCalendarFixtures "$1" Calendar-active.sqlite
  push_calendar
  wait_for_phase "$2"
}
verify_ical() {
  wanted="$1"
  /usr/bin/osascript - "$wanted" <<'APPLESCRIPT'
on run argv
  set wanted to (item 1 of argv) as integer
  repeat 30 times
    tell application "iCal"
      set cs to every calendar whose name starts with "RCS Calendar Test"
      if (count cs) is 1 then
        set c to item 1 of cs
        if (count every event of c) is wanted then
          set dayEvent to first event of c whose summary is "RCS Calendar Test All Day"
          if not (allday event of dayEvent) then error "All-day flag lost"
          set firstDate to start date of dayEvent
          set lastDate to end date of dayEvent
          if (day of firstDate) is not 20 then error "All-day start changed"
          if (day of lastDate) is not 22 then error "Exclusive all-day end changed"
          set weekly to first event of c whose summary starts with "RCS Calendar Test E"
          if recurrence of weekly contains "BYMONTH=;" then error "Empty recurrence option"
          return "iCal verified"
        end if
      end if
    end tell
    delay 1
  end repeat
  error "Timed out waiting for iCal"
end run
APPLESCRIPT
}
export_phase empty empty
./RetroCloudCalendarVerifier snapshot Calendar-baseline.plist
export_phase initial initial
echo '[PASS] Calendar, events, recurrence, exception, attendee, and alarm imported'
export_phase initial initial
echo '[PASS] Repeated import has no duplicates'
export_phase updated updated
verify_ical 3
echo '[PASS] iCal received the update/deletion and retained date/recurrence semantics'
export_phase malformed updated
/usr/bin/sqlite3 Calendar-active.sqlite "SELECT export_status FROM calendar_resources WHERE href='https://example.test/cal/series.ics';" | grep -q 'retained previous'
echo '[PASS] Malformed download retained the last exported series'
export_phase missing-uid updated
/usr/bin/sqlite3 Calendar-active.sqlite "SELECT export_status FROM calendar_resources WHERE href='https://example.test/cal/series.ics';" | grep -q 'retained previous'
echo '[PASS] Invalid resource identity retained the last exported series'
export_phase unsupported updated
/usr/bin/sqlite3 Calendar-active.sqlite "SELECT export_status FROM calendar_resources WHERE href='https://example.test/cal/series.ics';" | grep -q 'retained previous'
echo '[PASS] Unsupported recurrence retained the last exported series'
export_phase updated updated
export_phase empty empty
./RetroCloudCalendarVerifier baseline Calendar-baseline.plist
echo '[PASS] Cleanup preserved pre-existing calendar/event identifiers'
export_status=0
echo 'Offline calendar integration tests passed.'
