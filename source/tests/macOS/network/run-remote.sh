#!/bin/bash
# Linux runner for a standalone Mac HTTPS check; no GUI or account credentials.
set -euo pipefail
test_host="${TEST_HOST:-x4-vm}"
build_root="${BUILD_ROOT:?BUILD_ROOT is required}"
certificate_path="${CA_CERTIFICATES:?CA_CERTIFICATES is required}"
run_name="RetroCloudSync-NetworkTests-$(date +%Y%m%d-%H%M%S)-$$"
remote_relative="Desktop/$run_name"
local_artifacts="$build_root/tests/macOS/network/$run_name"
mkdir -p "$local_artifacts"
ssh -o LogLevel=ERROR "$test_host" "mkdir -p '$remote_relative'"
scp -o LogLevel=ERROR "$build_root/tests/macOS/network/RetroCloudHTTPSDownloadTest" \
  "$test_host:$remote_relative/"
scp -o LogLevel=ERROR "$certificate_path" "$test_host:$remote_relative/cacert.pem"
status=0
ssh -o LogLevel=ERROR "$test_host" \
  "cd '$remote_relative' && ./RetroCloudHTTPSDownloadTest cacert.pem download.jpg" \
  > "$local_artifacts/network.log" 2>&1 || status=$?
cat "$local_artifacts/network.log"
echo "Network test artifacts: $test_host:~/$remote_relative; $local_artifacts"
exit "$status"
