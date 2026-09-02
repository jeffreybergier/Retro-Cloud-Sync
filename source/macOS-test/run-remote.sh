#!/bin/bash

set -euo pipefail

test_host="${TEST_HOST:-x4-vm}"
build_root="${BUILD_ROOT:?BUILD_ROOT is required}"
project_root="${PROJECT_ROOT:?PROJECT_ROOT is required}"
run_name="RetroCloudSync-GUITests-$(date +%Y%m%d-%H%M%S)-$$"
remote_relative="Desktop/${run_name}"

ssh "${test_host}" "mkdir -p '${remote_relative}/screenshots'"
scp -r "${build_root}/macOS-app/release/RetroCloudSync.app" \
  "${test_host}:${remote_relative}/"
scp "${build_root}/macOS-test/release/RetroCloudSyncTests" \
  "${test_host}:${remote_relative}/"

echo "--- Running GUI tests on ${test_host} ---"
if ssh "${test_host}" \
  "cd '${remote_relative}' && chmod +x RetroCloudSyncTests && ./RetroCloudSyncTests --app \"\$HOME/${remote_relative}/RetroCloudSync.app\" --screenshots \"\$HOME/${remote_relative}/screenshots\""; then
  echo "GUI test artifacts: ${test_host}:~/${remote_relative}"
else
  local_artifacts="${project_root}/build/macOS-test/remote-artifacts/${run_name}"
  mkdir -p "${local_artifacts}"
  scp -r "${test_host}:${remote_relative}/screenshots" \
    "${local_artifacts}/" 2>/dev/null || true
  echo "GUI test failed; screenshots copied to ${local_artifacts}" >&2
  exit 1
fi
