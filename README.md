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
▾ MODELS                          $26.63
    default                        $9.73
    claude-sonnet-5-thinking-high  $9.39
    composer-2.5-fast              $7.51
```

Ordered by cost, and read from the usage events, which name real models
(`claude-sonnet-5-thinking-high`) where the aggregate endpoint reports only a
`modelIntent` (`default`). It covers every event, including spend in sessions that could
not be named, so the total matches the cycle rather than just the nameable part.

`default` is not a model — it is Cursor's **Auto** setting (`auto-smart`). Cursor picks
per request and never reports which model actually ran. On this account Auto handled 65
requests for $9.73 while 5 hand-picked Sonnet-thinking requests cost $9.39: the difference
is `cursorTokenFee`, charged on the premium model and zero on the rest.

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

## Sharing it with a colleague

```sh
./package.sh     # → dist/CursorGauge-1.0.0.dmg, about 1 MB
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
swift test                                   # 89 tests, no network and no database
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
