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

One list, ranked by cost. Top five shown; the rest behind a "show more" row that carries
its own total, so the cycle always accounts for itself even while collapsed.

```
  ⬡  $23.51 of $200              12%
     ────────────────────────────────
     Today                     $13.64
     Estimated total     $128 by Sep 1
     ────────────────────────────────
     TOP SESSIONS THIS CYCLE
     ▾ OXP-54 feature discussion $13.64
         Implement Task 4 fetch   $2.83
         Implement Task 6 Single  $1.79
         Implement Task 7 Mixed   $1.55
     ▸ Order tracking e2e test    $3.01
     ▸ PR review comments         $0.52
     ▸ OXP-30 test case generation $0.17
     ▸ OXP-81 getOrderView update $0.12
       Show 11 more               $6.05
     ────────────────────────────────
     Last request          2 min ago
```

Expanded, the remaining roots appear in the same ranking. The nine with no local record
cannot be listed by name, so they stay aggregated on a final line that says so plainly:

```
     ▸ Ko PR description          $0.07
     ▸ DataLayer GA events        $0.05
       Unnamed sessions (9)       $5.93
       Show less
```

Roots rank by **rolled** total, so cost of the whole piece of work drives the order.
Children rank by own cost. Rows are collapsed by default; expansion state is view-local
and resets when the menu closes. The section scrolls past a fixed maximum height so a
heavy cycle cannot grow the menu without bound.

#### No "current session"

Earlier drafts pinned the session in progress, marked, above the ranking. Dropped: this is
a **cost view**, and a session's recency does not change what it cost. Giving one row
special status added a marker, a legend, a pinning rule, an exclusion rule, and a
`current` field to the model — all to answer a question ("what am I spending right now")
that `Today` already answers better.

Removing it also retires the 21%-miss problem that pinning existed to solve, rather than
solving it.

#### The "show more" total is a remainder, and rounds to match

Two different things fall off the visible list: roots with no local record (nine this
cycle) and named roots below the display cut (two). An earlier draft summed only the
un-nameable ones and silently lost the rest — its own figures came to $23.39 against a
$23.51 cycle.

So the figure on the `Show N more` row is defined by **subtraction, not by category**:

```
more = cycleTotal − Σ(listed)
```

which reconciles by construction whatever the list length or how many roots are nameable.

It is computed from the **rounded** row values, not the raw ones. Summing raw cents and
rounding at the end gives $6.06, and the column then reads $23.52 against a $23.51 total —
correct in memory, visibly wrong on screen. Rounding each listed row first and subtracting
gives $6.05, and the column adds up as displayed:

```
$13.64 + $3.01 + $0.52 + $0.17 + $0.12 + $6.05 = $23.51   ✓
     more = 9 un-nameable ($5.93) + 2 ranked-out named ($0.12)
```

#### Rows removed

- **`Burn rate`** — `estimatedTotal = burnRate × cycleLengthDays` exactly
  ($4.12 × 31 = $128), so the two rows carried one fact. `Estimated total` survives
  because it is directly comparable to the $200 limit.
- **`Session`** — a dedicated row for the session in progress. Removed with the
  current-session concept above; `Today` covers "what am I spending right now".

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
    public let ranked: [SessionNode]     // named roots by rolled cost, all of them
    public let unnamedCents: Double      // roots with no local record, summed
    public let unnamedCount: Int
    public let totalCents: Double        // invariant: ranked + unnamed == total
}
```

`UsageSnapshot` gains `sessions: SessionBreakdown`. The model carries **every** named root;
the view decides how many to show and derives the `Show N more` figure by subtracting the
rounded values of the rows it actually rendered. Keeping truncation in the view means the
"show more" expansion needs no refetch and no second code path.

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
| Local DB unreadable / Cursor not installed | Costs still shown; the whole cycle collapses to `Unnamed sessions (N)` |
| Root has no local record | Aggregated as `Unnamed sessions (N)`, never one row each |
| Named root below the display cut | Absorbed by the `Show N more` remainder |
| `subagentInfo` absent or shape changed | Session treated as top-level |
| Parent id not resolvable | Child promoted to root |
| Parent cycle (A→B→A) | Broken by a visited set; nodes emitted once |
| Event without `conversationId` | Excluded from the tree, still counted in Today/cycle |
| Page cap hit | List marked partial |

## Testing

Pure logic, TDD (`SessionRollupTests`): flat sessions; parent with children; rolled
arithmetic; root ordering by rolled and child ordering by own; orphan promotion; cycle
guard; event with no `conversationId`; empty input; un-nameable roots aggregated into
`unnamedCents`/`unnamedCount`; and `ranked + unnamed == totalCents` asserted as an
invariant across every case.

View logic (`SessionBreakdownTests`): the `Show N more` figure equals
`total − Σ(rounded displayed rows)` — **the displayed column must sum exactly to the cycle
total at any cut point**, the property whose absence produced a $23.39-vs-$23.51 mismatch
in one draft and a $23.52 rounding mismatch in the next. Count on the row matches the
number of hidden roots, expanding hides nothing, and a cycle with fewer roots than the cut
shows no `Show more` row at all.

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
