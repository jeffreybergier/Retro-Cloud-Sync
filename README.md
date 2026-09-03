# Retro-Cloud-Sync
Sync iCloud Email, Contacts, Calendars with Retro Macs 10.4+

## Contacts and Calendars preferences

Open the application and choose **Sync** in the toolbar. Enter the Apple ID
used for iCloud, an app-specific password, select Contacts and/or Calendars,
and choose the desired sync interval. The password is stored in the user's
login Keychain and is never written to the configuration file or LaunchAgent.
Restart the background service after changing sync settings.

The Calendars selection is saved with the account settings for the calendar
sync engine; the current daemon build only performs the Contacts mirror.

When enabled, the daemon downloads contacts immediately after it starts and
then at the configured interval. Its read-only mirror is stored at:

```text
~/Library/Application Support/RetroCloudSync/Contacts.sqlite
```

Contact download errors do not stop the mail proxy; they are written to the
daemon log and retried at the next interval.

## Read-only CardDAV probe

Build the non-shipped PowerPC/Intel diagnostic tool with:

```sh
make carddav-probe
make test-shared
```

Copy `build/macOS-carddav-probe/release/RetroCloudCardDAVProbe` and
`build/macOS-app/release/RetroCloudSync.app/Contents/Resources/cacert.pem` to
a Mac under `~/Desktop`, then run:

```sh
./RetroCloudCardDAVProbe \
  --username "name@icloud.com" \
  --database "$HOME/Desktop/RetroCloudContacts.sqlite" \
  --ca "$HOME/Desktop/cacert.pem"
```

The password is read from an interactive prompt. The probe performs CardDAV
discovery and read-only contact downloads; it never sends `PUT` or `DELETE`.
Downloaded vCards are stored both as their original bodies and as normalized
contact, property, parameter, and structured-value rows.
