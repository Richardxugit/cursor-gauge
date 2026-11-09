# Plan: Event Feed Incremental Top-Up

Spec: `docs/superpowers/specs/2026-11-09-event-feed-incremental.md`. Strict red-green TDD,
one commit per task, Mac verification between tasks. Branch: `feat/event-feed-incremental`
from `master`.

## Task 1 — API window

- `CursorAPI.fetchSnapshot(detail:preferredTeamID:eventsSince:)` with default `nil`
  (existing call sites unchanged).
- Overlap constant `eventFeedOverlap: TimeInterval = 600`.
- Event feed start = `max(cycleStart, eventsSince - overlap)` when `eventsSince` is given.
- Summary path ignores `eventsSince` (unchanged pageSize 1).
- Tests: transport records `startDate`/`endDate` bodies; assert the top-up window, the
  overlap, the cycleStart lower bound, and that `nil` reproduces today's window exactly.

## Task 2 — Store merge + reconciliation

- `UsageStore` keeps `mergedEvents: [SessionEvent]` per selection (dies with the snapshot
  on team switch, exactly like `snapshot`).
- On a publishable full refresh:
  - top-up: dedupe by `(conversationID, timestamp)`, fresh row wins; rebuild sessions from
    the merged set; `lastActivity` = max over merged set;
  - reconciliation triggers: 10th refresh, `cycleStart` change, feed truncated, no
    previous events; these fetch with `eventsSince = nil` and replace the merged set.
- Failures do not advance the reconciliation counter; superseded attempts publish nothing.
- Tests: merge/dedupe/edit-convergence, counter cadence, cycle-change rebuild, truncation
  rebuild, failure keeps counter, team switch clears merged events, summary polls keep
  pageSize 1.

## Task 3 — Report path + verification

- `ReportCommand` passes `eventsSince: nil` explicitly (default already nil; add the
  explicit argument with a comment so it cannot silently become incremental).
- Mac full suite; independent spec + quality reviews; merge to `master`.

## Task 4 — Release v1.0.3

- Bundle P1 (digest single scan) + P2 (incremental feed).
- Version bump, tag, DMG, GitHub Release, download SHA-256 verification (established
  v1.0.1/v1.0.2 flow).
