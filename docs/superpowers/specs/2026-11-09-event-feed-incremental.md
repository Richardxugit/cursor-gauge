# Event Feed: Incremental Top-Up With Periodic Reconciliation

Status: approved for implementation. Supersedes nothing; builds on the background-summary
refresh design.

## Problem

Every menu-open full refresh downloads the whole billing cycle's event feed
(up to 3 pages x 500 rows) and re-builds the sessions list, even when only the last few
minutes are new. With the menu open the refresh fires every 60 seconds, so a long-lived
session re-downloads megabytes that changed by nothing.

The local side of this was fixed by materialising the activity digest in one scan
(`perf: scan bubble store once per activity digest`). This design addresses the network
side: the usage-event feed.

## Design

Incremental top-up with a periodic full reconciliation:

1. `CursorAPI.fetchSnapshot` gains `eventsSince: Date?`. When non-nil, the event feed
   window becomes `[max(cycleStart, eventsSince - overlap), now]` with `overlap = 10
   minutes`. The overlap admits late-arriving billing events whose server record carries
   an earlier timestamp than the moment they appeared.
2. `UsageStore` merges each top-up into the previous full snapshot's events, deduplicating
   by `(conversationID, timestamp)` with the freshly fetched row winning. This makes an
   adjusted or refunded event converge to its latest state instead of being double-counted.
3. Reconciliation: every 10th full refresh re-fetches the entire window
   (`eventsSince = nil`) and rebuilds from scratch. A full rebuild also happens when
   `cycleStart` changes or when the feed was truncated. Reconciliation bounds how long any
   merge mistake can live.
4. Reports (`ReportCommand`) always use `eventsSince = nil` — an export is a point-in-time
   artifact and must be complete.
5. Summary polls are unchanged (pageSize = 1, no events kept).

## Invariants

- `lastActivity` is the max timestamp over the merged set.
- Sessions are rebuilt from the merged set on every publish.
- Supersession (team switch) still discards everything: merged events belong to the
  selected team and die with its snapshot.
- A top-up that fails leaves the previous snapshot untouched (existing failure semantics).
- Reconciliation counter is per-store and survives refresh failures (failures neither
  advance nor reset it; a failed reconciliation retries on the next refresh).

## Acceptance

- Transport-level tests assert the top-up window (startDate = previous max timestamp minus
  overlap, bounded below by cycleStart) and the reconciliation window (startDate =
  cycleStart).
- Merge tests: new event appended; duplicate replaced by the fresh row; an event edited
  between cycles converges to the latest cents; reconciliation rebuilds from scratch and
  drops stale rows.
- Counter tests: full rebuild on the 10th refresh, on cycleStart change, and on
  truncation; failure does not advance the counter.
- All existing tests remain green; displayed figures for the always-full reference
  implementation and the incremental implementation agree on scripted feeds.
