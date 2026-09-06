#!/bin/bash

set -euo pipefail

test_host="${TEST_HOST:-x4-vm}"
build_root="${BUILD_ROOT:?BUILD_ROOT is required}"
run_name="RetroCloudSync-app-Tests-$(date +%Y%m%d-%H%M%S)-$$"
remote_relative="Desktop/${run_name}"

ssh "${test_host}" "mkdir -p '${remote_relative}/screenshots'"
scp -r "${build_root}/macOS-app/release/RetroCloudSync.app" \
  "${test_host}:${remote_relative}/"
scp "${build_root}/tests/macOS/app/release/RetroCloudAppGUITests" \
  "${test_host}:${remote_relative}/"

echo "--- Running app tests on ${test_host} ---"
if ssh "${test_host}" \
  "cd '${remote_relative}' && chmod +x RetroCloudAppGUITests && ./RetroCloudAppGUITests --app \"\$HOME/${remote_relative}/RetroCloudSync.app\" --screenshots \"\$HOME/${remote_relative}/screenshots\""; then
  echo "app test artifacts: ${test_host}:~/${remote_relative}"
else
  local_artifacts="${build_root}/tests/macOS/app/remote-artifacts/${run_name}"
  mkdir -p "${local_artifacts}"
  scp -r "${test_host}:${remote_relative}/screenshots" \
    "${local_artifacts}/" 2>/dev/null || true
  echo "app test failed; screenshots copied to ${local_artifacts}" >&2
  exit 1
fi
