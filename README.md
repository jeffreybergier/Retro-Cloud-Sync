# Retro-Cloud-Sync

Legacy Mac OS X mail proxy and contacts/calendar synchronization, with a jailbroken iOS mail proxy and contacts/calendar daemon.

The app and daemon are quad-fat binaries: PPC and i386 use the 10.5 SDK
(minimum OS 10.4); x86_64 and arm64 use the 11.3 SDK (minimum OS 10.9
and 11.0 respectively). This follows ENIL's Altivec Intelligence arrangement,
including LLVM's x86_64 linker so Tiger selects the legacy Intel slice.

Contacts and Calendars use Sync Services through OS X 10.8. From 10.9 onward,
they use AddressBook.framework and EventKit.framework. The new frameworks are
absent from the PPC/i386 slices. Grant Contacts and Calendars access when macOS
asks. The daemon requests access for enabled services at startup, before any
DAV downloads; a pending Calendar approval resumes the same poll. Denial skips
only the affected service. System iCloud sign-in is unnecessary; DAV credentials
remain in Keychain.
The mail proxy continues independently.

The daemon selects a publication backend through `RCSyncBackend.h`.
`RCMacSyncBackend.m` preserves the Mac version/slice selection policy;
`RCSyncServicesBackend.m` owns legacy sessions and conflict resolution, while
`RCMacNativeBackend.m` and `RCMacNativeStore.m` own Mac AddressBook access.
`RCIOSNativeBackend.m` and `RCIOSNativeStore.m` provide the third backend using
iOS AddressBook's C API. The worker uses one access/publication interface.
`RCNativeSystemStore.m` shares durable ownership, receipts, recovery and EventKit
mapping between the two native backends, with narrow platform differences.

Forward graphs (`RCContactGraph.m`, `RCCalendarGraph.m`), reverse mapping,
write journals and verified-receipt completion are shared. Their historical
record keys and persisted schemas remain unchanged. `RCNativeExchange.m` uses
the `RCNativeStore` protocol and an injected, retained store factory, without
SyncServices linkage or a CPU-width gate. `RCPlatformDate` uses NSCalendarDate on
Mac and a keyed NSDate subclass on iOS, preserving timezone and floating-time
markers in the journal. Calendar-operation verification uses libxml2 on both.

The native backend owns an account-specific Contacts group and local calendars.
One-way mode imports the retained server mirror. Two-way mode detects edits and
new records in those managed containers, then uses the existing conditional DAV
write journal. Add new contacts to the account's rCloud group to upload them.
Unrelated local contacts and calendars are excluded.

Native calendar publication supports ordinary events, display alarms and sound
alarms with relative or absolute triggers. On Mac, sounds use the matching installed
system sound, or Basso (another installed sound if Basso is unavailable). Missing
or custom attachments are retained unchanged for uploads; fallback selection
does not change the cloud alarm. Explicit local sound changes can upload.
One-way mode also imports basic recurrence rules. Recurring masters with `EXDATE`
import without exclusions locally, so excluded occurrences appear in the native calendar on both Mac and iOS.
The full original exclusions remain in the retained cloud data. Two-way recurring series stay
pending because EventKit cannot supply their complete exception set; the backend
must not upload or delete a series based only on its master event. Invitations
import as ordinary local events without attendees or organizers. Their complete
participant data stays in the durable publication base and is preserved in
uploads of supported local edits. EventKit cannot edit participants or RSVP;
deleting a local invitation remains pending rather than deleting it from iCloud.
Detached occurrences, non-recurring exception structures, non-Monday recurrence week starts, and mail/repeating alarms remain
cached for attention if they cannot be represented safely. Pending writes and
conflicts preserve local edits; the native backend does not invoke the obsolete
Sync Services conflict UI. Native calendar renames/moves require attention;
retired calendar containers are retained. New local events are discovered from
1970 through 2101 (existing mapped events use direct identity lookups). Interrupted ambiguous native saves stop replay to
avoid duplicates. Use the recovery inspection/export commands before recovery.
Pending calendar saves recover only when an existing event in the managed
calendar uniquely matches the intended native fields. The old Mavericks all-day
alarm failure can also recover its missing identifier and duplicate default
alarm this way. Missing, edited, already owned, or multiple matches remain pending; recovery
never creates a replacement event.
Verified legacy all-day snapshots with misidentified display reminders are
repaired without changing the event or its original calendar data. Automatic
native reminders remain outside outgoing iCloud data when unchanged. Mavericks
may materialize another default on an all-day recurring series after publication;
exactly one verified extra Basso reminder is omitted from readback without
changing the native alarms or the original calendar data.
Alarm readback matches unchanged alarms independently of their order. Duplicate
local projections and ambiguous simultaneous alarm edits are deferred rather
than guessing which alarm owns retained attachment data.


## Jailbroken iOS daemon

`make ios-package` builds `build/iOS/rCloud-rootful.deb` using the iOS 8.4 SDK:
armv7 targets iOS 5.0 and arm64 targets iOS 7.0. Native integration has been tested
on `koolphone5` running iOS 8.4.1; iOS 5 and arm64 device execution remain untested.
This package supports rootful installation. It imports contacts and calendars;
the mail proxy can be enabled independently in the iOS app.

Install with `dpkg -i rCloud-rootful.deb`. Registration via `uicache` is required:
launchd runs `/Applications/rCloud.app/rCloud --daemon` as **mobile**, preserving
the registered bundle's identity. A standalone unregistered executable was
denied access on iOS 8. The registered daemon successfully requested the normal
Contacts/Calendar prompts, and a fresh launch opened both stores after user
approval. No TCC database changes or privacy-bypass entitlements are used.
iOS 5 uses the older AddressBook initializer and Calendar APIs; iOS 6+ privacy
APIs are weak-linked/runtime-guarded. Permission denial stops the affected
service, never exposing an empty store to deletion logic.

Open **rCloud → Sync** to enter your Apple Account and app-specific
password. Choose the Contacts and Calendars modes, interval, and history, then
tap **Save**. A blank password keeps the existing Keychain password for that
account. New GUI setups start with both services disabled; two-way sync is an
explicit choice. Set both services to Disabled to stop syncing. Use Save to apply changes. Saving safely stops the current daemon; launchd restarts it promptly with the
new configuration. First setup triggers launchd through a configuration-file watch.
A five-second throttle prevents rapid restart loops; active work must finish
stopping safely before the replacement daemon starts. Passwords never enter
the configuration or log. The status and log screens have Refresh buttons.
All screens use standard UIKit table controllers and navigation, with the Mac
pane order and labels: Status, Mail, Sync, Log. Portrait launch
images cover the original iPhone, iPhone 5, iPhone 6/6 Plus, and iPad, including
`Default-568h@2x.png` to avoid the iPhone 4 compatibility viewport.

Open **rCloud → Mail**, enable the proxy, and tap **Save** to use Mail
through localhost. Existing installations leave the proxy disabled until enabled.
A mail-only setup does not require a Contacts/Calendar account or credentials in
rCloud. It preserves any existing sync configuration.

In the iPhone's manually configured Mail account, use **127.0.0.1**, incoming
port **1143**, outgoing port **1587**, and **SSL off** for both local connections.
Use Password authentication and enter your iCloud mail credentials/app-specific
password in Mail itself. The proxy listens only on IPv4 loopback and verifies
upstream TLS certificates and hostnames: IMAP TLS to `imap.mail.me.com:993`,
SMTP STARTTLS to `smtp.mail.me.com:587`. Local and upstream ports/hosts can be
changed in the standard table-based Mail screen. Port conflicts or TLS
failures appear in the daemon log. Mail account migration is manual; installation
does not change Mail accounts or remove another proxy/tweak.

Command-line setup remains available via `/usr/share/rcloud/Config.example.plist`
and `rCloud --set-password USERNAME` as mobile, with the password supplied on
stdin. The GUI and daemon share `/var/mobile/Library/Application Support/rCloud/Config.plist`.

Both services default to `OneWay` in the example; each independently accepts
`Disabled`, `OneWay`, or explicit `TwoWay`. No account is configured during
installation, and no DAV requests occur until setup. The daemon keeps mirrors,
write journals and `Status.plist` beside `Config.plist`; logs are in
`/var/mobile/Library/Logs/RetroCloudSync`. Package hooks send SIGTERM and wait for journal-safe shutdown before unloading.
Removal preserves account data and
Keychain credentials. `--access`, `--request-access`, `--inspect-recovery` and
`--export-recovery` are available on the installed executable.

The iOS importer uses an account-owned group in the existing local Contacts
source and owned calendars in EventKit's local source. It fails clearly if a
local source is unavailable. iOS exposes alarm timing but no public sound/action
setter: audio alarms use the device's normal reminder, while the original audio
action and attachment remain in the wire base. Timing edits preserve those
bytes. Contact primary-value preferences are retained in the wire base because
iOS has no matching public setter. The recurring-series, invitation and
ambiguous-save restrictions described above apply on iOS too.

To run offline device checks, first unload the installed daemon (even if idle):

```sh
# On the test iPhone as root:
launchctl unload /Library/LaunchDaemons/com.altivecintelligence.rcloudd.plist
# In the build container:
make test-ios-native-stores TEST_HOST=koolphone5
make analyze-ios
```

The runner requires an installed, authorized rCloud app. It temporarily replaces
its executable with the test build, runs synthetic fixtures via mobile launchd,
then restores the installed binary. It refuses a loaded production job and
retains logs/journals under the phone's Caches directory and `build/tests/iOS`.
After testing, reload the installed launchd plist to resume the daemon. These
offline tests exercise synthetic Keychain credentials, import, edits, exact acknowledgement, replay, recovery,
recurrence/exclusion and invitation guards; they do not validate live iCloud.

Build inside Altivec Intelligence with both SDK volumes installed:

```sh
podman compose run --rm altivec "make release"
```

Modern slices are signed with `rcodesign` before universal assembly. Compose
mounts `~/.local/share/retro-cloud-sync/signing` read-only; place a persistent
certificate/private key PEM in `development.pem`, or override
`RCLOUD_SIGNING_DIR` / the Make variable `RCLOUD_SIGNING_PEM`. Keep private keys
outside the repository. Without a PEM, builds use ad-hoc signatures and privacy
grants may need renewal after rebuilds. A local self-signed identity gives stable
designated requirements; it is not Developer ID distribution or notarization.
The native test app uses the same persistent identity and requests Calendar
permission once while a request is pending.

Run tests from the Linux build container:

```sh
make test-business-linux
make test-mac-native-stores TEST_HOST=x9-local
make test-business-mac TEST_HOST=x4-vm
make test-ui-mac TEST_HOST=x4-vm
```

`make test` runs the Linux suite. See [test documentation](source/tests/README.md)
for dependencies, suite membership, narrower targets and Mac desktop requirements.

GitHub Actions runs `make test-business-linux` once per branch push. A `vMAJOR.MINOR.PATCH`
tag builds the macOS app ZIP and attaches `Retro-Cloud-Sync-VERSION-macOS.zip`
to its GitHub Release after checking that the tag and app version match. The
release workflow needs three repository secrets containing HTTPS URLs for the
checksum-verified SDK archives: `ALTIVEC_SDK_MACOS_105_URL`,
`ALTIVEC_SDK_MACOS_113_URL`, and `ALTIVEC_SDK_IPHONEOS_84_URL`.
