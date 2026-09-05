# Retro-Cloud-Sync
Sync iCloud Email, Contacts, Calendars with Retro Macs 10.4+

## Contacts and Calendars preferences

Open the application and choose **Sync** in the toolbar. Enter the Apple ID
used for iCloud, an app-specific password, select a sync mode for Contacts and
Calendars, and choose the desired sync interval. The password is stored in the user's
login Keychain and is never written to the configuration file or LaunchAgent.
Saving or removing an account restarts an already-running background service
so the new settings take effect.

Contacts and Calendars each support a one-way iCloud mirror and Sync Services
import. Either can run independently; a failure in one does not skip the other.
The configuration stores `ContactsSyncMode` and `CalendarsSyncMode` as
`Disabled`, `OneWay`, or `TwoWay`. Legacy `Enabled` and `CalendarsEnabled`
booleans remain in the plist for compatibility. Two-way synchronization is not implemented. Unsupported modes are logged
and are never treated as one-way sync by the daemon.

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

## Calendar database and iCal import

With Calendars set to **1-way**, the daemon downloads calendars immediately and
at the shared sync interval. The database is:

```text
~/Library/Application Support/RetroCloudSync/Calendar.sqlite
```

`calendars` and `events` contain readable fields. `calendar_resources` retains
original `.ics` bytes and the last successfully exported body. Ordered
`ical_components`, `ical_properties`, and `ical_parameters` retain additional
properties. SQL views expose available events, recurrence, participants, alarms,
and time zones. Newly created files use a format readable by Tiger's `sqlite3`:

```sql
SELECT calendar_name, summary, start_value, start_kind, start_tzid,
       end_value, recurrence_id, export_status
FROM available_events;
```

Dates retain their original date-only, UTC, zoned, or floating meaning. The view
contains recurring masters and overrides, not expanded occurrences. Raw bytes
are retained even when parsing fails; `parse_error` identifies stale normalized
rows. A failed/incomplete DAV run rolls back instead of treating absent rows as
remote deletions. Each account has separate state and Sync Services identity.
Changing accounts preserves the previous account's cached/local calendars.

The Tiger mapper supports ordinary and all-day events, daily/weekly/monthly/
yearly recurrence within Apple's schema, exclusions, moved/cancelled instances,
participants, and display/audio alarms. Floating timed events, unsupported
recurrence forms (including RDATE, subdaily rules and ranged exceptions), and
recurring zones that differ from Tiger's rules remain in SQLite with an export
explanation. A previously exported series is retained if its replacement cannot
be represented. Tasks, unknown extensions, and unsupported alarm actions are
stored but not exported. Calendar color is stored but is not a Tiger schema field.

iCal creates ordinary local calendars with a stable short suffix in their names
to distinguish equal remote calendar names. Local edits are never uploaded to
iCloud and may be replaced by a later import. The daemon checks completion of
Sync Services' merge phase before recording a successful export. System sync
confirmation dialogs, when required, must be available in the logged-in desktop
session; the app's per-user LaunchAgent runs there.

Build the non-shipped CalDAV probe and offline tests with:

```sh
make caldav-probe
make test-calendar
make test-calendar-build
make test-calendar-syncservices TEST_HOST=x4-vm
```

The probe is `build/macOS-caldav-probe/release/RetroCloudCalDAVProbe` and accepts
the same arguments as the CardDAV probe below, defaulting to
`https://caldav.icloud.com`. It prompts for the app-specific password and performs
no remote writes or Sync Services import.

Calendar integration tests run synthetic data through the real Tiger framework
and verify iCal using AppleScript. They use a separate test client, preserve a
baseline of existing calendar/event identifiers, exercise repeated imports,
updates/deletion and malformed/unsupported replacements, and clean up their
records. The remote runner opens a Terminal session because an SSH bootstrap
session cannot reliably reach Tiger's Sync Services confirmation UI. With native
Accessibility enabled, the harness confirms only dialogs naming its separate
"Retro Cloud Calendar Tests" client. All remote
artifacts remain under `~/Desktop`. Stop the production daemon before testing.

The build fetches checksum-pinned libical 3.0.20 and needs CMake, Perl, Python 3,
and curl on the Linux host. It builds only the C library for PPC/i386 and native
tests. The source archive and the reproducible GCC 4.2 diagnostic-only patches
are included with the application under `Contents/Resources/libical-source`,
alongside the MPL 2.0 license. See [CALENDAR_DESIGN.md](CALENDAR_DESIGN.md) for the
original proposal and deferred work.

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

## Offline Sync Services test

Build the non-shipped test tools and synthetic contact databases with:

```sh
make test-syncservices-build
make test-syncservices-analyze
```

Run the end-to-end test on a Tiger host with:

```sh
make test-syncservices TEST_HOST=x4-vm
```

The test refuses to run while the production daemon is active. It uses the
separate Sync Services client identifier
`com.retrocloudsync.contacts.test.v1` and never reads the login Keychain,
loads the service configuration, initializes the network stack, or contacts
iCloud. It records the existing Address Book identifiers, adds two uniquely
named synthetic contacts, verifies an idempotent re-export, updates one,
deletes the other, removes all test contacts, and confirms that every
pre-existing Address Book record remains. Cleanup is attempted after failures,
and all remote tools and artifacts remain under `~/Desktop`.
