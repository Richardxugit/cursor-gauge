# Background summary refresh for CursorGauge

## Goal

Reduce the network, decoding, and local-database work performed by background polling
without changing the existing refresh cadence, menu content, or report output.

A background poll currently downloads every billed event in the cycle (up to three pages
of 500), resolves session names from both local stores, and rebuilds the complete session
tree. Most of that work is invisible while the menu is closed.

## Non-goals

- No change to the 60-second, 5-minute, or 30-minute polling cadence.
- No change to the gauge, menu layout, thresholds, or report format.
- No speculative caching layer for API responses or CLI metadata.
- No reduction in the detail returned by a manual refresh or a usage report.

## Design

### Two snapshot detail levels

`CursorAPI` gains an explicit snapshot detail level with two modes, shared with the app
target so `UsageStore` can select the appropriate read:

- **Summary** is used by background polling. It fetches team spend, cycle aggregation,
  today's aggregation, and one event page with `pageSize: 1`. The event request exists only
  to keep **Last request** current. It performs no session-name lookup and returns no
  session tree or raw report events.
- **Full** retains the current behavior: up to three event pages of 500, local session-name
  resolution, the complete session tree, and raw events for reports.

The existing `fetchSnapshot()` entry point remains full by default, so `ReportCommand` and
existing callers keep their current behavior. A summary still updates all headline values,
including spend, limit, cycle dates, today's spend, aggregate model usage, last activity,
and capture time.

A summary read does not claim to contain report events. Its `events` array is empty and its
sessions value is empty; consumers that need either must request a full snapshot.

### Menu visibility selects the work

`UsageStore` tracks whether the menu is open:

- Timer, wake, and other background refreshes use summary mode while the menu is closed.
- Opening the menu immediately requests a full refresh.
- Refreshes that run while the menu is open use full mode, so a timer cannot replace the
  visible session tree with an empty summary.
- Closing the menu restores summary polling at the next scheduled refresh.

`MenuContent` reports appearance and disappearance to the store. The existing refresh
shortcut remains a full refresh because the shortcut is available only while the menu is
open.

### In-flight refresh upgrade

A menu can open while a summary refresh is already running. The existing in-flight guard
must not turn that open into a no-op and leave the menu without sessions until the next
poll.

The store records that detail is required when the menu opens. After an in-flight summary
finishes, it runs one full refresh if the menu is still open and detail is still required.
A full refresh clears that requirement when it starts. Repeated timer events during a full
refresh do not queue additional full refreshes.

### State replacement and failures

A successful summary may replace a closed menu's previous detail; it is not visible and the
next menu open fetches it again. While the menu is open, only a full snapshot replaces the
visible snapshot.

A failed refresh keeps the previous snapshot and follows the existing stale/error behavior.
No summary result is ever passed to report generation. Account reauthentication continues
to invalidate the cached identity; a subsequent menu open obtains a fresh full snapshot.

## Verification

New tests are written before the implementation and must demonstrate the expected failure
first.

### API tests

- Summary mode sends `pageSize: 1` and makes exactly one filtered-events request.
- Summary mode performs no `SessionNaming` lookup and returns the latest activity date.
- Summary mode returns no session tree or raw events.
- Full mode retains `pageSize: 500`, pagination, session naming, and raw events.
- Existing snapshot and report tests continue to pass without changing their expectations.

### Store tests

- A background refresh requests summary mode.
- Opening the menu requests full mode and populates session details.
- Opening the menu during a stalled summary upgrades to one full refresh after the summary
  finishes or times out.
- Timer refreshes while the menu is open remain full and do not erase session details.
- Closing the menu restores summary mode.
- Existing deadline, recovery, stale-data, and failure tests remain green.

### macOS verification

Run the complete XCTest suite and build the app on macOS. Exercise these real UI paths:

1. Launch with the menu closed and confirm the gauge updates.
2. Open the menu during an initial refresh and confirm sessions appear without waiting for
   the next timer.
3. Leave the menu open across a refresh and confirm the session list remains populated.
4. Close and reopen the menu, then run a manual refresh.
5. Generate HTML and JSON reports and confirm their session and event data remain complete.

The optimization is accepted on the structural evidence that a background poll requests one
event instead of up to 1,500 and performs zero naming lookups. No percentage improvement is
claimed without measurements from the real account and local stores.
