# Per-session costs in the CursorGauge dropdown

Show what each Cursor chat cost, with subagent runs grouped under the chat that spawned
them.

## Why

The gauge answers "how much of my $200 is gone". It cannot answer "gone on what". On a
subagent-driven workflow that gap is large: on 2026-08-06 a single planning chat
(`OXP-54 feature discussion`) spawned 13 subagents and accounted for **$13.64 of the
day's $13.64**. Within it, `Implement Task 4 fetch hook` cost $2.83 — a third of the
implement budget, and more than the entire six-chat review pass. None of that is visible
in Cursor's dashboard or in the app today.

## What we discovered

All of this was verified live against the account on 2026-08-06.

### Usage events already carry a session id

`POST /api/dashboard/get-filtered-usage-events` returns a `conversationId` on every
event. That id **is** the composer id — the chat in Cursor's history sidebar:

```
bubbleId:9ee76573-9d38-4e6d-bd40-7fab527e4435:…      ← local chat messages
composerData:9ee76573-9d38-4e6d-bd40-7fab527e4435    ← name: "Implement Task 7 Mixed view"
```

### Cursor records the parent→subagent link explicitly

No inference needed. The relationship is stored on both ends:

| Side | Field |
|---|---|
| Parent | `subagentComposerIds: [<id>, …]` |
| Child | `subagentInfo.parentComposerId`, `subagentInfo.subagentTypeName` |

Over 7 days: 33 sessions, **17 subagents** (13 `generalPurpose`, 4 `e2e-debugger`), 16
top-level, **zero orphans**. The rollup reconciles exactly with the day's spend, which is
the correctness check that matters:

```
OXP-54 feature discussion          own $2.21   rolled $13.64   ← equals Today
   └ Implement Task 4 fetch hook       $2.83
   └ Implement Task 6 Single+SidePanel $1.79
   └ Implement Task 7 Mixed view       $1.55
   … 13 subagents
```

Genuinely standalone chats stay flat (`Ko PR description $0.07`).

### It costs no extra network calls

The app already calls `get-filtered-usage-events` on every poll with `pageSize: 1`, purely
to populate "Last request". Widening that same call serves both purposes. Poll cost stays
at three requests.

### Reading names is cheap if done in SQL

`composerData` blobs average 91 KB and reach 692 KB; pulling 33 into the app would move
~3 MB per poll. `json_extract` in the SQL statement returns just the strings —
**measured 10 ms for 33 ids**, and the blobs never enter our memory.

### Click-to-open is not available

Cursor registers only two deeplink routes (`cursor-deeplink/automations`,
`cursor-deeplink/background-agent`). Internal commands such as `composer.openComposer`
exist but no URL route or CLI flag can invoke them. **Rows are therefore not clickable**;
we will not ship an affordance that looks live and isn't.

## Design

### Menu

Roots collapsed by default, each with a disclosure triangle. `Session` is the most recent
root, rolled up — the answer to "what is this sitting costing me".

```
  ⬡  $23.51 of $200              12%
     ────────────────────────────────
     Today                     $13.64
     Session                   $13.64
       OXP-54 feature discussion
     Projected           $118 by Sep 1
     Burn rate              $4.70 / day
     ────────────────────────────────
     TOP SESSIONS THIS CYCLE
     ▸ OXP-54 feature discussion $13.64
     ▾ Order tracking e2e test    $1.64
         Debug checkout flow      $0.71
         Fix flaky selector       $0.55
         Retry timeout handling   $0.38
     ▸ Ko PR description          $0.07
     ────────────────────────────────
     Last request          2 min ago
```

Roots rank by **rolled** total, so cost of the whole piece of work drives the order.
Children rank by own cost. Expansion state is view-local and resets when the menu closes.

### Components

| Component | Responsibility | Depends on |
|---|---|---|
| `CursorAPI` (edit) | Widen the existing events call; expose raw events | — |
| `SessionCatalog.swift` (new, Core) | id → name / parent / subagent type, from the local DB | SQLite, read-only |
| `SessionRollup.swift` (new, Core) | Events + catalog → tree of `SessionNode`. Pure | neither |
| `MenuContent` (edit) | Render the section, own expansion state | the above |

`SessionRollup` is pure, so the grouping and arithmetic — the part with real logic — test
without a database or a network, exactly as `UsageMetrics` does.

```swift
public struct SessionNode: Equatable, Identifiable {
    public let id: String            // conversationId == composerId
    public let name: String?         // nil when not on this Mac
    public let subagentType: String?
    public let ownCents: Double      // sum of chargedCents, incl. cursorTokenFee
    public let requestCount: Int
    public let lastActivity: Date
    public let children: [SessionNode]

    public var rolledCents: Double { … }   // own + children, recursively
}
```

`UsageSnapshot` gains `sessions: [SessionNode]` (roots).

### API changes

- Window becomes cycle-start → now, matching the gauge so the figures reconcile.
- `pageSize: 500`; page while `totalUsageEventsCount` exceeds what we hold, **capped at 3
  pages (1500 events)** so a heavy month cannot stall a poll. A truncated read is flagged
  so the UI can mark the list partial rather than under-report silently.
- `FilteredUsageResponse.Event` gains `conversationId: String?`.
- `chargedCents` stays the money field: it includes `cursorTokenFee`, which
  `tokenUsage.totalCents` omits (measured: 122.2¢ + 73.4¢ = 155.2¢).

### Catalog resolution

One statement, extracting in SQL:

```sql
SELECT substr(key, 14),
       json_extract(value, '$.name'),
       json_extract(value, '$.subagentInfo.parentComposerId'),
       json_extract(value, '$.subagentInfo.subagentTypeName')
FROM cursorDiskKV WHERE key IN (…)
```

A parent may have no billed requests of its own and so be absent from the event set, so
resolution iterates: query, collect unseen parent ids, query again — **to a depth of 4**,
which both closes the set in practice and bounds the work.

Opened read-only (`mode=ro`), the pattern already proven by `TokenStore` against the same
~480 MB WAL database.

### Failure behaviour

Session data is strictly additive; nothing here may take down the gauge.

| Failure | Result |
|---|---|
| Local DB unreadable / Cursor not installed | Costs still shown, names read `Unnamed session` |
| `subagentInfo` absent or shape changed | Session treated as top-level |
| Parent id not resolvable | Child promoted to root |
| Parent cycle (A→B→A) | Broken by a visited set; nodes emitted once |
| Event without `conversationId` | Excluded from the tree, still counted in Today/cycle |
| Page cap hit | List marked partial |

## Testing

Pure logic, TDD (`SessionRollupTests`): flat sessions; parent with children; rolled
arithmetic; root ordering by rolled and child ordering by own; orphan promotion; cycle
guard; missing name; event with no `conversationId`; empty input.

Decoding (`CursorAPITests`): `conversationId` present and absent; pagination stops at
`totalUsageEventsCount`; page cap honoured. The existing
`testColleagueIdentityIsNotDecoded` must keep passing.

Catalog (`SessionCatalogTests`): fixture DB covering named, unnamed, subagent, and
missing rows, plus depth-limited parent resolution.

End-to-end: `--dry-run` prints the tree; **root rollups must sum to the cycle total** —
the assertion that catches a dropped or double-counted subagent.

## Out of scope

- **Clickable rows** — no supported route exists (see above).
- **A toggle to hide session names.** Names surface ticket numbers (`OXP-54`), which
  matters when screen-sharing. Deferred, not designed away: raised with Peirong twice and
  not requested. One `Preferences` flag and a fallback label if it's wanted later.
- **`composerData.usageData`** — a local per-session usage field spotted during
  investigation. Unexamined; the API path already reconciles, so it stays unopened.
