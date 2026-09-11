#!/bin/bash
set -eu
cd "$(dirname "$0")"
exec > two-way.log 2>&1
lock="$HOME/Desktop/.RetroCloudSync-ContactsTests.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo 'Contacts tests already own the Desktop lock.'
  echo 1 > status
  exit 1
fi
echo "$$ $(pwd)" > "$lock/owner"
helper_pid=
baseline=0
finish() {
  status=$?
  trap - EXIT
  set +e
  if [ "$baseline" -eq 1 ]; then
    attempts=0
    until ./RetroCloudContactsSyncServicesVerifier baseline AddressBook-baseline.plist > baseline.log 2>&1; do
      attempts=$((attempts+1))
      if [ "$attempts" -ge 60 ]; then cat baseline.log; status=1; break; fi
      sleep 1
    done
  fi
  if [ -n "$helper_pid" ]; then kill "$helper_pid" 2>/dev/null; wait "$helper_pid" 2>/dev/null; fi
  if [ "$status" -ne 0 ]; then /usr/sbin/screencapture -x two-way-failure.png 2>/dev/null; fi
  rm -f "$lock/owner"
  rmdir "$lock"
  echo "$status" > status
  exit "$status"
}
trap finish EXIT
if ps -axww -o command | grep '/Library/Application Support/\(RetroCloudSync\|rCloud\)/\(RetroCloudSyncDaemon\|rcloudd\) --config' | grep -v grep >/dev/null; then
  echo 'Stop the production daemon before running two-way tests.'
  exit 1
fi
./RetroCloudContactsSyncServicesVerifier snapshot AddressBook-baseline.plist
baseline=1
/usr/bin/osascript - "$PWD" <<'APPLESCRIPT' &
on run argv
  set artifactDirectory to item 1 of argv
  set reviewCaptured to false
  repeat 1800 times
    try
      tell application "System Events"
        if exists process "syncuid" then
          tell process "syncuid"
            if exists window "Sync Alert" then
              set alertText to value of every static text of window "Sync Alert"
              if (alertText as text) contains "Retro Cloud Two Way Tests" then
                click button "Allow" of window "Sync Alert"
              end if
            end if
          end tell
        end if
        if exists process "Conflict Resolver" then
          tell process "Conflict Resolver"
            if exists button "Review Now" of window 1 then click button "Review Now" of window 1
            if (exists button "Done" of group 1 of window 1) and not reviewCaptured then
              set frontmost to true
              do shell script "/usr/sbin/screencapture -x " & quoted form of (artifactDirectory & "/conflict-review.png")
              log "Conflict review ready: " & artifactDirectory & "/conflict-review.png"
              set reviewCaptured to true
            end if
          end tell
        else
          set reviewCaptured to false
        end if
      end tell
    end try
    delay 1
  end repeat
end run
APPLESCRIPT
helper_pid=$!
./TwoWaySyncTests --mappers
./TwoWaySyncTests "$@"
echo 'PASS: Two-way fixtures removed and test clients unregistered'
