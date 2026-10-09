#!/usr/bin/env python3
"""Run offline fixtures as mobile under launchd using the installed app identity.
The installed daemon must be unloaded first. Restore its executable afterwards.
"""
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import time

host = os.environ.get('TEST_HOST', '')
if not host:
    raise SystemExit('Set TEST_HOST to an authorized test iPhone.')
root = Path(os.environ['PROJECT_ROOT'])
build = Path(os.environ['BUILD_ROOT'])
app = '/Applications/rCloud.app/rCloud'
label = 'com.altivecintelligence.rcloud.native-tests'
remote = '/var/mobile/Library/Caches/RetroCloudIOS-' + time.strftime('%Y%m%d-%H%M%S', time.gmtime())
logs = build / 'tests/iOS' / Path(remote).name
logs.mkdir(parents=True, exist_ok=False)

def ssh(command, check=True):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR', host, command],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check)

def copy(source, destination):
    subprocess.run(['scp', '-q', '-O', str(source), host + ':' + destination], check=True)

jobs = ssh('launchctl list').stdout
if any(line.endswith('\tcom.altivecintelligence.rcloudd') or line.endswith('\t' + label) for line in jobs.splitlines()):
    raise SystemExit('Unload the rCloud daemon and any earlier test job before this suite.')
ssh('su mobile -c ' + shlex.quote(app + ' --access'))
ssh('mkdir -p ' + shlex.quote(remote) + '; chmod 700 ' + shlex.quote(remote) +
    '; chown mobile:mobile ' + shlex.quote(remote) + '; cp ' + app + ' ' + shlex.quote(remote + '/original'))
loaded = False
completed = False
try:
    with tempfile.TemporaryDirectory() as tmp:
        plist = Path(tmp) / 'test.plist'
        plist.write_bytes(plistlib.dumps({
            'Label': label, 'ProgramArguments': [app, '--native-tests', remote],
            'UserName': 'mobile', 'GroupName': 'mobile', 'RunAtLoad': True,
            'WorkingDirectory': remote,
            'StandardOutPath': remote + '/test.log', 'StandardErrorPath': remote + '/error.log',
        }))
        copy(build / 'iOS-tests/rCloud.app/rCloud', app + '-test-new')
        ssh('chmod 755 ' + app + '-test-new; mv ' + app + '-test-new ' + app)
        copy(plist, remote + '/test.plist')
    loaded = True  # A connection failure can leave the remote load successful.
    ssh('launchctl load ' + shlex.quote(remote + '/test.plist'))
    print('Offline native tests: ' + host + ':' + remote, flush=True)
    last = ''
    for _ in range(180):
        time.sleep(5)
        output = ssh('cat ' + shlex.quote(remote + '/test.log'), check=False).stdout
        if output != last:
            print(output[len(last):], end='', flush=True)
            last = output
        job = ssh('launchctl list').stdout
        rows = [line.split() for line in job.splitlines() if line.endswith('\t' + label)]
        if rows and rows[0][0] == '-':
            completed = True
            if rows[0][1] != '0' or 'FAIL:' in output:
                raise RuntimeError('Native test failure; inspect retained logs and fixture journals.')
            break
    if not completed:
        raise RuntimeError('Test is still running; executable/job retained for safe completion. ' + remote)
finally:
    for name in ('test.log', 'error.log'):
        result = ssh('cat ' + shlex.quote(remote + '/' + name), check=False)
        (logs / name).write_text(result.stdout)
    if completed or not loaded:
        if loaded:
            ssh('launchctl unload ' + shlex.quote(remote + '/test.plist'))
        ssh('cp ' + shlex.quote(remote + '/original') + ' ' + app + '-restored; chmod 755 ' + app +
            '-restored; mv ' + app + '-restored ' + app)
print('Logs: ' + str(logs), flush=True)
