#!/bin/bash
# Tiger Sync Services confirmation UI needs the logged-in desktop session.
set -eu
cd "$(dirname "$0")"
exec > contacts-tests.log 2>&1
lock="$HOME/Desktop/.RetroCloudSync-ContactsTests.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo 'Another contacts test owns the Desktop test lock; inspect it before retrying.'
  echo 1 > contacts-tests.status
  exit 1
fi
echo "$$ $(pwd)" > "$lock/owner"
daemon=./RetroCloudSyncDaemon
verifier=./RetroCloudContactsSyncServicesVerifier
description=./ContactsTestSyncClient.plist
history=./Contacts-truth-history.plist
helper_pid=
started=0

push_contacts() {
  attempts=0
  until "$daemon" --test-syncservices "./Contacts-$1.sqlite" "$description"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then return 1; fi
    sleep 2
  done
  test "$(/usr/bin/sqlite3 "./Contacts-$1.sqlite" "SELECT generation>0 AND generation=published_generation FROM accounts WHERE username='syncservices-test';")" = 1
}
wait_for_phase() {
  attempts=0
  until "$verifier" "$1" "$history" > phase-verification.log 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      cat phase-verification.log
      echo "Timed out waiting for contacts phase: $1"
      return 1
    fi
    sleep 1
  done
}
finish() {
  status=$?
  trap - EXIT
  set +e
  if [ "$status" -ne 0 ]; then
    "$verifier" diagnose "$history" > contacts-diagnostics.log 2>&1
    /usr/sbin/screencapture -x contacts-failure.png 2>/dev/null || true
  fi
  if [ "$started" -eq 1 ]; then
    # Preserve registration for recovery if deletion cannot be verified.
    if push_contacts empty && wait_for_phase empty; then
      "$daemon" --unregister-syncservices-test-client || status=1
      "$verifier" unregistered || status=1
    else
      echo 'FAIL: Cleanup incomplete; test client retained for recovery.'
      status=1
    fi
    "$verifier" baseline AddressBook-baseline.plist || status=1
  fi
  if [ -n "$helper_pid" ]; then
    kill "$helper_pid" 2>/dev/null || true
    wait "$helper_pid" 2>/dev/null || true
  fi
  if [ "$status" -ne 0 ]; then
    "$verifier" diagnose "$history" > contacts-cleanup-diagnostics.log 2>&1
  else
    echo '[PASS] Cleanup removed contacts and child records, unregistered the client, and preserved existing Address Book contents/groups'
    echo 'Offline contacts Sync Services tests passed.'
  fi
  rm -f "$lock/owner"
  rmdir "$lock"
  echo "$status" > contacts-tests.status
  exit "$status"
}
trap finish EXIT
if ps -axww -o command | grep '/Library/Application Support/RetroCloudSync/RetroCloudSyncDaemon --config' | grep -v grep >/dev/null; then
  echo 'Stop the production daemon before running offline contacts tests.'
  exit 1
fi
sed 's/Retro Cloud Sync Contacts/Retro Cloud Contacts Tests/' SyncClient.plist > "$description"
chmod +x "$daemon" "$verifier"
"$verifier" snapshot AddressBook-baseline.plist
"$verifier" client-registration "$description"
echo '[PASS] Account-scoped production client identifier registers and cleans up on Tiger'
/usr/bin/osascript <<'APPLESCRIPT' &
repeat 1800 times
  tell application "System Events"
    if exists process "syncuid" then
      tell process "syncuid"
        if exists window "Sync Alert" then
          set alertText to value of every static text of window "Sync Alert"
          if (alertText as text) contains "Retro Cloud Contacts Tests" then
            click button "Allow" of window "Sync Alert"
          end if
        end if
      end tell
    end if
  end tell
  delay 1
end repeat
APPLESCRIPT
helper_pid=$!
started=1
open -a 'Address Book'
push_contacts empty
wait_for_phase empty
"$verifier" baseline AddressBook-baseline.plist
for phase in initial initial; do
  push_contacts "$phase"
  wait_for_phase "$phase"
  "$verifier" baseline AddressBook-baseline.plist
done
echo '[PASS] Initial and repeated exports: exact values, Unicode, birthday, labels, preferred entries, company flag, truth relationships and stable identities'
if "$daemon" --test-syncservices ./Contacts-fresh.sqlite "$description" > fresh-export.log 2>&1; then
  echo 'FAIL: A never-completed mirror unexpectedly exported'
  exit 1
fi
grep 'no complete inventory' fresh-export.log >/dev/null
wait_for_phase initial
for phase in retained interrupted; do
  push_contacts "$phase"
  wait_for_phase initial
  "$verifier" baseline AddressBook-baseline.plist
  echo "[PASS] $phase: previous complete graph published from durable cache"
done
for phase in malformed missing-identity; do
  if "$daemon" --test-syncservices "./Contacts-$phase.sqlite" "$description" > "$phase-export.log" 2>&1; then
    echo "FAIL: Invalid fixture unexpectedly exported: $phase"
    exit 1
  fi
  # Ensure this is the intended failure, not an unrelated unavailable service.
  case "$phase" in
    malformed) expected_error="not a complete vCard" ;;
    missing-identity) expected_error="sync identity is missing" ;;
  esac
  if ! grep -i "$expected_error" "$phase-export.log" >/dev/null; then
    echo "FAIL: $phase failed for an unexpected reason"
    cat "$phase-export.log"
    exit 1
  fi
  test "$(/usr/bin/sqlite3 "./Contacts-$phase.sqlite" "SELECT generation>published_generation FROM accounts WHERE username='syncservices-test';")" = 1
  wait_for_phase initial
  "$verifier" baseline AddressBook-baseline.plist
  push_contacts initial
  wait_for_phase initial
  echo "[PASS] $phase rejected, previous graph preserved, valid replay recovered"
done
for phase in reordered updated stripped; do
  push_contacts "$phase"
  wait_for_phase "$phase"
  "$verifier" baseline AddressBook-baseline.plist
  echo "[PASS] $phase: exact fields and relationships; no stale or orphaned records"
done
# EXIT always verifies cleanup and makes its failures affect the result.
