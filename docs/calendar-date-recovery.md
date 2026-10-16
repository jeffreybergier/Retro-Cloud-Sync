# Calendar date overflow and explicit local restoration

On OS X 10.9.5, EventKit persists a recurrence end as signed 32-bit seconds
from 2001-01-01. A disposable native test verified that 2147483647 survives a
fresh store read, while 2147483648 and a 2099 end date return -2147483648
(1932-12-13 20:45:52 UTC). The original in-memory EKEvent still reports the
requested date after save, so reading that object alone misses the failure.

The native publisher rejects recurrence ends outside that range on Mavericks
before modifying an event. It keeps the complete downloaded iCalendar data.
After native saves on all supported EventKit platforms, it resets the store,
reloads the owned event and checks start/end dates and recurrence ends before
acknowledging publication. Failed readback retains the pending save for recovery.
Existing series whose only difference is the exact overflow signature receive
`native-series-date-overflow`, without authorizing a write or clearing attention.
Other differences still require ordinary local-edit attention. iOS and later
macOS are not assumed to share Mavericks' recurrence-end range.

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
