# Calendar date overflow and explicit local restoration

On OS X 10.9.5, EventKit persists a recurrence end as signed 32-bit seconds
from 2001-01-01. A disposable native test verified that 2147483647 survives a
fresh store read, while 2147483648 and a 2099 end date return -2147483648
(1932-12-13 20:45:52 UTC). The original in-memory EKEvent still reports the
requested date after save, so reading that object alone misses the failure.

All three importers (Sync Services, Mac EventKit and iOS EventKit) now apply a
conservative compatibility policy: every imported date must fit signed 32-bit
seconds in both the Unix (1970) and Apple (2001) epochs. The inclusive UTC range
is **1932-12-13 20:45:52 through 2038-01-19 03:14:07**. This is a precautionary
policy, not a claim that every field or OS has the Mavericks storage defect.

The shared mapper checks start/end dates, recurrence limits, recurrence IDs,
exception/additional dates, absolute alarms and derived end/alarm dates. Source
dates are checked before recurrence projection; projected dates are checked
again. EventKit additionally checks converted all-day start/end dates before
saving. Floating dates use the local timezone. Unused wire metadata (such as
CREATED) and VTIMEZONE transition history are not imported dates and do not
cause rejection. Open-ended recurrence is not expanded indefinitely for this
check; no artificial UNTIL is added.

An unsafe date skips the entire resource/series, with a warning identifying the
field rather than private event text. Original cloud bytes are retained and the
sync does not advance full-publication success. EventKit preserves any owned
local copy and continues with safe resources; a durable date-range attention
entry clears when the resource maps safely again. Sync Services one-way imports
retain the last safe published graph. If that retained graph is itself unsafe,
the complete-graph publication stops before opening a session rather than
omitting an existing event. Two-way Sync Services similarly pauses when a
rejected resource was previously published, avoiding accidental deletion or
upload from an obsolete baseline. No automatic clamping or repair occurs.

After native saves on all supported EventKit platforms, the publisher resets
the store, reloads the owned event and checks start/end dates, recurrence ends
and absolute alarm dates before acknowledging publication. Failed readback
retains the pending save for recovery. Existing series whose only difference is
the exact Mavericks overflow signature receive `native-series-date-overflow`,
without authorizing a write or clearing attention.

Removing UNTIL in iCloud does not automatically overwrite an existing local
series: rCloud protects local occurrences and exceptions. For a user who has
explicitly chosen to discard local-only changes to particular events, the
maintenance tool restores only those owned roots from committed cloud downloads.
It uses the production mapper, native publisher and durable publication receipt,
performs no network operations, and never advances account-wide success.

1. Let a normal download finish; confirm the desired cloud change is cached.
2. Stop rCloud. The tool refuses to run while `rcloudd` is running.
3. Build `make build-calendar-recovery` in the configured Altivec container.
   Stage `build/tools/macOS/calendar-recovery/rCloud Calendar Recovery.app` under
   `~/Desktop` on the Mac.
4. Launch it with the database path, a **new** backup path, and only the roots
   the user authorized for local overwrite:

   ```sh
   open "$HOME/Desktop/rCloud Calendar Recovery.app" --args \
     "$HOME/Library/Application Support/rCloud/Calendar.sqlite" \
     "$HOME/Desktop/calendar-before-restoration.sqlite" \
     cal-EXPLICITLY-SELECTED-ROOT
   ```

   Approve Calendar access through the normal system dialog if requested.
   The tool exports a private, consistent SQLite backup before any restoration.
   It rejects missing/ambiguous ownership, missing local records, pending native
   saves, pending writes/fields, calendar operations, and unusable downloads.
   Each selected resource is restored separately; a later failure does not undo
   earlier successful restores. Inspect `~/Desktop/rCloud-calendar-recovery.log`.
5. Restart rCloud and verify its next sync. A successful restoration removes only
   that root's series/publication attention; unrelated warnings remain intact.

The backup preserves rCloud's previous publication data and journal. It is not
an export of every local EventKit occurrence or exception. Explicit restoration
may discard local-only changes to the selected series and must never run as
an automatic response to a sync warning.

On iOS, run the installed executable as `mobile` after unloading its launchd
job. `--restore-calendars DATABASE NEW_BACKUP ROOT [ROOT ...]` uses the same
ownership, pending-write and native-publication checks as the Mac tool. It
refuses a live daemon PID recorded in the adjacent Status.plist and creates a
new private SQLite backup before changing selected local events. Restart the
launchd job after checking the result. This is an explicit maintenance action,
not an automatic sync policy.

`--remove-excluded-calendars DATABASE NEW_BACKUP ROOT [ROOT ...]` is a separate,
explicitly authorized local cleanup for selected owned events outside the
current download scope. It rejects in-scope events and pending writes, removes
the local copy through EventKit, and clears that root's series attention only
after checking removal. It retains the cloud resource and never queues a cloud
DELETE. Back up the native Calendar database as well before discarding local
occurrences or exceptions. Widening the history scope may import the event again.

New cloud recurring series in two-way mode use ordinary first publication and
persisted readback. Existing native series still take the protected audit path;
this exception does not authorize replacing local occurrences or exceptions.

Retained native events outside the requested history scope do not prevent the
current in-scope inventory from completing publication. Their ownership,
attention records and pending writes remain intact; scope exclusion never
means remote deletion.
