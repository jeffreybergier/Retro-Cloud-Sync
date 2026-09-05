Implementation note (September 5, 2026): the one-way mirror, readable SQLite
store, CalDAV probe, daemon integration, and Tiger SyncServices mapper are now
implemented. See README.md for the supported mapping and test commands. The
text below preserves the original proposal. Native testing showed that iCal
converts imported calendars to writable local calendars, so the implementation
publishes that state and enforces one-way behavior in the bridge. It uses full
ETag inventories; multiget, sync tokens, and bidirectional writes remain deferred.
Validation passed for a clean universal release build, static analysis, portable
codec/store and DAV failure tests, and the synthetic SyncServices/iCal integration
suite on PowerPC Mac OS X 10.4.11. Authenticated iCloud testing is still pending.

Calendar mirror and SyncServices proposal — September 5, 2026

Implement the existing contacts flow for calendars: download from iCloud into
`~/Library/Application Support/RetroCloudSync/Calendar.sqlite`, retain the
original calendar data alongside ordinary SQL tables, and publish a supported
projection to iCal through Tiger's SyncServices API. Start with the same
one-way behavior as Contacts. Calendar writes to iCloud are a later phase.

This is a design proposal, not an implemented calendar engine. It builds on
[CONCEPT.md](CONCEPT.md), the current source, Apple's documentation, and the
DAV/iCalendar standards. No authenticated iCloud calendar requests or native
iCal tests were performed during this investigation.

The current implementation provides these reusable pieces:

| Existing code | Finding and implication |
| --- | --- |
| [RCHTTPClient.c](source/shared/RCHTTPClient.c) | curl transport, CA verification, HTTPS destination restrictions, relative URL resolution, ETags, response limits, and redirects that retain the requested method/body. Reuse for CalDAV. Its Accept header and some errors still mention CardDAV. |
| [RCCardDAVMirror.c](source/shared/RCCardDAVMirror.c) | Discovers principal, home, and collections; obtains a complete ETag inventory with PROPFIND; GETs changed resources. XML helpers are private to this file. There is currently no multiget or sync-token implementation. |
| [RCContactStore.c](source/shared/RCContactStore.c) | Schema version 2 stores original vCards, readable contact/property/parameter/value rows, persistent SyncServices IDs, run history, and remote-missing markers. Resource replacement is transactional; missing resources are marked after successful collection processing. |
| [RCSyncServicesBridge.m](source/macOS-daemon/RCSyncServicesBridge.m) | Reparses stored vCards into record dictionaries and requests a complete push on each export. Child records have persistent IDs. SyncServices does not directly read Contacts.sqlite. |
| [SyncClient.plist](source/macOS-app/Resources/SyncClient.plist) | Registers a server client and push-only Contacts entities. Calendar registration should have its own description and client identity. |
| [main.m](source/macOS-daemon/main.m) | A contact worker retrieves Keychain credentials, mirrors contacts, then exports after success. Calendar modes currently only produce log messages, and disabling Contacts returns before starting a worker. |
| [RCConfiguration.m](source/macOS-app/RCConfiguration.m) | Calendar modes and the shared interval already exist under the historical Contacts configuration dictionary. ServiceURL is currently fixed to the contacts endpoint. |

CONCEPT.md already recommends the right overall architecture. Its proposed
shared DAV layer, libical adapter, and calendar mapper are still future work.
The existing mirror also does not reconcile disappearing collections at the
home level; the calendar implementation should explicitly handle that case.

The critical model difference is that a CalDAV resource is a recurrence set,
not necessarily one event. A master and its overrides share a UID and resource;
different UIDs occupy separate resources within a collection. Resources can
also contain time-zone definitions, and a set can contain overrides without a
master. Therefore separate resource identity from component identity.
[CalDAV RFC 4791, section 4.1](https://www.rfc-editor.org/rfc/rfc4791#section-4.1)

Use this flow:

```text
iCloud CalDAV
    |
    | existing HTTP transport + shared DAV helpers
    v
Calendar.sqlite
    | original .ics bodies
    | readable calendar/event/component tables
    | persistent record identities and publication state
    v
RCCalendarSyncServicesBridge
    | Tiger-compatible record dictionaries
    v
SyncServices -> iCal
```

I propose the following database structure. Names and columns below describe
the intended schema; the migration SQL should be finalized with the codec.

| Tables | Main columns and purpose |
| --- | --- |
| `schema_version`, `accounts` | Database version; durable account ID, username, discovered principal/home URLs. Keep credentials in Keychain. |
| `sync_runs`, `collection_runs` | Attempt status, timestamps, inventory completeness, download/parse failures, candidate tokens, committed generations. Distinguish remote fetch success from local publication success. |
| `calendars` | Account ID, collection URL, display name, description, color, advertised components/reports, access state, sync token, persistent sync ID, remote-missing status. |
| `calendar_resources` | Calendar ID, href, UID, component type, current revision ID, seen generation, remote-missing status. Unique on calendar plus href. |
| `resource_revisions` | Resource ID, fetched ETag, original `.ics` BLOB, download time, parse status/error. Retain the current downloaded revision and any older revision still needed by the exported projection. |
| `ical_components` | Revision ID, parent component ID, component kind, position, UID, recurrence identity. Represents VCALENDAR, VEVENT, VALARM, VTIMEZONE, STANDARD/DAYLIGHT, and other received components. |
| `ical_properties`, `ical_parameters`, `ical_value_parts` | Ordered original and decoded values, parameter values, and structured/list parts. Preserve unfamiliar fields and repeated properties as inspectable rows. |
| `events` | Component/resource/calendar references, stable event ID, UID, recurrence key, master ID, summary, description, location, URL, status, classification, priority, sequence, and typed start/end/duration fields. |
| `recurrence_rules`, `recurrence_rule_parts`, `recurrence_dates` | Original rule text plus decoded frequency/count/interval/until and ordered BY* parts; typed RDATE/EXDATE values, including periods where present. |
| `attendees`, `organizers`, `alarms` | Readable participation and alarm data linked to the owning event; preserve original calendar addresses and trigger semantics. |
| `timezones`, `timezone_observances` | Resource-scoped TZIDs and STANDARD/DAYLIGHT definitions. A matching TZID string in another resource is not sufficient to deduplicate definitions. |
| `sync_record_ids`, `sync_exports` | Persistent IDs for mapped objects; last successful/pending projection generation, mapper version, export status, and reasons for unsupported mappings. |

Keep commonly read data in ordinary columns. Generic property tables preserve
detail but should not be the only way to find an event's title or start time.
Provide an `available_events` view joining the current parsed events to calendar
names, with original time values, interpretation, recurrence identity, and
export status visible. For example:

```sql
SELECT calendar_name, summary, start_value, start_kind, start_tzid,
       end_value, recurrence_id, recurrence_rule, export_status
FROM available_events
ORDER BY calendar_name, start_value;
```

This example orders stored wall-clock/date strings for inspection; it is not a
chronological agenda across time zones. It shows masters and overrides, not an
infinite expansion of recurring occurrences. If an agenda becomes useful,
derive a separately labeled, bounded occurrence cache from these records.

Raw bodies remain byte-preserved. A parser's reserialization is not an exact
copy of the download. If parsing fails, keep the new body and error without
silently replacing the last usable event graph. Unsupported but parseable
components remain visible in the generic SQL tables.

For identity, use account + calendar + UID to locate a series, then a typed
RECURRENCE-ID to locate an override. Store a non-null master sentinel in the
normalized recurrence key so SQLite's NULL uniqueness behavior cannot admit
duplicate masters. Include date/floating/zoned semantics in that key and retain
the original value. A moved occurrence keeps the identity of its original
slot, even when its DTSTART changes. Persistent generated IDs should survive
property reordering, reparsing, ETag changes, and unambiguous href renames within
the same calendar. Duplicate UIDs or ambiguous moves need diagnostics rather
than guessed merges. Do not merge equal UIDs across calendars or accounts.

Match child records using persisted ownership and semantic identity, with
deterministic disambiguation for repeated alarms/attendees. Neither array
position nor an ETag is a stable SyncServices identifier. Preserve IDs for
tombstoned records until publication and recovery no longer need them.

For network access, reuse the Keychain username/password and packaged CA bundle.
Apple documents app-specific passwords for third-party access to iCloud
calendars. [Apple authentication documentation](https://support.apple.com/en-us/102654)

Start from the calendar endpoint recorded in CONCEPT.md,
`https://caldav.icloud.com`, with discovery determining the actual account URLs.
Treat current shard behavior and extension support as integration-test findings,
not guarantees established by this investigation.

The proposed first fetch implementation is:

1. Discover the principal and calendar-home-set, then list real calendar
   collections and their metadata. Keep unsupported collection types out of
   the event export. Preserve available color/access metadata even if Tiger
   cannot publish it.
2. Obtain a complete Depth:1 href/ETag inventory for each selected calendar.
   Compare against durable state and GET changed bodies. This directly follows
   the existing contact strategy. Do not limit the authoritative inventory to a
   rolling date window.
3. Add bounded calendar-multiget batches to reduce request overhead, requesting
   complete calendar data without recurrence expansion or property filtering.
   Check individual response and property statuses; an outer 207 alone is not
   proof that every item succeeded.
4. Commit downloaded revisions and usable projections with explicit generation
   state. A partial response, failed GET, or permission error must not authorize
   deletion. Confirm resource disappearance from a successful complete inventory;
   separately reconcile missing calendars after successful home discovery.
5. Add sync-collection once advertised and tested. Advance a token only with the
   durable processing of its complete result, including any continuation pages.
   Invalid tokens cause a fresh inventory, not a database wipe.

Calendar discovery and multiget are defined by
[RFC 4791](https://www.rfc-editor.org/rfc/rfc4791); token synchronization and
truncated results are defined by
[RFC 6578](https://www.rfc-editor.org/rfc/rfc6578). A standards-based discovery
fallback can use `/.well-known/caldav` as described in
[RFC 6764](https://www.rfc-editor.org/rfc/rfc6764). Multiget and tokens are
optimizations, not prerequisites for the first correct mirror.

The codec should wrap a pinned, audited libical build. The upstream project
provides iCalendar parsing and manipulation, not our DAV mirror.
[libical upstream](https://github.com/libical/libical)
The inspected 3.0.20 build configuration has switches for static libraries and
disabling C++/GLib bindings, making that release a useful portability probe,
not a final version selection. Test supported/patched releases against the
actual PPC/i386 toolchain before choosing one. Build only the needed C portion,
disable accidental host dependency detection, and validate timezone handling.
[libical 3.0.20 build configuration](https://raw.githubusercontent.com/libical/libical/v3.0.20/CMakeLists.txt)

Store DATE, UTC DATE-TIME, TZID-based DATE-TIME, and floating DATE-TIME distinctly.
DTEND is exclusive; retain DURATION and whether the end was explicit or inferred.
Preserve recurrence rules, exclusions, additions, and RECURRENCE-ID independently.
These are semantic distinctions in
[iCalendar RFC 5545](https://www.rfc-editor.org/rfc/rfc5545), not formatting choices.
Keep readable ISO dates and local times plus their type/TZID, with a nullable
64-bit derived UTC value where resolution is valid. Do not make 32-bit time_t
the authoritative representation, or attach the Mac's current timezone to a
floating value in storage. Test beyond 2038 and pre-1970. Embedded timezone
definitions should take precedence for interpreting their resource; fallback
timezone data needs an explicit version and cannot blindly rely on Tiger's
old system rules.

For SyncServices, use `com.apple.Calendars` and the
`com.apple.calendars.*` entities. The proposed mapping is:

| Stored object | Apple entity/projection |
| --- | --- |
| Calendar collection | `Calendar` |
| Master or detached VEVENT | `Event` |
| RRULE | `Recurrence` |
| EXDATE | Event `exception dates` |
| Override | `original date`, `main event`, inverse `detached events` |
| ATTENDEE / ORGANIZER | `Attendee` / `Organizer` |
| Supported VALARM | `DisplayAlarm` / `AudioAlarm` |

Apple's reference marks calendar color, extra floating-time fields, and
`CalDAVAccount` as Leopard additions. `CalendarOrder` belongs to iCal and is
read-only for other clients. Recurrence frequency supports daily through yearly,
so subdaily rules cannot be passed through directly. Set calendar `read only`
for the one-way projection and verify iCal honors it. Source: Apple's
[iCal schema reference, preserved copy](https://leopard-adc.pepas.com/documentation/AppleApplications/Reference/SyncServicesSchemaRef/Articles/Calendars.html).

Before finalizing `CalendarSyncClient.plist`, inspect the installed Tiger
`/System/Library/SyncServices/Schemas/Calendars.syncschema` and produce small
native fixtures to verify required properties, identity matching, date value
types, inverse relationships, and recurrence behavior. The available SDK has
API headers but did not supply that installed schema in the inspected paths.
Treat the published 2007 reference as a starting point; gate each property on
Tiger availability. Register a stable server client such as
`com.retrocloudsync.calendars.v1` with push-only mapped entities.

Build the supported calendar object graph before opening an ISyncSession.
Preserve the contacts approach of consistent sync mode across related entities.
A complete push omitting previously known records can mean deletion, and
cancellation does not roll back every earlier phase of a session.
[Apple session management guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SyncServices/Articles/SessionManagement.html)
Therefore, persist pending publication state and make replay idempotent. On a
mapping failure, reuse that resource's last successful projection or defer the
export if a coherent graph cannot be assembled. Never export a partial series
as if missing exceptions or alarms had been deliberately removed. Only confirmed
remote absence removes a previously exported resource's graph.

Use the existing Tiger ISyncSession entry points with manual reference counting.
The local SDK explicitly gates ISyncSessionDriver and session anchor overloads
to 10.5; use our own SQLite publication journal for Tiger recovery. Keep network
transactions outside the framework session. Retry a pending export from the
last committed mirror even if a later network attempt fails.

Support ordinary events, all-day events, tested time zones, common recurrence
rules, detached instances, cancellations/exclusions, and display alarms in the
first usable iCal import. Floating times, RDATE combinations, THISANDFUTURE,
custom zones, end-relative alarms, and other difficult forms require explicit
mapping tests. Preserve their data and report unsupported exports rather than
silently simplifying them. Do not turn a cancelled instance into deletion of
the whole resource. Keep mail alarms and unknown executable/attachment alarm
actions stored until their local behavior is deliberately implemented. VTODO
can be retained as received without promising a modern iCloud Reminders bridge.

The daemon integration should use a shared account worker/coordinator that
attempts Contacts and Calendars independently and serializes SyncServices
sessions. Calendar-only operation must work. A failed contact fetch must not
skip calendar work, and vice versa; retain the independent mail proxy. Keep
existing configuration keys compatible, supply a separate calendar service URL,
and bind database rows to account identity so changing username cannot export
the previous account's data. Disabled mode pauses work; TwoWay continues to
report unsupported until implemented.

Proposed new source files are `RCDAVClient.c/.h` for extracted XML/discovery
helpers, `RCCalDAVMirror.c/.h`, `RCICalendar.c/.h`, `RCCalendarStore.c/.h`, and
`RCCalendarSyncServicesBridge.m/.h`. Keep the contacts mapper separate. Update
the daemon source list, shared-test source list and dependency linking, bundle
`CalendarSyncClient.plist`, and teach RCServiceController to install it next to
the existing client description. No additional LaunchAgent is necessary.

Implement and verify in this order:

1. Prove the libical cross-build and Tiger schema mappings with synthetic
   fixtures. Resolve all-day boundaries, DST recurrence, detached identity, and
   read-only calendar behavior before committing to the full bridge.
2. Add the portable codec/store and a non-shipped read-only CalDAV probe.
   Verify raw-body preservation, readable rows, stable IDs, parse failures,
   empty calendars, href renames, and account isolation.
3. Add discovery and complete inventories, including simulated mixed-status
   DAV failures and interrupted downloads. Confirm failed runs cannot create
   false deletions. Then add batching/token optimizations as needed.
4. Add an offline calendar SyncServices verifier with a separate test client.
   Check iCal visibility using Tiger-compatible scripting/UI access, idempotent
   repeat imports, updates, recurrence exceptions, deletion, and retry after
   interruption. Record and preserve pre-existing calendars/events; avoid
   assumptions about global CalendarOrder. Keep remote tools/artifacts under
   `~/Desktop`, as required by AGENTS.md.
5. Connect calendar-only and combined daemon modes; verify resource installation,
   restart behavior, pending-export recovery, and failure isolation. Run portable
   tests, release build, static analysis, and native Tiger/Leopard tests before
   enabling the feature for normal use.

Future bidirectional work needs a durable outbox, per-resource base revision,
and explicit conflict handling. Patch supported changed fields into retained
calendar data; never rebuild an entire remote series from only Tiger's visible
fields. Conditional writes belong to the resource, not an individual exception.
Scheduling also needs separate consideration: calendar writes can participate
in invitation processing under
[CalDAV scheduling RFC 6638](https://www.rfc-editor.org/rfc/rfc6638).
That work should not delay the requested durable download and one-way import.

Investigation validation: `make test-shared` passed for the existing vCard and
contact-store code. Calendar compatibility, libical portability, current iCloud
capabilities, and actual Tiger/iCal publication remain implementation gates.
