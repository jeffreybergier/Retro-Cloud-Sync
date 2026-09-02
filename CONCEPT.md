# Retro Cloud: Modern iCloud on Tiger and Leopard

Research notes from September 1, 2026.

This document collects the findings from investigating whether the technique used by iCloudMailFix can be extended to Mac OS X Tiger and later, and how Mail, contacts, and calendars could be connected to modern iCloud using an app-specific password.

## Executive summary

There are really two different compatibility problems:

1. **Mail on an old system already speaks IMAP and SMTP, but cannot negotiate the TLS required by modern iCloud.** A local TLS proxy is a good solution.
2. **Tiger's applications do not speak modern CalDAV or CardDAV.** TLS translation alone cannot add an application protocol that the programs do not implement. For Tiger, the clean solution is a custom Sync Services server client that talks to iCloud itself and exchanges canonical contact and calendar records with the system sync engine.

For Leopard, the situation is mixed: its iCal generation has CalDAV support, so a compatibility proxy might be sufficient for calendars after testing. Its Address Book generation does not provide the same usable native CardDAV path, so contacts still need a bridge. Snow Leopard is the first practical baseline where both native CalDAV and CardDAV clients are present.

The sibling `AltivecIntelligence` build system is a strong foundation for the bridge. It already supplies quad-fat Tiger-through-modern builds and the most important portable dependencies:

- libcurl 7.88.1
- OpenSSL 1.1.1w
- SQLite
- cJSON
- zlib
- a Mozilla CA certificate bundle

The recommended implementation is therefore:

```text
Tiger/Leopard Address Book and iCal
                |
         Apple Sync Services
                |
    Retro Cloud Sync Services client
                |
   CalDAV/CardDAV client and sync engine
                |
      libcurl + OpenSSL + CA bundle
                |
              iCloud
```

Mail can remain a separate, much simpler local transport proxy:

```text
Old Mail.app          Local daemon               Modern iCloud
IMAP/SMTP  <---->  plaintext/legacy side  <---->  validated TLS
```

## Authentication and current iCloud services

Third-party clients use the user's Apple Account address and an app-specific password. Apple currently requires two-factor authentication before an app-specific password can be created. Passwords can be generated and revoked from the Apple Account site. See [Apple's app-specific password documentation](https://support.apple.com/en-us/102654).

The service entry points relevant to this project are:

| Service | Entry point | Notes |
|---|---|---|
| IMAP | `imap.mail.me.com:993` | Implicit TLS |
| SMTP | `smtp.mail.me.com:587` | Submission with STARTTLS |
| CalDAV | `https://caldav.icloud.com` | Redirects to an account shard are normal |
| CardDAV | `https://contacts.icloud.com` | Redirects or shard hosts must be accepted carefully |

Credentials must never be logged. The remote TLS connection must verify both the certificate chain and the requested hostname against the packaged CA bundle. The local side should listen only on loopback and should not expose plaintext credentials or personal data to the LAN.

Service URLs and undocumented behavior can change. They should be isolated in configuration and covered by integration tests rather than scattered throughout the source.

## Mail on Tiger and later

### Why the existing technique transfers well

Old Mail.app versions already understand IMAP and SMTP. Their principal incompatibility with iCloud is the TLS layer and, potentially, their old trust store. That is the same class of problem solved by iCloudMailFix on iOS:

1. Mail connects to a local listener.
2. The daemon opens the real iCloud connection with modern OpenSSL.
3. The daemon validates the iCloud server certificate and hostname.
4. It relays bytes without interpreting or storing mail credentials or content.

The Mac version does not necessarily require an injected DNS hook. A manually configured mail account can point directly to `127.0.0.1` or `localhost`. If the old account editor insists on the real hostname, host redirection or a narrowly scoped hook can be considered later.

### Suggested listeners

The exact local ports are a product decision, but unprivileged high ports simplify installation and avoid collisions. Conceptually:

```text
127.0.0.1:<local-imap> -> imap.mail.me.com:993 using TLS
127.0.0.1:<local-smtp> -> smtp.mail.me.com:587 using STARTTLS
```

SMTP on port 587 is not simply an implicit-TLS socket. The proxy must implement enough of the SMTP conversation to issue or bridge STARTTLS correctly, as the existing project already does.

### What the proxy does not solve

A TLS proxy cannot repair application-level authentication assumptions, unsupported IMAP extensions, or a client that insists on an obsolete account-discovery workflow. These need testing on each target Mail.app version. Nevertheless, the core protocols are old and stable enough that this is substantially smaller than the contacts/calendar project.

## Native calendar and contact support by OS generation

This is the practical compatibility matrix established during the investigation. Exact point releases should still be verified on real systems or clean virtual machines.

| System | iCal / Calendar | Address Book / Contacts | Practical approach |
|---|---|---|---|
| Tiger 10.4 | iCal 2 supports publication/subscription but not a complete CalDAV account client | No CardDAV account client | Sync Services bridge for both |
| Leopard 10.5 | iCal 3 has CalDAV support | No comparable native CardDAV account support | Test calendar through a TLS/DAV compatibility path; bridge contacts |
| Snow Leopard 10.6+ | Native CalDAV | Native CardDAV | Try direct configuration first; add compatibility proxy only where modern TLS or iCloud behavior breaks it |

Tiger's ability to publish or subscribe to an `.ics` calendar over WebDAV is not equivalent to CalDAV synchronization. A subscription is normally read-only, and publishing a monolithic calendar file does not provide CalDAV collections, per-object ETags, reports, conflict handling, or efficient incremental changes.

## Why old iSync is not the right primary extension point

iSync plug-ins were primarily device adapters. They taught iSync how to communicate with a phone, PDA, or similar device and how to map that device's records.

iCloud is a remote server, not a locally attached device. Pretending that it is a phone could be made to work, but it would add unnecessary device lifecycle, UI, and pairing assumptions. It would also make unattended periodic synchronization awkward.

The underlying Sync Services framework is the better layer. Apple explicitly described a server client as a liaison for a remote server and identified iCal and Address Book as other clients of the same local sync engine. See Apple's archived [Sync Services overview](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SyncServices/Articles/SyncOverview.html).

An iSync-facing UI could potentially be added later, but it should control a Sync Services client rather than contain the synchronization implementation.

## How a Sync Services client works

Sync Services maintains one local sync engine and one aggregate "truth database" for each user. Address Book, iCal, device adapters, and network-service adapters are clients of that engine. Clients do not synchronize directly with one another.

Apple provides canonical schemas for Contacts and Calendars. A Retro Cloud client would register the entities and properties it supports, then perform ordered synchronization sessions.

At a high level, one session does this:

1. Register a stable client identifier and client-description property list.
2. Open an `ISyncSession`, or use `ISyncSessionDriver` and its delegate model.
3. Negotiate fast, slow, refresh, pull-truth, or push-truth behavior as appropriate.
4. Push additions, modifications, and deletions learned from iCloud into the sync engine.
5. Allow the engine to mingle those changes with changes from Address Book, iCal, and other clients.
6. Pull the resulting changes that must be applied to iCloud.
7. Upload them with conditional DAV requests.
8. Acknowledge successful records and finish the session.

Fast synchronization exchanges changes since the previous successful session. Slow synchronization compares complete datasets and is needed for first use, damaged state, changed schemas, or expired server synchronization tokens.

The truth database is field-oriented. It may merge changes to different fields of the same record, while concurrent changes to the same field can become a conflict. The client must not assume that changes are returned in their original order.

Apple warns that the session API is a finite-state machine whose call ordering is critical and that incorrect use can cause data loss. The implementation should therefore:

- use `ISyncSessionDriver` unless a lower-level session is genuinely needed;
- keep the network phase and Sync Services transaction boundaries explicit;
- acknowledge only remote writes that definitely succeeded;
- retain enough state to retry after interruption;
- test first with disposable Apple Accounts and local user accounts;
- include a read-only and one-way mode before enabling bidirectional deletion.

The primary references are Apple's archived [Sync Services overview](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SyncServices/Articles/SyncOverview.html), [client registration guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SyncServices/Articles/RegisteringClients.html), and [session management guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SyncServices/Articles/SessionManagement.html).

## CalDAV and CardDAV terminology

Several pieces are often all called a "client," but they are separate:

| Component | Responsibility |
|---|---|
| HTTP/TLS transport | Connect, authenticate, redirect, upload, and download |
| WebDAV core | DAV methods, properties, collections, `207 Multi-Status`, ETags |
| CalDAV/CardDAV adapter | Discovery and protocol-specific reports |
| iCalendar/vCard parser | Interpret `.ics` and `.vcf` resource bodies |
| Sync engine | Reconcile two stores, including deletions and conflicts |
| Sync Services bridge | Map DAV resources to Apple's canonical local records |

CalDAV stores and queries iCalendar resources through extensions to WebDAV. CardDAV does the corresponding job for vCard resources. The core standards are [CalDAV RFC 4791](https://www.rfc-editor.org/rfc/rfc4791), [CardDAV RFC 6352](https://www.rfc-editor.org/rfc/rfc6352), and the later [WebDAV collection synchronization RFC 6578](https://www.rfc-editor.org/rfc/rfc6578).

## Existing open-source C implementations

### libcaldav

`libcaldav` is a small C client library intended to implement CalDAV. The last SourceForge release, 0.6.2, appeared in 2010 and is marked beta. Trinity Desktop maintains a lightly patched version with build-system updates.

- [SourceForge libcaldav releases](https://sourceforge.net/projects/libcaldav/files/)
- [Trinity related-project description](https://www.trinitydesktop.org/relatedprojects.php)

Its age makes it useful as reference code and a source of request templates, but not something to trust against current iCloud without a source, security, interoperability, and license audit.

### libcarddav

Trinity's `libcarddav` is a portable C CardDAV client. Trinity describes complete list, get, add, modify, and delete operations with libcurl as its only build dependency. That makes it the most directly relevant existing code for the `AltivecIntelligence` environment.

It is also old and apparently lightly maintained. As with `libcaldav`, its exact source headers and licensing need to be inspected before code is copied or linked. The project-description page is not enough for a licensing decision.

### neon

[neon](https://notroj.github.io/neon/) is an actively maintained HTTP/1.1 and WebDAV C library. It provides:

- arbitrary HTTP methods and headers;
- Basic and Digest authentication;
- OpenSSL or GnuTLS support;
- XML parsing through libxml2 or Expat;
- WebDAV property, locking, and ACL helpers.

It is a credible implementation, but adopting it would duplicate libcurl and part of the existing OpenSSL integration. For this project, a small DAV layer over the already-built libcurl is probably less work than adding and porting neon.

### libical

[libical](https://github.com/libical/libical) is the established C implementation of iCalendar data and protocols. It is actively maintained and dual-licensed MPL 2.0/LGPL 2.1.

It parses and manipulates `.ics` data; it is not itself a CalDAV network client. A modern libical release may assume a newer CMake and compiler environment, so an older compatible release or a small Tiger portability patch set may be preferable. It should be tested on big-endian PowerPC as well as Intel.

### C vCard parsers

Old C parsers such as [libvc](https://manpages.ubuntu.com/manpages/jammy/man3/vc.3.html) and [ccard](https://ccard.sourceforge.net/) exist, but the ecosystem is much less healthy than libical. Many projects are abandoned, underspecified, or handle only a subset of vCard versions.

A small vCard 3.0 parser may be reasonable, but it must handle more than splitting lines at colons:

- folded lines;
- escaped separators and newlines;
- property groups and parameters;
- structured values such as `N` and `ADR`;
- repeated telephone, email, and address properties;
- UTF-8 and legacy quoted-printable input where encountered;
- binary or base64 photographs;
- Apple extension properties.

### SyncEvolution

[SyncEvolution](https://syncevolution.org/) is a complete synchronization framework with CalDAV and CardDAV backends. Its DAV backend historically used neon and tracked remote changes by ETag. It has also contained experimental iCloud compatibility work.

It is C++, comparatively large, and brings a substantial dependency and abstraction stack. Porting it wholesale to Tiger is unlikely to be the shortest route. Its source remains valuable for studying discovery, ETag tracking, record matching, slow synchronization, and recovery behavior. See the [backend documentation](https://syncevolution.org/documentation/backends/).

### Apple Calendar Server client library

Apple's `ccs-caldavclientlibrary` is a CalDAV protocol and testing stack written in Python, not C. It was archived in 2024. It can provide test ideas but is not a suitable runtime dependency for a small Tiger application. See [Apple's archived repository](https://github.com/apple/ccs-caldavclientlibrary).

## Build versus reuse decision

A complete generic implementation of every CalDAV, CardDAV, WebDAV, scheduling, sharing, recurrence, access-control, and discovery feature is not simple. An iCloud-specific client supporting the subset required for contacts and personal calendars is bounded and practical.

The recommended reuse boundary is:

- reuse libcurl and OpenSSL for network transport and TLS;
- reuse the packaged Mozilla CA bundle for trust;
- use libxml2 or a small SAX-style XML layer for DAV responses;
- evaluate a Tiger-buildable libical for `.ics` parsing;
- either audit an old C vCard library or implement a deliberately scoped vCard 3 parser;
- use SQLite for durable synchronization state;
- use `libcaldav`, `libcarddav`, and SyncEvolution primarily as references until they pass an audit.

libcurl supports DAV methods through `CURLOPT_CUSTOMREQUEST`; see the [libcurl documentation](https://curl.se/libcurl/c/CURLOPT_CUSTOMREQUEST.html). It does not implement DAV discovery, XML semantics, or synchronization policy for us.

## Minimal DAV operations required

An initial client needs only a focused subset.

### Discovery

1. Begin at `https://caldav.icloud.com` or `https://contacts.icloud.com`.
2. Send `PROPFIND` to obtain `current-user-principal`.
3. Query the principal for `calendar-home-set` or `addressbook-home-set`.
4. List the available calendar or address-book collections and their display names.
5. Retain the final shard host and canonical collection URLs.

### Reading

1. Request resource URLs and ETags with `PROPFIND`, `calendar-query`, or `addressbook-query`.
2. Compare those results with the local SQLite state.
3. Fetch changed bodies with a multiget `REPORT`, or individual `GET` requests as a fallback.
4. Treat missing previously known resources as deletions only after a complete, successful listing.

### Writing

- Create a resource with `PUT` and `If-None-Match: *`.
- Update it with `PUT` and `If-Match: <known-etag>`.
- Delete it with `DELETE` and `If-Match: <known-etag>`.
- On a precondition failure, fetch the new remote version and enter conflict resolution instead of overwriting it.

### Incremental synchronization

If iCloud advertises WebDAV `sync-collection`, store its opaque sync token and request only subsequent changes. If the token expires or is rejected, fall back to a full ETag inventory. ETags remain necessary for conditional writes even when sync tokens are available.

## Known iCloud interoperability concerns

Testing against current iCloud matters more than nominal RFC coverage. Current open-source compatibility testing reports behaviors worth designing around:

- CalDAV entry requests can redirect to hosts such as `pXX-caldav.icloud.com:443`.
- A redirect handler must preserve `PROPFIND` and `REPORT`; generic redirect behavior can incorrectly retry the request as `GET`.
- Relative `href` values must be resolved against the correct response URL.
- Calendar queries should begin conservatively; complicated property filters may be rejected even when simpler multiget requests work.
- Imported events cannot be assumed to have a resource filename derived from their UID.
- ETags must be treated as authoritative for updates.

One useful contemporary set of empirical notes is the [iCloud CalDAV compatibility document](https://github.com/ThomasCrouzet/icloud-mcp/blob/main/docs/caldav-compatibility.md). Because this describes observed rather than guaranteed behavior, the client should log protocol metadata safely and make workarounds testable and replaceable.

## Data preservation and mapping

Old Address Book and iCal schemas cannot represent every field modern iCloud may store. A destructive round trip is the largest data-integrity risk.

For each remote resource, SQLite should retain at least:

```text
account identifier
collection identifier and URL
remote resource href
remote UID
last successful ETag
last raw .ics or .vcf body
Sync Services record identifier
last local and remote revision markers
tombstone/deletion state
pending operation and retry state
```

The raw remote body should be preserved. When uploading an edit made by an old application, modify only fields that were actually changed and retain unknown properties, parameters, time-zone components, recurrence exceptions, alarms, photos, and `X-APPLE-*` extensions wherever possible.

Calendars require special care around recurring events, detached recurrence instances, floating times, time zones, all-day values, attendee state, and alarms. Contacts require stable handling of labeled multivalue fields, groups, images, birthdays, phonetic names, and Apple-specific labels.

## Proposed component structure

```text
RetroCloud/
  Transport/
    RCHTTPClient             libcurl wrapper
    RCTLSConfiguration       CA bundle, verification, TLS policy
    RCURL                    redirect and href resolution

  DAV/
    RCDAVClient              generic request/response layer
    RCMultiStatusParser      namespace-aware 207 XML parser
    RCDAVDiscovery           principal and home-set discovery
    RCDAVSyncCollection      sync-token and ETag inventory

  Calendar/
    RCCalDAVClient           calendar-query and calendar-multiget
    RCICalendarCodec         libical adapter or scoped parser
    RCCalendarMapper         iCalendar <-> Sync Services records

  Contacts/
    RCCardDAVClient          addressbook-query and addressbook-multiget
    RCVCardCodec             loss-preserving vCard parser/writer
    RCContactMapper          vCard <-> Sync Services records

  Sync/
    RCSyncCoordinator        session state machine
    RCSyncServicesDriver     ISyncSessionDriver integration
    RCConflictResolver       explicit merge policy
    RCStateStore             SQLite state and transactions

  MailProxy/
    RCIMAPProxy
    RCSMTPProxy
```

The names are illustrative. Shared DAV code should be plain C where that improves portability and testing. The Sync Services boundary will naturally be Objective-C using manual reference counting and APIs available on Tiger.

## Recommended development sequence

### Phase 1: protocol probe

Build a command-line Tiger-compatible tool that:

- accepts credentials without printing them;
- authenticates with an app-specific password;
- discovers calendar and address-book collections;
- lists resource URLs and ETags;
- downloads raw `.ics` and `.vcf` resources;
- performs no writes.

This validates libcurl, OpenSSL, CA loading, redirects, HTTP methods, authentication, XML parsing, and big-endian correctness before Sync Services is involved.

### Phase 2: durable read-only mirror

- Add the SQLite state database.
- Add multiget and optional sync-token support.
- Parse enough calendar and contact data to produce diagnostic summaries.
- Retain raw resources and detect additions, modifications, and deletions.

### Phase 3: one-way Sync Services import

- Register narrowly declared Contacts and Calendars capabilities.
- Import remote records into the truth database.
- Do not upload or propagate local deletions yet.
- Test interruption, duplicate matching, repeated runs, and slow sync.

### Phase 4: safe creation and updates

- Pull local additions and modifications.
- Upload with conditional `PUT` requests.
- Re-fetch and store server-selected hrefs and ETags.
- Preserve unrecognized remote properties.

### Phase 5: deletion and conflict handling

- Introduce tombstones and conditional `DELETE`.
- Require explicit policy for simultaneous edits and deletes.
- Add recovery from expired sync tokens and partial sessions.
- Provide backups/export and a dry-run diagnostic mode.

### Phase 6: daemon and user interface

- Schedule periodic synchronization through `launchd`.
- Store credentials in the Keychain when the old API permits it.
- Add status, last-sync time, errors, read-only mode, and per-collection selection.
- Keep protocol logging free of credentials and private record bodies.

## Testing priorities

The highest-risk tests are:

- PowerPC big-endian parsing and SQLite behavior;
- Tiger and Leopard framework/API availability;
- TLS hostname and chain validation with the packaged CA bundle;
- redirects that preserve custom DAV methods and bodies;
- XML namespaces and mixed successful/failed properties in a `207` response;
- UTF-8, folded lines, escaped values, photos, and Apple extensions;
- recurring events and time-zone round trips;
- create/update/delete precondition failures;
- process termination between remote write and local acknowledgement;
- full resynchronization without duplicates or unintended deletion;
- changes made concurrently on a modern Apple device and the old Mac.

A local standards-friendly test server can exercise generic DAV behavior, but final integration tests must use disposable iCloud data because iCloud-specific behavior is the actual target.

## Conclusions

- The mail-fix technique applies directly to Mac OS X because the missing functionality is principally modern TLS around protocols Mail.app already understands.
- A TLS proxy alone cannot give Tiger iCal and Address Book CalDAV/CardDAV support.
- Leopard may be able to use its native CalDAV client through a compatibility layer, but contacts still need a bridge.
- An iSync device plug-in is technically possible but architecturally indirect.
- A Sync Services server client is the intended Tiger-era mechanism for bringing a remote contacts/calendar service into Address Book and iCal.
- Existing C CalDAV/CardDAV libraries are useful but old. They should be audited and mined for ideas rather than accepted blindly.
- The existing libcurl, OpenSSL, SQLite, CA bundle, and quad-fat build infrastructure in `AltivecIntelligence` make a focused iCloud DAV implementation realistic.
- DAV transport is not enormous; reliable two-way synchronization and lossless data mapping are the hard parts.
- The safest path is read-only discovery, then a durable mirror, one-way Sync Services import, conditional updates, and deletions last.

