# Retro-Cloud-Sync
Sync iCloud Email, Contacts, Calendars with Retro Macs 10.4+

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
