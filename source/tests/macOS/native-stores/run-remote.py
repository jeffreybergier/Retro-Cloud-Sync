#!/usr/bin/env python3
"""Deploy the container-built harness; run only disposable, offline native tests."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import time

host = os.environ.get('TEST_HOST', 'x9-local')
project = Path(os.environ.get('PROJECT_ROOT', '.')).resolve()
build = Path(os.environ.get('BUILD_ROOT', 'build')).resolve()
artifacts = build / 'tests/macOS/native-stores'
run = 'run-' + time.strftime('%Y%m%d-%H%M%S')
remote = 'Desktop/RetroCloudNativeTests'
app = 'rCloud Native Tests.app/Contents'
def ssh(command, **kwargs):
    return subprocess.run(['ssh', host, command], check=True, **kwargs)

# Never replace the executable of an active test, or run two native tests at once.
ssh('test "$(stat -f %Su /dev/console)" != root || { echo "Log into the Mac desktop first" >&2; exit 1; }')
ssh('if pgrep -x rcloudd >/dev/null; then echo "Stop the production daemon before native tests" >&2; exit 1; fi')
ssh('if pgrep -f "[N]ativeStoreTests" >/dev/null; then echo "Native test already running" >&2; exit 1; fi')
ssh('mkdir -p "$HOME/' + remote + '/' + run + '"')
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode='w:gz') as tar:
    tar.add(artifacts / 'rCloud Native Tests.app', arcname='rCloud Native Tests.app')
ssh('tar -xzf - -C "$HOME/' + remote + '"', input=archive.getvalue())
ssh('open "$HOME/' + remote + '/rCloud Native Tests.app" --args "$HOME/' + remote + '/' + run + '"')
print('Offline test started on ' + host + '; approve Contacts and Calendar prompts if shown.', flush=True)
print('Remote artifacts: ~/' + remote + '/' + run, flush=True)
logfile = artifacts / (run + '.log')
previous = ''
for _ in range(180):
    time.sleep(5)
    result = ssh('cat "$HOME/' + remote + '/' + run + '/test.log" 2>/dev/null || true', capture_output=True, text=True)
    log = result.stdout
    if log != previous:
        print(log[len(previous):], end='', flush=True)
        logfile.write_text(log)
        previous = log
    if 'Native store offline suite; disposable' in log:
        raise SystemExit(0)
    if 'FAIL:' in log or 'Cleanup needs retry:' in log:
        raise SystemExit(1)
raise SystemExit('Test still waiting; inspect the remote log and prompts before retrying.')
