# CursorGauge

A macOS menu bar indicator for your Cursor spend. A hexagon that fills like a pie chart as
you approach your monthly limit, with an end-of-cycle estimate and a per-chat cost
breakdown behind a click.

```
  ⬡  $30.32                   ← menu bar
```

The wedge starts at twelve o'clock and sweeps clockwise, so the filled area *is* the
percentage: a quarter spent fills a quarter of the shape, a full limit fills it solid.

Two deliberate choices. It is a filled hexagon rather than a thin progress ring because on
a $200 limit a normal month sits near 2%, and a 2% ring is an empty circle with nothing to
read — a solid silhouette keeps its presence. And a true-to-scale 1% slice is a hairline
that vanishes at 18pt, so any spend at all draws at least a 14° wedge: "a little" must
never look like "none".

## Why this exists

Building was the second choice. The existing trackers — **CursorMeter**,
**cursor-status-bar**, **SessionWatcher**, the Raycast *Cursor Costs* extension — all
work the same way, and all of them are correct for the plan they target: a **Pro**
subscription, where you get N included requests against a hard limit. They read
`GET /api/usage` and gauge against `hardLimit`.

On an **enterprise pooled-token contract** those endpoints aren't wrong so much as
*blank*, which is worse — a gauge renders blank as a confident zero. Live, on this
account, mid-cycle, with real money spent:

```jsonc
GET  /api/usage                     → {"gpt-4":{"numRequests":0,"maxRequestUsage":null}, …}
POST /api/dashboard/get-hard-limit  → {"hardLimit":2147483647}
```

`maxRequestUsage` is `null` because this contract doesn't meter included requests at all,
and `2147483647` is `Int32.max` — a sentinel for "no personal cap", not a limit. Gauge
$49.59 against a notional $2.1-billion ceiling and you get **0.000002%**: a bar that
never moves, never warns, and looks perfectly healthy on the day you hit the real one.

The figure that actually governs the account is in the **team dashboard** endpoints,
because on this contract your spend is a slice of a team pool. Spend, limit and billing
cycle arrive together:

```jsonc
POST /api/dashboard/get-team-spend
{ "overallSpendCents": 4959, "monthlyLimitDollars": 200,
  "effectivePerUserLimitDollars": 200,
  "subscriptionCycleStart": "1785542400000", "nextCycleStart": "1788220800000" }
```

Two things plausibly kept the existing tools away from it. The route is a `POST` that
answers `403 Invalid origin for state-changing request` unless you send
`Origin: https://cursor.com`, which reads as "forbidden" rather than "add a header". And
it's a *team* endpoint — an unlikely place to go looking for a personal number.

**On a Pro plan, use one of the tools above instead.** This one would tell you nothing
you couldn't get more easily. It earns its place only where the personal endpoints come
back empty.

## Install

```sh
./build.sh --install     # builds universal, installs to /Applications
open /Applications/CursorGauge.app
```

Nothing to configure. It reads the token the Cursor app already stores on this Mac and
discovers your user id, team and billing cycle by itself.

**First launch, if you got this as a download** rather than building it locally: it's
ad-hoc signed, not notarized, so macOS quarantines it.

```sh
xattr -dr com.apple.quarantine /Applications/CursorGauge.app
```

Built locally, that isn't needed.

**Launch at login** is off by default. Turn it on in Settings if you want it.

## What it shows

| | |
|---|---|
| **Gauge + amount** | Spend this billing cycle against your limit |
| **Today** | Spend since midnight, live |
| **Estimated total** | Where the cycle lands at the current rate (hidden for the first day — too noisy) |
| **Top sessions** | What each chat cost, subagents rolled into the chat that spawned them |
| **Last request** | When Cursor last charged something |

"Estimated total" is a **forecast of the end-of-cycle total**, including what you have
already spent — not the balance remaining. There is deliberately no burn-rate row: it is
this figure divided by the cycle length, so the two would carry one fact between them.

### Sessions

Usage events carry a `conversationId`, which is the composer id of the chat in Cursor's
history — and Cursor records `subagentInfo.parentComposerId` on any chat it spawned. So a
planning chat and the thirteen task chats it dispatched roll up into one line:

```
TOP SESSIONS THIS CYCLE
▾ OXP-54 feature discussion  $16.76
    Implement Task 4 fetch hook    $2.83
    Final whole-branch code review $1.96
    Implement Task 6 Single+Side   $1.79
    Show 12 more                   $7.05
▸ Order tracking e2e test     $3.01
  Show 11 more                $6.05
```

Rows rank by rolled-up cost, so the size of the *job* drives the order. Click to expand a
chat, or "Show N more" for the rest of the cycle. Subagents are cut the same way — the
priciest three, then the rest on click, because one chat here spawned fifteen.

A subagent list does not sum to its parent, and that is not a bug: the difference is what
the parent chat spent on its own requests. Above, the fifteen subagents come to $13.63
against a $16.76 parent — the $3.13 gap is the planning chat's own turns.

The last row is a remainder, computed by subtracting the rounded rows above it from the
cycle total — so the column you read always adds up, whatever the cut point. Chats with no
local record (created on another Mac, or aged out of Cursor's store) cannot be named and
appear as a single `Unnamed sessions (N)` line rather than N anonymous rows.

### Models

Where the month went by model, in one collapsed row until you ask for it:

```
▾ MODELS                            $47.02
    Auto                             $25.06
    claude-sonnet-5-thinking-high    $11.83
    composer-2.5-fast                 $7.51
    Cursor Grok 4.5 (Auto Balanced)   $2.54
```

Ordered by cost, and read from the usage events, which name real models
(`claude-sonnet-5-thinking-high`) where the aggregate endpoint reports only a
`modelIntent`. It covers every event, including spend in sessions that could not be
named, so the total matches the cycle rather than just the nameable part.

**"Auto" is a relabelling, and worth understanding.** Cursor bills those requests under
`default` — a placeholder that names nothing and looks like a bug in a cost list. Nothing
in the event carries the model that actually ran: not `tokenUsage`, not
`subscriptionProductId`, not the aggregate, and nothing in Cursor's local store either.
The pick is unrecoverable, so the row takes the model picker's word for it.

What it means becomes clear by joining the billing feed to Cursor's own local
`modelConfig` for each chat. Over one cycle, every request:

| chat's local setting | billed as | reqs |
|---|---|---|
| Auto, `optimize_for: cost` | `default` | 108 |
| Auto, `optimize_for: balanced` | `Cursor Grok 4.5 (Auto Balanced)` | 7 |
| picker never touched (`default`) | `default` | 11 |
| no local record for the chat | `default` | 21 |
| any explicitly chosen model | itself | 17 |

So **Auto discloses its pick on Balanced and hides it on Cost** — without exception here.
Not one `default` request came from a chat set to a named model. That is also the useful
lever: if you want Cursor to itemise what it ran, move Auto off Cost. On this account the
Cost tier is the single largest line in the cycle, and the one line that cannot be broken
down.

The row is labelled `Auto` rather than `Auto (Cost)` on purpose. A third of these
requests come from chats whose picker was never touched or that have no local record at
all, so Cost is not provable for them — and the local config is the chat's *current*
setting, so reading it per-event would retroactively relabel past spend whenever you
change a chat's mode. `Auto` is true in every one of those cases.

Auto requests Cursor *does* resolve keep the name it gives them, such as
`Cursor Grok 4.5 (Auto Balanced)`. Knowing which model ran beats knowing it was Auto, so
those are never folded away — which is why one row says `Auto` and another names an Auto
pick. That is the difference between "Cursor chose, and told us" and "Cursor chose, and
didn't".

### Colour

The gauge stays monochrome while healthy and only takes colour when it means something:
amber past 60%, red past 85%, both configurable.

**Pace warning.** On a $200 limit a normal month barely moves the gauge, so absolute
percentage is a weak signal. Pace mode goes amber when spending outruns the calendar —
40% of budget on day 10 of 31 — regardless of how low the percentage is. The thin
vertical marker on the progress bar is where the calendar says you should be.

## How it refreshes

There's no push API, so it polls adaptively:

| Situation | Interval |
|---|---|
| Cursor frontmost in the last 5 min | 60s |
| Cursor running but idle | 5 min |
| Cursor not running | 30 min |

Plus immediately on menu open, on ⌘R, and on wake from sleep. Repeated failures back off
exponentially to a 15-minute ceiling. A reading old enough to mislead is dimmed rather
than shown as current.

The clock runs independently of whether any given reading succeeds, and no reading may
take longer than 45 seconds. Both matter more than they sound: a request that never
returns used to leave the app with no timer and no way back, frozen on its last figure
for as long as it stayed open. A VPN that roams is enough to cause it — the socket stays
open with nothing ever arriving, so there is no gap between packets for an ordinary
request timeout to notice.

## Sharing it with a colleague

```sh
./package.sh     # → dist/CursorGauge-<VERSION>.dmg, about 1 MB
```

A drag-to-Applications disk image: the app, an `Applications` shortcut, and a note about
the first launch. Send them the `.dmg`. The version comes from the `VERSION` file, which
`build.sh` reads too, so the bundle and the filename can't disagree.

The build has no account details compiled in — user id, team and cycle are discovered at
runtime — so the same `.app` shows each person their own usage. It reads whichever
account is signed into Cursor on that machine; copying it elsewhere doesn't carry your
data with it. Recipients need:

1. Cursor installed and signed in on their Mac
2. macOS 14 or later (Intel and Apple Silicon both work — the binary is universal)
3. To clear quarantine once, per the note in the image — see below

### The Gatekeeper step, and how to remove it

There is no Apple Developer certificate on this machine, so `package.sh` falls back to an
**ad-hoc signature**. That is a real signature — the bundle can't be tampered with
unnoticed — but it isn't tied to an Apple-registered identity, so a *downloaded* copy is
quarantined and refused on first open. Since macOS 15 the old right-click → Open bypass
is gone; it takes a Terminal command or a trip to System Settings:

```sh
xattr -dr com.apple.quarantine /Applications/CursorGauge.app
```

The image ships with that instruction in `Read me first.txt`, so it survives being
forwarded without you attached to it.

To remove the step entirely you need a **paid Apple Developer account** ($99/yr) and
Apple's notarization. With a "Developer ID Application" certificate in the keychain
`package.sh` finds it and uses it automatically — no flags, and the hardened runtime and
secure timestamp notarization requires are applied for you. Then store a credential once
and pass `--notarize`:

```sh
xcrun notarytool store-credentials CursorGauge \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
./package.sh --notarize
```

That uploads the image, waits for Apple, and staples the ticket so it validates offline.
The result opens on any Mac with a double-click and no warning, and the readme note is
dropped from the image because there is nothing left to explain.

For a handful of colleagues the `xattr` line is honestly fine. The certificate is worth
it once you're handing this to people you can't easily talk to.

## Privacy

`get-team-spend` returns every team member's name and email — 105 people on this team.
Only the fields for the signed-in user are declared in the decoding model, so everyone
else's details are discarded at the parse boundary and never stored, logged or displayed.
`CursorAPITests.testColleagueIdentityIsNotDecoded` pins that.

Session names are read from Cursor's own store on this Mac and rendered only in your own
menu. They are never sent anywhere. Note they *are* your chat titles, so they can carry
ticket numbers — worth knowing before screen-sharing.

The app holds no secret of its own. It reads `cursorAuth/accessToken` **read-only** from
Cursor's SQLite store and lets Cursor's own refresh cycle keep it valid.

## Development

```sh
swift test                                   # 93 tests, no network and no database
swift run CursorGauge --dry-run              # print the live reading as text
swift run CursorGauge --emit-preview out.png # render every menu bar state
swift run CursorGauge --design-lab out.png    # compare candidate gauge shapes
./build.sh                                   # universal .app in ./build
./build.sh --install                         # …and replace /Applications/CursorGauge.app
./package.sh                                 # distributable .dmg in ./dist
```

`--dry-run` is the quickest way to check the app against
[cursor.com/dashboard](https://cursor.com/dashboard) — the figures should match.

## Caveat

These are **undocumented internal endpoints** (`/api/dashboard/*`) and Cursor can change
them without notice. Decoding is defensive: a changed shape, an HTML error page or a
missing field surfaces as a visible "API changed" message rather than a crash or, worse,
a confidently wrong number.

If they ever break for good, the documented
[Admin API](https://cursor.com/docs/account/teams/admin-api) (`/teams/spend`) is the
fallback — but it needs a team admin key.
