#!/usr/bin/env python3
"""Run the isolated UIKit harness without replacing the installed rCloud app."""
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import tempfile
import uuid
import subprocess
import time
from service_smoke import run as service_smoke

host = os.environ.get('TEST_HOST', '')
if not host:
    raise SystemExit('Set TEST_HOST to an authorized test iPhone.')
build = Path(os.environ['BUILD_ROOT'])
app = build / 'tests/iOS/UI/release/rCloud/rCloud.app'
identity = 'com.altivecintelligence.rcloud.ui-tests'
info = plistlib.loads((app / 'Info.plist').read_bytes())
if info['CFBundleIdentifier'] != identity:
    raise SystemExit('Refusing to install a non-test bundle.')
# A previously installed test IPA may own the old URL scheme. Give each run
# its own identity and require its nonce in the result before accepting a pass.
run_id = uuid.uuid4().hex
identity += '.' + run_id
scheme = 'rcloud-ui-tests-' + run_id
staging = tempfile.TemporaryDirectory(prefix='rcloud-ui-')
staged_app = Path(staging.name) / 'rCloud.app'
shutil.copytree(app, staged_app)
info['CFBundleIdentifier'] = identity
info['CFBundleURLTypes'] = [{'CFBundleURLSchemes': [scheme]}]
info['RCTestRunID'] = run_id
(staged_app / 'Info.plist').write_bytes(plistlib.dumps(info))
entitlements = plistlib.loads((Path(__file__).parent / 'Entitlements.plist').read_bytes())
entitlements['application-identifier'] = identity
entitlement_path = Path(staging.name) / 'Entitlements.plist'
entitlement_path.write_bytes(plistlib.dumps(entitlements))
subprocess.run(['ldid', '-S' + str(entitlement_path), str(staged_app / info['CFBundleExecutable'])], check=True)
remote_app = '/Applications/rCloudUITests-' + run_id + '.app'
cache = '/var/mobile/Library/Caches/RetroCloudUITests'
output = build / 'tests/iOS/UI'
output.mkdir(parents=True, exist_ok=True)

def ssh(command, check=True):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR', host, command],
                          capture_output=True, check=check)

def stop_test_ui():
    jobs = ssh('launchctl list').stdout.decode()
    for line in jobs.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2].startswith('UIKitApplication:' + identity + '['):
            ssh('launchctl stop ' + shlex.quote(fields[2]))

stop_test_ui()
ssh('test ! -e ' + remote_app + ' || rm -rf ' + remote_app)
subprocess.run(['scp', '-q', '-O', '-r', str(staged_app), host + ':' + remote_app], check=True)
try:
    ssh('rm -f ' + cache + '/result.plist ' + cache + '/Config.plist')
    ssh('su mobile -c uicache')
    ssh('su mobile -c ' + shlex.quote('uiopen ' + scheme + '://'))
    for _ in range(60):
        result = ssh('cat ' + cache + '/result.plist', check=False)
        if result.returncode == 0:
            report = plistlib.loads(result.stdout)
            if report.get('RunID') != run_id:
                time.sleep(1)
                continue
            (output / 'result.plist').write_bytes(result.stdout)
            print(report, flush=True)
            for name in ('status.png', 'account.png', 'log.png'):
                subprocess.run(['scp', '-q', '-O', host + ':' + cache + '/' + name, str(output / name)], check=False)
            if report['Result'] != 'PASS':
                raise SystemExit('UIKit tests failed')
            service_smoke(ssh, host, build, remote_app)
            break
        time.sleep(1)
    else:
        raise SystemExit('UIKit test timed out; check the unlocked test device.')
finally:
    stop_test_ui()
    ssh('rm -rf ' + remote_app)
    ssh('su mobile -c uicache')
    staging.cleanup()
