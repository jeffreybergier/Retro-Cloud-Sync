#!/bin/bash

set -euo pipefail

test_host="${TEST_HOST:-x4-vm}"
build_root="${BUILD_ROOT:?BUILD_ROOT is required}"
run_name="RetroCloudSync-SyncServicesTests-$(date +%Y%m%d-%H%M%S)-$$"
remote_relative="Desktop/${run_name}"

ssh "${test_host}" "
if ps -axww -o command | grep '/Library/Application Support/RetroCloudSync/RetroCloudSyncDaemon --config' | grep -v grep >/dev/null; then
  echo 'The production Retro Cloud Sync daemon must be stopped' >&2
  exit 1
fi
mkdir -p '${remote_relative}'
"

scp "${build_root}/macOS-daemon/release/RetroCloudSyncDaemon" \
  "${test_host}:${remote_relative}/"
scp "${build_root}/syncservices-test/RetroCloudSyncSyncServicesVerifier" \
  "${test_host}:${remote_relative}/"
scp "${build_root}/syncservices-test/Contacts-initial.sqlite" \
  "${build_root}/syncservices-test/Contacts-updated.sqlite" \
  "${build_root}/syncservices-test/Contacts-empty.sqlite" \
  "${test_host}:${remote_relative}/"
scp "${build_root}/macOS-app/release/RetroCloudSync.app/Contents/Resources/SyncClient.plist" \
  "${test_host}:${remote_relative}/"

echo "--- Running offline Sync Services tests on ${test_host} ---"
ssh "${test_host}" "cd '${remote_relative}' && /bin/bash -s" <<'REMOTE_TEST'
set -eu

daemon="./RetroCloudSyncDaemon"
verifier="./RetroCloudSyncSyncServicesVerifier"
description="./SyncClient.plist"

chmod +x "${daemon}" "${verifier}"

wait_for_phase() {
  phase="$1"
  attempts=0
  while ! "${verifier}" "${phase}" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "${attempts}" -ge 60 ]; then
      "${verifier}" "${phase}" || true
      echo "Timed out waiting for Address Book phase: ${phase}" >&2
      return 1
    fi
    sleep 1
  done
}

cleanup_test_client() {
  set +e
  "${daemon}" --test-syncservices ./Contacts-empty.sqlite "${description}"
  wait_for_phase empty
  "${daemon}" --unregister-syncservices-test-client
}

trap cleanup_test_client EXIT

# Remove leftovers from an interrupted prior test, but never touch records from
# the production client or records which predate this test.
"${daemon}" --test-syncservices ./Contacts-empty.sqlite "${description}"
wait_for_phase empty
"${verifier}" snapshot ./AddressBook-baseline.plist
echo "[PASS] Existing Address Book baseline captured"

"${daemon}" --test-syncservices ./Contacts-initial.sqlite "${description}"
wait_for_phase initial
echo "[PASS] Synthetic contacts and child properties were added"

"${daemon}" --test-syncservices ./Contacts-initial.sqlite "${description}"
wait_for_phase initial
echo "[PASS] Re-export did not duplicate synthetic contacts"

"${daemon}" --test-syncservices ./Contacts-updated.sqlite "${description}"
wait_for_phase updated
echo "[PASS] Contact fields were updated and an omitted contact was deleted"

"${daemon}" --test-syncservices ./Contacts-empty.sqlite "${description}"
wait_for_phase empty
"${verifier}" baseline ./AddressBook-baseline.plist
echo "[PASS] Test contacts were removed and existing contacts were preserved"

"${daemon}" --unregister-syncservices-test-client
trap - EXIT
echo "Offline Sync Services tests passed."
REMOTE_TEST

echo "Sync Services test artifacts: ${test_host}:~/${remote_relative}"
