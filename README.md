# CursorGauge

A macOS menu bar indicator for your Cursor spend. A hexagon that fills from the base as
you approach your monthly limit, with burn rate and end-of-cycle projection behind a
click.

```
  ⬡  $3.58                    ← menu bar
```

The shape is a flat-top hexagon rather than a progress ring for a specific reason: on a
$200 limit a normal month sits near 2%, and a thin ring at 2% is an empty circle with
nothing to read. A filled silhouette keeps its presence when nearly empty, and a flat
base means a low fill renders as a sliver rather than tapering into a stray triangle.

## Why this exists

The existing Cursor usage trackers target individual **Pro** plans: they read
`GET /api/usage` and gauge against `hardLimit`. On an **enterprise pooled token
contract** those return zeros and `2147483647` respectively, so the gauge is empty or
meaningless.

The real per-user figure lives somewhere none of them look — `get-team-spend`, which
returns spend, limit and billing cycle in one response:

```jsonc
{ "userId": 307093031, "overallSpendCents": 331,
  "monthlyLimitDollars": 200, "effectivePerUserLimitDollars": 200 }
```

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
| **Projected** | Extrapolated end-of-cycle total (hidden for the first day — too noisy) |
| **Burn rate** | Dollars per day so far this cycle |
| **Models** | Per-model cost and token split, top 3 |
| **Last request** | When Cursor last charged something |

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

## Sharing it with a colleague

The build has no account details compiled in — user id, team and cycle are discovered at
runtime — so the same `.app` shows each person their own usage. They need:

1. Cursor installed and signed in on their Mac
2. macOS 14 or later (Intel and Apple Silicon both work — the binary is universal)
3. The `xattr` command above, once

It reads whichever account is signed into Cursor on that machine. Copying it elsewhere
doesn't carry your data with it.

## Privacy

`get-team-spend` returns every team member's name and email — 105 people on this team.
Only the fields for the signed-in user are declared in the decoding model, so everyone
else's details are discarded at the parse boundary and never stored, logged or displayed.
`CursorAPITests.testColleagueIdentityIsNotDecoded` pins that.

The app holds no secret of its own. It reads `cursorAuth/accessToken` **read-only** from
Cursor's SQLite store and lets Cursor's own refresh cycle keep it valid.

## Development

```sh
swift test                                   # 52 tests, no network
swift run CursorGauge --dry-run              # print the live reading as text
swift run CursorGauge --emit-preview out.png # render every menu bar state
swift run CursorGauge --design-lab out.png    # compare candidate gauge shapes
./build.sh                                   # universal .app in ./build
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
