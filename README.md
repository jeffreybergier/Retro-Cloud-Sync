# Retro-Cloud-Sync
Sync iCloud Email, Contacts, Calendars with Retro Macs 10.4+

## Contacts and Calendars preferences

Open the application and choose **Sync** in the toolbar. Enter the Apple ID
used for iCloud, an app-specific password, select Contacts and/or Calendars,
and choose the desired sync interval. The password is stored in the user's
login Keychain and is never written to the configuration file or LaunchAgent.
Saving or removing an account restarts an already-running background service
so the new settings take effect.

The Calendars selection is saved with the account settings for the calendar
sync engine; the current daemon build only performs the Contacts mirror.

When enabled, the daemon downloads contacts immediately after it starts and
then at the configured interval. Its read-only mirror is stored at:

```text
~/Library/Application Support/RetroCloudSync/Contacts.sqlite
```

Contact download errors do not stop the mail proxy; they are written to the
daemon log and retried at the next interval. Choose **Log** in the application
toolbar to follow that log. It is stored at:

```text
~/Library/Logs/RetroCloudSync/RetroCloudSyncDaemon.log
```

After a successful CardDAV download, the daemon submits the available contacts
to Tiger's Sync Services Contacts schema. This is a one-way, push-only bridge:
it does not upload Address Book edits to iCloud or treat existing local Address
Book cards as CardDAV records. Tiger's Address Book application identifier is
`com.apple.AddressBook`; the separate Sync Services data class is named
`com.apple.Contacts`.

The contact database schema is upgraded automatically to add stable Sync
Services identifiers for contacts and their child properties. Re-enter and
save the app-specific password after installing a newly built application so
the replacement daemon is authorized by the login Keychain.

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
