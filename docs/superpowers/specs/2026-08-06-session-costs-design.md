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

Two sections: the session you are in, then everything else ranked by cost. The current
session is expanded by default — it is the one you want to see inside — and the ranked
list is collapsed.

```
  ⬡  $23.51 of $200              12%
     ────────────────────────────────
     Today                     $13.64
     Estimated total     $128 by Sep 1
     ────────────────────────────────
   ● ▾ OXP-54 feature discussion  $13.64
         Implement Task 4 fetch    $2.83
         Implement Task 6 Single   $1.79
         Implement Task 7 Mixed    $1.55
     ────────────────────────────────
     TOP SESSIONS THIS CYCLE
     ▸ Order tracking e2e test     $3.01
     ▸ PR review comments          $0.52
     ▸ OXP-30 test case generation $0.17
     ▸ OXP-81 getOrderView update  $0.12
       Other sessions              $6.06
     ────────────────────────────────
     Last request          2 min ago
```

Roots rank by **rolled** total, so cost of the whole piece of work drives the order.
Children rank by own cost. Both sections expand; expansion state is view-local and resets
when the menu closes.

The current session is excluded from the ranked list, so it renders exactly once. That is
why the list below can start at $3.01 while a larger figure sits above it.

`THIS CYCLE` is retained on the second header here, having been dropped from the earlier
single-section design. With a "now" section directly above it, the qualifier draws a real
contrast — this session versus the whole month — rather than restating the frame the
surrounding rows already set.

#### The current session is pinned, marked `●`

Ranking by cost alone loses the session you are actually in whenever it is cheap. Measured
by replaying all 84 events of this cycle and asking, after each one, whether the session
just used appeared in the list:

| List length | Current session absent |
|---|---|
| top 3 | **42%** of events |
| top 5 | **21%** of events |
| top 8 | 7% of events |

A one-in-five failure to answer "what is this session costing me" is not acceptable for
what the feature exists to do. So the current root gets its own section above the ranked
list, always first, marked `●`, and is removed from the ranking below.

This replaces the separate `Session` row of the first draft, which showed the name and
figure a second time and duplicated the list's top entry roughly 79% of the time. Giving
the current session the full row — expandable, with its subagents — costs no more space
than that row did and always says something the list cannot.

#### `Other sessions` is the remainder, defined by subtraction

Nine of this cycle's 16 roots have no local record at all — no `composerHeaders` row, no
`composerData`, no subtitle (verified, not assumed). They cannot be named by any local
means, and listing them individually would put "Unnamed session" at positions 3 and 4.

But un-nameable roots are not the only ones that fall off the list: the ranked section is
capped at four, so named-but-cheap roots drop off too. Defining `Other` as only the
un-nameable ones silently loses those — an earlier draft of this spec did exactly that and
its own arithmetic came to $23.39 against a $23.51 cycle.

So `Other sessions` is defined by **subtraction, not by category**:

```
other = cycleTotal − current − Σ(listed)
```

This reconciles by construction, whatever the list length or how many roots are nameable:

```
$13.64 + $3.01 + $0.52 + $0.17 + $0.12 + $6.06 = $23.51   ✓
        other = 9 un-nameable ($5.93) + 2 ranked-out named ($0.13)
```

#### Rows removed

- **`Burn rate`** — `estimatedTotal = burnRate × cycleLengthDays` exactly
  ($4.12 × 31 = $128), so the two rows carried one fact. `Estimated total` survives
  because it is directly comparable to the $200 limit.
- **`Session`** — became the pinned `●` row above.

Net: two metric rows rather than five, and no figure appears twice.

### Relabel: `Projected` → `Estimated total`

Not part of session costs, but found while reviewing this menu and cheap to fix here.
Peirong read `Projected $128 by Sep 1` as the *remaining* balance. It is the opposite: a
forecast of the end-of-cycle **total**, already including the $23.51 spent. The word
"total" removes that reading in a way "projected" and "estimated usage" do not — both can
still be parsed as a balance.

No separate "Left" row: the headline `$23.51 of $200` already carries the balance, and the
menu is worth keeping short. Label only; `UsageMetrics.projectedCents` is unchanged.

### Components

| Component | Responsibility | Depends on |
|---|---|---|
| `CursorAPI` (edit) | Widen the existing events call; expose raw events | — |
| `SessionCatalog.swift` (new, Core) | id → name / parent, from `composerHeaders` | SQLite, read-only |
| `SessionRollup.swift` (new, Core) | Events + catalog → tree of `SessionNode`. Pure | neither |
| `MenuContent` (edit) | Render the section, own expansion state | the above |

`SessionRollup` is pure, so the grouping and arithmetic — the part with real logic — test
without a database or a network, exactly as `UsageMetrics` does.

```swift
public struct SessionNode: Equatable, Identifiable {
    public let id: String            // conversationId == composerId
    public let name: String?         // nil when not on this Mac
    public let ownCents: Double      // sum of chargedCents, incl. cursorTokenFee
    public let requestCount: Int
    public let lastActivity: Date
    public let children: [SessionNode]

    public var rolledCents: Double { … }   // own + children, recursively
}

public struct SessionBreakdown: Equatable {
    public let current: SessionNode?     // most recent root, pinned and marked
    public let ranked: [SessionNode]     // named roots by rolled cost, current excluded
    public let otherCents: Double        // remainder: total − current − ranked
    public let totalCents: Double        // invariant: current + ranked + other == total
}
```

`UsageSnapshot` gains `sessions: SessionBreakdown`. `current` is whichever root holds the
newest event; it is excluded from `ranked` so it renders exactly once. `ranked` is already
truncated to what the menu shows, so `otherCents` absorbs both un-nameable roots and named
roots below the cut.

### API changes

- Window becomes cycle-start → now, matching the gauge so the figures reconcile.
- `pageSize: 500`; page while `totalUsageEventsCount` exceeds what we hold, **capped at 3
  pages (1500 events)** so a heavy month cannot stall a poll. A truncated read is flagged
  so the UI can mark the list partial rather than under-report silently.
- `FilteredUsageResponse.Event` gains `conversationId: String?`.
- `chargedCents` stays the money field: it includes `cursorTokenFee`, which
  `tokenUsage.totalCents` omits (measured: 122.2¢ + 73.4¢ = 155.2¢).

### Catalog resolution

Read `composerHeaders`, **not** `cursorDiskKV`:

```sql
SELECT composerId,
       json_extract(value, '$.name'),
       json_extract(value, '$.subagentInfo.parentComposerId')
FROM composerHeaders WHERE composerId IN (…)
```

`composerHeaders` is a 256-row table keyed by `composerId` PRIMARY KEY. It carries the
same names and the same parent links as the `composerData` blobs — **verified: 0/33 parent
mismatches and identical name coverage (24/33)** — while avoiding blobs that average 91 KB
and reach 692 KB. The first draft read `cursorDiskKV`; this is strictly better for the
same result.

A parent may have no billed requests of its own and so be absent from the event set, so
resolution iterates: query, collect unseen parent ids, query again — **to a depth of 4**,
which both closes the set in practice and bounds the work.

Opened read-only (`mode=ro`), the pattern already proven by `TokenStore` against the same
~480 MB WAL database.

### Failure behaviour

Session data is strictly additive; nothing here may take down the gauge.

| Failure | Result |
|---|---|
| Local DB unreadable / Cursor not installed | Costs still shown; every root falls into `Other sessions` |
| Root has no local record | Absorbed by the `Other` remainder, never listed as "Unnamed" |
| Named root below the display cut | Absorbed by the same remainder |
| `subagentInfo` absent or shape changed | Session treated as top-level |
| Parent id not resolvable | Child promoted to root |
| Parent cycle (A→B→A) | Broken by a visited set; nodes emitted once |
| Event without `conversationId` | Excluded from the tree, still counted in Today/cycle |
| Page cap hit | List marked partial |

The current session is pinned even when it lands in `Other sessions` — it is shown as
`Current session` with its cost, and excluded from the `Other` sum so the total still
reconciles.

## Testing

Pure logic, TDD (`SessionRollupTests`): flat sessions; parent with children; rolled
arithmetic; root ordering by rolled and child ordering by own; orphan promotion; cycle
guard; event with no `conversationId`; empty input. Specifically for this revision —
**current session pinned when it ranks outside the list**, current session not duplicated
when it ranks first, un-nameable roots absorbed by `otherCents`, named-but-cheap roots
below the cut also absorbed, and `current + ranked + other == totalCents` asserted as an
invariant across every case — the property whose absence produced a $23.39-vs-$23.51
mismatch in an earlier draft.

Decoding (`CursorAPITests`): `conversationId` present and absent; pagination stops at
`totalUsageEventsCount`; page cap honoured. The existing
`testColleagueIdentityIsNotDecoded` must keep passing.

Catalog (`SessionCatalogTests`): fixture `composerHeaders` covering named, unnamed,
subagent, and absent rows, plus depth-limited parent resolution.

End-to-end: `--dry-run` prints the tree; **root rollups must sum to the cycle total** —
the assertion that catches a dropped or double-counted subagent.

## Out of scope

- **Clickable rows** — no supported route exists (see above).
- **A toggle to hide session names.** Names surface ticket numbers (`OXP-54`), which
  matters when screen-sharing. Deferred, not designed away: raised with Peirong twice and
  not requested. One `Preferences` flag and a fallback label if it's wanted later.
- **`composerData.usageData`** — a local per-session usage field spotted during
  investigation. Unexamined; the API path already reconciles, so it stays unopened.
