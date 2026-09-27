#!/usr/bin/env python3
"""Isolated daemon shutdown test. No installed service, Keychain or iCloud access."""
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import time

host = os.environ.get('TEST_HOST') or 'x4-vm'
root = Path(os.environ['BUILD_ROOT']) / 'tests/macOS/shutdown'
root.mkdir(parents=True, exist_ok=True)
remote = 'Desktop/RetroCloudSync-Shutdown-' + time.strftime('%Y%m%d-%H%M%S')
ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host]
def run(command):
    return subprocess.run(ssh + [command], check=True, capture_output=True, text=True, timeout=30).stdout

configuration = {
    'ConfigurationVersion': 1,
    'Contacts': {'Username': 'shutdown-fixture@example.invalid', 'ServiceURL': 'https://contacts.icloud.com',
                 'ContactsSyncMode': 'OneWay', 'CalendarsSyncMode': 'Disabled', 'SyncIntervalSeconds': 60},
    'MailProxy': {'IMAP': {'LocalPort': 31143, 'RemoteHost': 'fixture.invalid', 'RemotePort': 993},
                  'SMTP': {'LocalPort': 31587, 'RemoteHost': 'fixture.invalid', 'RemotePort': 587}}}
# The production daemon runs under a different filename. Its credential helper
# launch is intercepted by this fixture; no Keychain call ever takes place.
helper = '#!/bin/sh\necho $$ > helper.pid\nexec /bin/sleep 30\n'
script = '''#!/bin/sh
set -eu
"$(pwd)/DaemonUnderTest" --config "$(pwd)/Configuration.plist" > daemon.log 2>&1 < /dev/null &
daemon=$!
trap 'kill -TERM "$daemon" 2>/dev/null || true' EXIT
attempt=0
while test ! -f helper.pid; do
  kill -0 "$daemon"
  attempt=$((attempt+1)); test "$attempt" -lt 15
  sleep 1
done
kill -TERM "$daemon"
attempt=0
while kill -0 "$daemon" 2>/dev/null; do
  attempt=$((attempt+1)); test "$attempt" -lt 6
  sleep 1
done
wait "$daemon"
helper=$(cat helper.pid)
if kill -0 "$helper" 2>/dev/null; then echo 'Credential helper survived'; exit 1; fi
trap - EXIT
echo 'SIGTERM interrupted a blocked credential read and stopped the daemon within 5 seconds.'
'''
with tempfile.TemporaryDirectory() as temporary:
    files = Path(temporary)
    (files / 'Configuration.plist').write_bytes(plistlib.dumps(configuration))
    (files / 'rcloudd').write_text(helper)
    (files / 'run.command').write_text(script)
    run('mkdir ' + shlex.quote(remote))
    def copy(source, name):
        subprocess.run(['scp', '-O', '-o', 'BatchMode=yes', str(source), host + ':' + remote + '/' + name], check=True, timeout=30)
    copy(os.environ['DAEMON_OUTPUT'], 'DaemonUnderTest')
    copy(os.environ['SESSION_TEST_OUTPUT'], 'SessionCancellationTests')
    copy(os.environ['CA_CERTIFICATE'], 'cacert.pem')
    for name in ('Configuration.plist', 'rcloudd', 'run.command'):
        copy(files / name, name)
    try:
        output = run('cd ' + shlex.quote(remote) + ' && chmod +x DaemonUnderTest rcloudd SessionCancellationTests run.command && ./SessionCancellationTests --cancellation-only && ./run.command')
        print(output, end='')
    finally:
        subprocess.run(['scp', '-O', '-o', 'BatchMode=yes', host + ':' + remote + '/daemon.log', str(root / 'daemon.log')], check=False, timeout=30)
    subprocess.run(['scp', '-O', '-o', 'BatchMode=yes', host + ':' + remote + '/Status.plist', str(root / 'Status.plist')], check=True, timeout=30)
    status = plistlib.loads((root / 'Status.plist').read_bytes())
    assert status['Running'] is False and status['Stopping'] is True
    assert status['Contacts']['Phase'] == 'Stopping'
    assert 'ErrorCode' not in status['Contacts'] and 'LastSuccess' not in status['Contacts']
    configuration['Contacts']['ContactsSyncMode'] = 'Disabled'
    (files / 'Configuration.plist').write_bytes(plistlib.dumps(configuration))
    idle = script.replace('while test ! -f helper.pid; do', 'while test ! -f Status.plist; do')
    idle = idle[:idle.index('helper=$(cat helper.pid)')] + idle[idle.index('trap - EXIT'):]
    idle = idle.replace('SIGTERM interrupted a blocked credential read and stopped the daemon within 5 seconds.', 'SIGTERM stopped an idle daemon within 5 seconds.')
    (files / 'run.command').write_text(idle)
    run('cd ' + shlex.quote(remote) + ' && rm Status.plist helper.pid')
    copy(files / 'Configuration.plist', 'Configuration.plist')
    copy(files / 'run.command', 'run.command')
    print(run('cd ' + shlex.quote(remote) + ' && ./run.command'), end='')
    # Sync startup errors must leave both mail listeners and normal shutdown
    # available. Invalid settings prevent all Keychain and sync network work.
    startup = '''#!/bin/sh
set -eu
"$(pwd)/DaemonUnderTest" --config "$(pwd)/Configuration.plist" > daemon.log 2>&1 < /dev/null &
daemon=$!
trap 'kill -TERM "$daemon" 2>/dev/null || true' EXIT
sleep 2
kill -0 "$daemon"
/usr/bin/python -c 'import socket; a=socket.socket(); a.connect(("127.0.0.1",31143)); a.close(); b=socket.socket(); b.connect(("127.0.0.1",31587)); b.close()'
cp Status.plist Running.plist
kill -TERM "$daemon"
wait "$daemon"
trap - EXIT
'''
    for invalid in ('invalid dictionary',
                    dict(configuration['Contacts'], ContactsSyncMode='invalid'),
                    dict(configuration['Contacts'], CalendarHistoryYears=3)):
        configuration['Contacts'] = invalid
        (files / 'Configuration.plist').write_bytes(plistlib.dumps(configuration))
        (files / 'run.command').write_text(startup)
        copy(files / 'Configuration.plist', 'Configuration.plist')
        copy(files / 'run.command', 'run.command')
        run('cd ' + shlex.quote(remote) + ' && ./run.command')
        copy_result = subprocess.run(['scp', '-O', '-o', 'BatchMode=yes',
            host + ':' + remote + '/Running.plist', str(root / 'Running.plist')],
            check=True, timeout=30)
        running = plistlib.loads((root / 'Running.plist').read_bytes())
        assert running['Running'] is True
        for service in ('Contacts', 'Calendars'):
            assert running[service]['ErrorCode'] == 'Configuration'
            assert 'LastSuccess' not in running[service]
    print('Both mail listeners survived malformed sync settings, invalid modes and invalid history.')
print('Shutdown status and child cleanup passed. Artifacts:', root)
