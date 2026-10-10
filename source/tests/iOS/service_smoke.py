"""Offline daemon reload test using only an isolated cache and loopback ports."""
from datetime import datetime
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import time


def run(ssh, host, build, app):
    root = '/var/mobile/Library/Caches/RetroCloudServiceTests'
    label = 'com.altivecintelligence.rcloud.service-tests'
    if label.encode() in ssh('launchctl list').stdout:
        raise RuntimeError('A previous service test is still registered')

    def listening(port):
        return ssh('/bin/bash -c ' + shlex.quote('exec 3<>/dev/tcp/127.0.0.1/' + str(port)), check=False).returncode == 0

    if listening(24143) or listening(24587):
        raise RuntimeError('Test ports are already in use')
    ssh('mkdir -p ' + root + '; chown mobile:mobile ' + root + '; chmod 700 ' + root)
    fixture = {
        'ConfigurationVersion': 1,
        'Contacts': {'Username': '', 'ContactsSyncMode': 'Disabled', 'CalendarsSyncMode': 'Disabled',
                     'CalendarHistoryYears': 2, 'SyncIntervalSeconds': 300},
        'MailProxy': {'Enabled': True,
                      'IMAP': {'LocalPort': 24143, 'RemoteHost': '127.0.0.1', 'RemotePort': 9},
                      'SMTP': {'LocalPort': 24587, 'RemoteHost': '127.0.0.1', 'RemotePort': 9}}
    }
    loaded = False
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)

        def copy_plist(value, name):
            source = temp / name
            source.write_bytes(plistlib.dumps(value))
            subprocess.run(['scp', '-q', '-O', str(source), host + ':' + root + '/' + name + '.new'], check=True)
            ssh('chown mobile:mobile ' + root + '/' + name + '.new; chmod 600 ' + root + '/' + name + '.new; mv ' + root + '/' + name + '.new ' + root + '/' + name)

        def save():
            fixture['SettingsUpdatedAt'] = datetime.now()
            copy_plist(fixture, 'Config.plist')

        def wait(running, ports):
            for _ in range(30):
                result = ssh('cat ' + root + '/Status.plist', check=False)
                if result.returncode == 0:
                    status = plistlib.loads(result.stdout)
                    if status.get('Running') == running and listening(24143) == ports and listening(24587) == ports:
                        return
                time.sleep(1)
            raise RuntimeError('Daemon did not reach the expected service/listener state')

        save()
        copy_plist({'Label': label, 'ProgramArguments': [app + '/rCloud', '--config', root + '/Config.plist'],
                    'UserName': 'mobile', 'GroupName': 'mobile', 'RunAtLoad': True,
                    'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 1,
                    'StandardOutPath': root + '/daemon.log', 'StandardErrorPath': root + '/daemon.log'}, 'launchd.plist')
        try:
            loaded = True
            ssh('chown 0:0 ' + root + '/launchd.plist; chmod 644 ' + root + '/launchd.plist')
            result = ssh('launchctl load ' + root + '/launchd.plist')
            if label.encode() not in ssh('launchctl list').stdout:
                raise RuntimeError('Test job was not loaded: ' + (result.stdout + result.stderr).decode())
            wait(True, True)
            fixture['ServicePaused'] = True
            save()
            wait(False, False)
            fixture['ServicePaused'] = False
            save()
            wait(True, True)
            fixture['MailProxy']['Enabled'] = False
            save()
            wait(True, False)
            fixture['MailProxy']['Enabled'] = True
            save()
            wait(True, True)
            print('PASS: daemon Pause/Resume and independent Mail enable reloads', flush=True)
        finally:
            if loaded:
                # No native stores or remote accounts are opened by this fixture.
                ssh('launchctl unload ' + root + '/launchd.plist')
            (build / 'tests/iOS/UI/service.log').write_bytes(ssh('cat ' + root + '/daemon.log', check=False).stdout)
