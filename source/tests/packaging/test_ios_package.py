#!/usr/bin/env python3
"""Offline lifecycle and archive checks; never signal an installed process."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]

class PackageTests(unittest.TestCase):
    def test_lifecycle_orders_shutdown_before_gui(self):
        for running, stuck in ((False, False), (True, False), (True, True)):
            with self.subTest(running=running, stuck=stuck), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                log = root / 'events'
                env = dict(os.environ, EVENTS=str(log))
                script = '''
launchctl() {
  echo "launchctl $*" >> "$EVENTS"
  if [ "$1" = list ]; then printf '%s\n' 'PID 0 com.altivecintelligence.rcloudd' '456 0 UIKitApplication:com.altivecintelligence.rcloud[0x123]' '789 0 UIKitApplication:com.altivecintelligence.rcloud.ui-tests[0x123]'; fi
}
kill() { echo "kill $*" >> "$EVENTS"; if [ "$1" = -0 ]; then return STUCK; fi; }
killall() { echo "killall $*" >> "$EVENTS"; if [ "$1" = -0 ]; then return 1; fi; }
sleep() { :; }
'''.replace('PID', '123' if running else '-').replace('STUCK', '0' if stuck else '1')
                script += (SOURCE / 'iOS-daemon/package/lifecycle.sh').read_text()
                script += '\nrc_stop && rc_stop_ui\n'
                result = subprocess.run(['sh', '-c', script], env=env, capture_output=True)
                events = log.read_text()
                if stuck:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('kill -TERM 456', events)
                    self.assertNotIn('launchctl unload', events)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertLess(events.index('launchctl unload'), events.index('kill -TERM 456'))
                    self.assertNotIn('kill -TERM 789', events)

    def test_archive_and_version_guard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'rCloud.app'
            app.mkdir()
            (app / 'rCloud').write_bytes(b'test executable')
            info = plistlib.loads((SOURCE / 'iOS-daemon/Info.plist').read_bytes())
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            command = ['bash', str(SOURCE / 'make/scripts/package-ios.sh'), str(root), str(SOURCE)]
            subprocess.run(command, check=True, capture_output=True)
            archive = root / 'rCloud-rootful.deb'
            metadata = subprocess.check_output(['dpkg-deb', '-f', str(archive)], text=True)
            self.assertIn('Version: ' + info['CFBundleShortVersionString'], metadata)
            self.assertIn('Installed-Size:', metadata)
            self.assertIn('Architecture: iphoneos-arm', metadata)
            control = root / 'control'
            subprocess.run(['dpkg-deb', '-e', str(archive), str(control)], check=True)
            for name in ('preinst', 'postinst', 'prerm', 'postrm'):
                hook = control / name
                self.assertEqual(hook.stat().st_mode & 0o777, 0o755)
                subprocess.run(['sh', '-n', str(hook)], check=True)
            for name in ('preinst', 'prerm'):
                self.assertIn('rc_stop; rc_stop_ui; rc_unregister', (control / name).read_text())
            info['CFBundleVersion'] = 'invalid'
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            result = subprocess.run(command, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'versions do not match', result.stderr)

if __name__ == '__main__':
    unittest.main()
