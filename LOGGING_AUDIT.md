# Daemon logging audit

Audited 2026-09-08. Scope: project-owned daemon output, shared-library progress
callbacks and propagated errors, recovery/test command output, LaunchAgent log
routing, and the GUI log reader. This is a source audit, not a runtime trace or
an inventory of every diagnostic third-party libraries might emit. No runtime
logging behavior was changed during the audit itself. The findings below describe
the pre-change code; line references refer to that snapshot.

## Current output paths

| Source | Output and coverage |
|---|---|
| `source/macOS-daemon/main.m` | `NSLog` for startup/configuration, account credentials, download summaries, local publication, outgoing failure, shutdown, and test commands. Recovery commands use stdout/stderr directly. |
| `source/shared/RCCardDAVMirror.c` | String-only progress callback: discovery, inventory, sync-token fallback, each downloaded contact, and invalid-contact retention. `main.m` adds `Contacts:`. |
| `source/shared/RCCalDAVMirror.c` | Same callback: discovery, token checks/fallback, unchanged calendar, and each resource download. `main.m` adds `Calendars:`. |
| `source/macOS-daemon/RCTwoWaySync.m` | Direct `NSLog` for retained local edits, deferred acceptance/mapping, successor operations, conflict reconciliation, isolated records, and exceptions. Shared by Contacts and Calendars, but messages usually omit which service. |
| `source/macOS-daemon/RCCalendarTwoWay.m` | Direct unsupported-resource warning; other failures propagate through `RCError`. |
| `source/macOS-daemon/RCCalendarSyncServicesBridge.m` | Direct mapping/retention and cancellation messages; other errors propagate to `main.m`. |
| `source/macOS-daemon/RCSyncServicesBridge.m` | Direct cancellation error; other errors propagate to `main.m`. |
| Other daemon mapping/conflict/session helpers | Primarily return `RCError` or durable attention state rather than writing logs directly. These affect the text printed by callers. |
| `source/macOS-daemon/RCMailProxy.c` | Private printf-style `RCLog`, socket helper, and OpenSSL error callback feed `RCMailProxyLogMessage` in `RCMailProxyLog.m`, which uses `NSLog`. |
| Shared HTTP, DAV writer, stores, journal, parsers, credentials | Primarily return errors or persist outcomes. The writer can successfully persist a conflict/uncertain outcome without producing a log. HTTP logging uses generic curl errors, not HTTP bodies. |
| `source/macOS-app/RCServiceController.m:395` | LaunchAgent sends stdout and stderr to the same `~/Library/Logs/RetroCloudSync/RetroCloudSyncDaemon.log`. |
| `source/macOS-app/DaemonLogView.m` | Displays raw text, refreshes every five seconds while updating, and reads the last 1 MiB. There is no severity filter. The display limit does not limit disk growth. |

## Findings, in priority order

1. **Download success is labeled as overall sync success.**
   `main.m:192` and `:248` print “sync complete” before local publication and
   before the final outgoing pass. A user can see success followed immediately
   by failure. Rename these to “Download complete.” Log local application and
   outgoing results independently. Add a poll summary only after tracking all
   those outcomes; do not infer overall success from the current `exported` flag.
   For contacts, statistics retrieval can fail after a successful fetch and is
   currently reported as “Contacts sync failed”; identify that as a statistics
   failure rather than claiming the download failed.

2. **Upload outcomes are largely invisible.**
   `main.m:109` only logs an outgoing error if `RCTwoWayRunWrites` returns -1.
   `RCTwoWaySync.m:698` returns the number of attempts, not successful uploads.
   `RCDAVWriter.c:29` can return success after recording `conflict` or `uncertain`,
   including non-success HTTP statuses. Those outcomes therefore need explicit
   reporting from the durable result, with service, operation ID, create/update/
   delete, and HTTP status when available. Distinguish queued, attempted,
   remotely verified, and locally acknowledged. “Conflict reconciled” currently
   means a successor was queued, not that the replacement was uploaded.

3. **Messages lack consistent scope and severity.**
   Contacts publication logs say only “Sync Services”; calendars alternate
   “Calendar” and “Calendars”; two-way logs usually name neither. Mail TLS stack
   details lose even the IMAP/SMTP prefix (`RCLogTLSError` ignores its context).
   All application messages use the same `NSLog` entry point with no project
   severity classification. Introduce service and phase metadata, rather than
   trying to classify free-form strings in the GUI.

4. **Recovery language describes implementation state rather than consequences.**
   `RCTwoWaySync.m:208` prints reason identifiers such as
   `verified-write-awaits-local-acceptance`. “Native revision,” “conditional
   successor,” “partial publication,” and “isolating unresolved records” require
   knowledge of the implementation. Keep stable reason identifiers as diagnostic
   fields, but explain what was preserved, what is waiting, and whether other
   records can continue. Some conflict attention reasons are written to the
   journal with no immediate message (`RCTwoWaySync.m:437`). Report the transition
   into attention and aggregate pending counts.

5. **Failure, deferral, fallback, and cached publication are conflated.**
   A missing Keychain password logs “Account download skipped” (`main.m:172`),
   but uploads are also skipped. One-way mode may still publish the last committed
   mirror; two-way mode requires a fresh download and then emits an additional
   export failure. Describe those paths explicitly and avoid reporting the same
   root cause as multiple independent errors. Token fallback is often recoverable
   and should normally be informational. Unsupported mapping can remain blocked
   indefinitely; do not promise a successful automatic retry.

6. **Mail connection diagnostics can state the wrong cause, or no cause.**
   `RCMailProxy.c:141` discards the `getaddrinfo` return code and does not preserve
   connect timeout / `SO_ERROR` consistently. Its caller logs `strerror(errno)`,
   which can be stale or unrelated. Preserve resolver, socket, timeout, TLS, and
   pthread error domains separately; use pthread's returned error code rather
   than errno. `RCRelayConnection`'s result is ignored (`:439`), so established
   connections can fail silently. Per-connection allocation/thread failures in
   the listener are also silent. Add connection IDs and a close outcome, with
   ordinary EOF at DEBUG and actual failures at WARN. Do not report successful
   mail login merely because the TLS proxy connection was established.

7. **Startup errors do not always explain that the whole daemon exits.**
   `main.m:353` says synchronization is disabled, but returns NO and startup exits
   after stopping the mail proxy. A non-dictionary Contacts configuration returns
   NO without any explanation (`:314`). Mail allocation/invalid-input paths can
   also fail without a specific message. Replace “Hello from…” (`:673`) with an
   explicit ready message, and log startup failure with its consequence. Report
   enabled sync modes, interval, calendar history setting, and listener endpoints
   without account credentials. The worker is started before the ready message,
   so allow for worker output preceding readiness, or order initialization logs
   deliberately. Shutdown should identify the request and completion, without
   doing unsafe logging from a signal handler.

8. **Counts mix different units and time scopes.**
   Contacts download summaries mix this-poll downloaded/unchanged counts with
   database-wide available/missing/parse-error totals. Calendar download counts
   measure DAV resources; publication counts can include calendar containers,
   events, alarms, and related Sync Services records. “Export complete: N records”
   does not mean N changed contacts/events. Label units and current-poll versus
   stored totals; do not rename internal record counts to events without adding
   real event counters. Replace negative partial-publication sentinels with a
   result structure if adding summary counts.

9. **Useful errors are buried by repetition and have no poll context.**
   Both mirrors log every resource download; discovery repeats each poll; retained
   or unsupported records can warn repeatedly. Prefer one stage summary and one
   service outcome at INFO, per-resource detail at DEBUG, and warning summaries
   with counts plus stable local IDs for diagnosis. Add a poll ID shared across
   phases, duration, and the next scheduled retry where known. Log recurring
   attention states on change, with periodic reminders; avoid suppressing new
   failures along with duplicates. The project has no log rotation mechanism;
   add a bounded retention policy separately from the GUI's display cap. Renaming
   a file alone is insufficient when launchd-owned stdout/stderr descriptors
   continue writing to it.

10. **Free-form external details need a common formatting boundary.**
    HTTP errors currently use `curl_easy_strerror`, and DAV writer code explicitly
    avoids turning response bodies into protocol logs. Preserve that behavior.
    Some Sync Services paths include raw exception reasons, while two-way paths
    only include exception names; raw reasons may contain record details or
    embedded newlines. Use a bounded, single-line, sanitized detail policy and
    structured exception/error domains. Prefer local resource/operation IDs to
    account URLs, contact names, event titles, or content. Do not dump credentials,
    mail traffic, vCards, iCalendar bodies, or recovery snapshots into routine logs.
    C progress strings currently pass through `%s`; use explicit UTF-8 conversion
    at the common boundary, as the mail bridge already does.

## Recommended convention

Keep the legacy-compatible NSLog sink initially, with a shared daemon logging
helper callable from C and Objective-C. Preserve its timestamp/process prefix;
add a consistent message prefix, for example:

```text
INFO [Daemon] Ready: Contacts=two-way, Calendars=one-way, interval=300s
INFO [Contacts][Download][poll=12] Complete: 3 resources downloaded, 42 unchanged
WARN [Calendars][Apply][poll=12][resource=81] Unsupported change; previous local version retained
WARN [Contacts][Upload][poll=12][operation=17] Server version changed; local edit preserved for reconciliation
INFO [Contacts][Upload][poll=13][operation=18] Server change verified; local acknowledgement pending
```

These are proposed examples, not observed runtime output. Only emit claims such
as “previous version retained” after confirming that outcome.

| Level | Meaning |
|---|---|
| ERROR | Daemon startup or a requested phase failed. Name the affected scope and consequence. |
| WARN | Partial progress, unresolved conflict, unsupported change, or a failed individual mail connection; explain what remains pending/preserved. |
| INFO | Ready/stopped, configuration summary, phase outcomes, normal fallback, recovery transition. |
| DEBUG | Discovery steps, per-resource progress, normal mail connect/close details, sanitized low-level diagnostics. |

Use `Contacts`, `Calendars`, `Mail/IMAP`, `Mail/SMTP`, `Account`, and `Daemon`
consistently. Use `Download`, `Apply`, `Upload`, `Recovery`, and `Database` phases
where appropriate. In explanations, “apply to local apps” is clearer than
“export”; retain “Sync Services” in technical failure details. Do not change
persisted journal reason/state strings just to improve presentation.

Keep recovery CLI stdout stable and separate from daemon lifecycle logs. Its
row-oriented output and snapshot success output are command results, not routine
log entries. Keep test-only messages explicitly labeled as tests. Preserve
secondary cancellation errors as secondary errors, without overwriting the
original failure; remove the duplicate two-way exception log when the caller
already logs the returned error with the same context.

## Suggested implementation sequence and verification

1. Add the common C/Objective-C helper with severity, service, optional phase,
   bounded UTF-8 details, and errno preservation. Retain manual reference
   counting and thread-local autorelease pools for C mail threads. Give shared
   progress callbacks explicit severity/event metadata; do not match text to
   guess severity. Migrate all production emitters, keeping CLI output separate.
2. Fix phase naming, missing service prefixes, startup consequences, and mail
   error propagation. Add tests for resolver errors, connect timeout/refusal,
   pthread failures, multiline/invalid UTF-8 details, and preserved errno.
3. Add explicit per-phase/write results and poll correlation. Exercise successful
   download followed by publication failure, cached one-way publication, missing
   credentials, unsupported mapping, HTTP conflict/uncertain upload, verified
   writes awaiting acknowledgement, and successful recovery. Assert both emitted
   outcomes and the absence of misleading overall-success messages.
4. Reduce repeated progress, add configurable DEBUG output and bounded retention.
   Test that logging remains bounded and does not lose new failures; test rotation
   against the actual launchd descriptor arrangement on Tiger. Check the GUI's
   tail reader around rotation and UTF-8 truncation boundaries.

Run `make release` and the relevant portable/Mac suites after implementation;
verify representative logs on Tiger, including concurrent mail and sync output.
No tests were run for this documentation-only audit. No live account data or
remote log files were accessed.

## Implementation following the audit

The daemon now has one `NSLog` sink (`RCLogger.m`), used by both Objective-C and
C callers. Service/phase/severity prefixes, thread-local poll/connection context,
DEBUG filtering, bounded single-line UTF-8 handling, phase-specific completion
wording, per-attempt durable upload outcomes, readable recovery messages, and
mail resolver/socket/thread error reporting are implemented. Raw Sync Services
exception reasons are replaced by exception types. Recovery CLI stdout remains
unchanged. Native tests exercise the actual NSLog sink on Tiger.

Follow-up items remain: bounded disk retention, deduplication of recurring
attention warnings, richer aggregate upload/publication counters, and detailed
TLS/relay failure classification. These require additional state or lifecycle
changes beyond the common logger and message migration. The GUI's 1 MiB display
limit still does not rotate the log file.
