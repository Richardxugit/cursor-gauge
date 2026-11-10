# CursorGauge

A macOS menu bar indicator for your Cursor spend. A hexagon that fills like a pie chart as
you approach your monthly limit, with an end-of-cycle estimate and a per-chat cost
breakdown behind a click.

Built for **one member of an enterprise team**, watching their own slice of a pooled
contract. Not a team dashboard, and it needs no admin rights: every person who installs
it sees their own usage, discovered from whichever account is signed into Cursor on that
Mac.

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

### The one that does target enterprise

[cursor-usage-tracker](https://github.com/ofershap/cursor-usage-tracker) is the closest
real alternative, and in one respect better built: it reads Cursor's **documented Admin
API** (`/teams/spend`, `/teams/filtered-usage-events`, `/teams/groups`) rather than the
undocumented dashboard routes, so it won't break the way this can.

It answers a different question, though. It's a self-hosted Next.js dashboard for
watching a *whole team* — per-developer spend, model mix, anomaly detection, alerting.
Cost governance for whoever owns the budget.

Two things rule it out here. It authenticates with an **Admin API key**, issued only to
team admins, and this account is `TEAM_ROLE_MEMBER` — the key isn't ours to create. And a
dashboard you have to open is not a glance: the entire point of a menu bar item is seeing
the number without first deciding to look.

They aren't competing. If you can get an admin key and want team-wide cost governance,
run that. This stays useful alongside it, because it answers "what am *I* spending, right
now" without a login, a container, or a browser tab — and it names the chats, which a
server-side tool cannot do, since chat titles never leave your Mac.

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

The current feature set, at a glance:

| Area | Included |
|---|---|
| **Menu-bar gauge** | Cycle spend against the limit; show amount, percentage, or icon only; stale readings are dimmed |
| **Cycle figures** | Best-available cycle spend from live/settled billing figures, today's spend, last request, and an end-of-cycle estimate (hidden for the first day — too noisy) |
| **Warnings** | Configurable amber/red thresholds, plus optional pace warnings when spend outruns the billing calendar |
| **Teams** | Automatic selection of the team with the most usage, or an explicit persisted choice in Settings |
| **Sessions** | Per-chat cost with subagents rolled into their parent, expandable rows, and explicit partial-feed/unnamed-session handling |
| **Cloud agents** | Separate cloud spend, or a cloud marker when the chat also has a local record |
| **Models** | Cycle-wide model spend from billed events, including an honest `Auto` bucket when Cursor does not disclose the selected model |
| **Reports** | Offline HTML and structured JSON joining billing with editor and CLI activity; prompt text is excluded unless explicitly requested |
| **Refresh** | Activity-aware polling, quiet-account backoff, incremental event top-ups, full reconciliation, wake/menu/manual refresh, and failure recovery |
| **Startup** | Optional launch at login; off by default |

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

### Cloud agents

```
  $3.01 Order tracking e2e test
  $0.54 ☁ Cloud agents (1)
 $15.89 Show 22 more
```

A cloud agent runs on Cursor's servers, so its chat never reaches this Mac and can't be
named. Rather than disappear into `Unnamed sessions`, that spend gets its own row: `(1)`
is **one agent run**, not one request, matching every other row in the list where the
count is how many pieces of work were collapsed into it.

That is deliberately all the detail there is. The question worth answering is *whether
cloud agents are costing you anything, and how much* — a cost question. Naming the
individual agent is an activity question, and answering it would need Cursor's Background
Agents API and an admin key.

Cursor marks these with both `isHeadless: true` and a `cloudAgentId`, and uses that id as
the `conversationId`; either signal alone is taken as proof, so the row survives Cursor
dropping one. If a cloud chat ever does sync down it keeps its name and carries a ☁
marker instead — a session is only called cloud when its *whole* subtree ran there, since
one begun in the cloud and continued locally is genuinely both.

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

### Settings

Settings persist across launches:

- **Menu bar:** amount spent, percentage of limit, or icon only.
- **Team:** `Auto — most usage` by default, or a specific team. Switching teams clears the
  old team's figures immediately and refreshes all spend, model and session data in the new
  team context; an in-flight answer from the previous team is discarded. Reports and
  `--dry-run` use the same selection — including when the CLI runs outside the app bundle
  (`swift run`): both read the same preferences domain.
- **Warnings:** amber and red thresholds, and whether pace warnings are enabled.
- **Startup:** open at login, available when running as an installed app bundle.

## Reports

The menu answers *how much have I spent?* A report answers *what did I spend it on?*

```sh
CursorGauge --report                 # writes to a temp file and opens it
CursorGauge --report ~/usage.html    # or a path you choose
```

Or **Usage Report…** (⌘E) in the menu. Either way you get one self-contained HTML file —
no scripts, no web fonts, nothing fetched — that opens offline and survives being emailed.
If the browser can't be opened to show the finished report, the menu says so and shows
the path the file was written to, instead of failing silently.

**What makes it worth having** is that it joins two sources the app already reads:

| | Billing API | Cursor's local database |
|---|---|---|
| Has | cents, models, tokens, per conversation | prompts, tool calls, repos, lines changed |
| Lacks | any activity detail | any cost |

Neither can tell you which repo is consuming your $200. Joined on the conversation id,
they can:

```
Where the money went
  ko-ui-lib        $30.23    25 chats · 1,169 tool calls · 88 prompts
  ko-tests         $22.43    21 chats · 1,215 tool calls · 91 prompts
  ko-services       $7.52    13 chats ·   336 tool calls · 26 prompts
  Cloud agents      $0.54    1 chat with no local record
  Unattributed      $5.93    billed work whose chat isn't in the local store
```

A chat whose billed events all cost zero counts as free of charge.

Also: spend by model, cost and effort per day, your chats ranked with the tool counts
behind them, which tools ran and how often they failed, what file types were touched, and
how you asked — prompt count, typical length, and your `/ko-feature`-style commands ranked.

**Three things it is careful about:**

- **Both halves cover the same window.** Activity is filtered to the billing cycle, so six
  months of tool counts can't sit beside one cycle of spend and imply a rate.
- **Nothing is filed under a repo it didn't come from.** Repos are keyed by full path, so
  two directories that share a name stay separate; when same-named rows do appear, each
  shows its full path. Spend that can't be traced goes to one of three named buckets —
  cloud agents, unattributed, or free of charge — and the footer states whether the buckets
  add up to the cycle total. If they don't, it says so rather than quietly rounding.
- **It reads statistics, not content.** Prompt *lengths* and *counts*, never prompt text;
  file *paths*, never file contents. Verified against a live report: none of 42 real prompt
  openings appear in the output.

Chat titles and repository names *do* appear — a title can carry a ticket number, so treat
the file the way you'd treat your branch names. The page says this on its own face.

If Cursor's database can't be read, the report still renders the cost half and states that
the rest is missing, rather than showing empty sections. A readable store with no activity
is described as quiet, not broken. Incomplete event coverage is marked as partial, and the
JSON export reports editor/CLI readability independently under `activityAvailability`.

### Both front ends

Cursor is two tools: the editor, and `cursor-agent` in a terminal. They keep **entirely
separate records** — the editor in `state.vscdb`, the CLI under `~/.cursor/chats` — and
nothing in one references the other.

The billing API never made that distinction, so CLI spend was always in the total and the
gauge was always right. But with only the editor's store to join against, none of it could
be named: on the cycle this was built against, **the entire "Unattributed" bucket turned
out to be CLI work** — $6.68 of it, every cent. Reading both stores closed it to $1.03,
named all eleven terminal chats, and put their spend against the right repositories.

The report shows the split, and each chat carries a `source` of `gui` or `cli`. A
chat with no local record in either store — cloud agents, or billed work whose chat
isn't in either — carries `unknown`, and is never labelled editor work.

Two limits, stated wherever the numbers appear:

- **The CLI's tool names differ** — `Read` where the editor says `read_file_v2`, `Shell`
  where it says `run_terminal_command_v2`. They do comparable work, but asserting they are
  the same tool is an equivalence this code can't verify, so they stay separate rows.
- **CLI messages carry no timestamps.** Only the conversation has start and end times, so
  the window applies per conversation and its counts are whole-conversation. Measured on
  real data this is nearly exact: no CLI conversation ran longer than 1.5 hours, median four
  minutes. And roughly two thirds of its message blobs aren't plaintext, so CLI *activity*
  counts are a floor. Cost is unaffected — that comes from the billing API and is exact.
  For the same reason, `--with-prompts` does not read CLI text (see the JSON section).

### JSON, for charts this report doesn't draw

```sh
CursorGauge --report out.json --json                  # facts only
CursorGauge --report out.json --json --with-prompts   # …plus the prompt text
```

The HTML answers the questions it was designed around. The JSON is for the ones it wasn't —
hand it to a model or a notebook and ask for whatever cut you want.

It exports **facts, not judgements**: which tools ran in each chat, which file types it
touched, how long its prompts were, what it cost. Never a label like *"this was a bug fix"*.
Those classifications are worth making, but baking one taxonomy in here would discard the
evidence behind it — a consumer can derive its own and show its work; it cannot un-derive
someone else's.

Per conversation you get id, title, repo, mode, cost, requests, prompt count, prompt
lengths, tool-name→count, extension→count, lines added/removed, files changed, first/last
activity, and whether it ran in the cloud. Plus the cycle, the residual buckets, and daily
series.

That's enough to derive most of what a work-analytics dashboard shows **without reading a
prompt**. On one real cycle, from behaviour alone:

| Axis | Derived from |
|---|---|
| Intent (Ask / Write Code / Plan / Automation) | which tools ran — edits vs reads vs planning tools |
| Task complexity | tool calls, prompt count, files changed |
| Categories (Documentation / Testing / Feature) | file extensions touched |
| Prompt specificity | median prompt length |

Work type (KTLO / Feature / Bug) is the exception — it genuinely needs the text, because
slash commands classify only ~10% of prompts. That's what `--with-prompts` is for.

**`--with-prompts` sends nothing anywhere** — it only widens what the local file contains,
and only with editor prompt text. It does not claim to recover CLI text: the export adds
`promptTextCoverage`, stating `gui` as `complete` or `unavailable` and `cli` as
`unsupported`, and CLI conversations omit `promptText` entirely rather than exporting an
empty array.
Nothing is decrypted or invented. The editor text it does export is everything you typed,
which on a work account means client code and ticket detail. It's off by default for that
reason, and the export states `includesPromptText` so a consumer never has to guess
whether an empty field means "none" or "not collected".

Every total reconciles four ways — conversations, repositories plus residuals, the daily
series, and the cycle total all agree to the cent — and `attribution.reconciles` says so
explicitly, so a consumer can refuse to chart a breakdown that doesn't add up.

## How it refreshes

There's no push API, so it polls adaptively:

| Situation | Interval |
|---|---|
| Cursor frontmost in the last 5 min | 60s |
| Cursor running but idle | 5 min |
| Cursor not running | 30 min |

When the menu is closed and repeated polls return the same spend, today's total and last
activity, active/idle polling backs off exponentially to a 30-minute ceiling. New activity
resets it immediately. An open menu always keeps the base cadence, dormant polling is
already capped at 30 minutes, and failure backoff remains separate rather than compounding
with quiet backoff.

Background polls fetch only the headline summary and latest-request marker. Opening the
menu upgrades to a full read. Full reads incrementally top up the event feed with a
ten-minute overlap for late-arriving events, deduplicate adjusted rows, and periodically
reconcile against the whole billing cycle; cycle rollover or a truncated feed also forces
a full rebuild. Full reads resolve the session tree once on a background thread before
publishing; summary polls do no session-name lookup. Reports always export the whole event
window rather than a top-up.

There is also an immediate refresh on menu open, on ⌘R, and on wake from sleep. Repeated
failures back off exponentially to a 15-minute ceiling. A reading old enough to mislead is
dimmed rather than shown as current.

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
ticket numbers — worth knowing before screen-sharing, and before sharing a report file.

Everything read from Cursor's local database goes through SQLite **read-only** (`mode=ro`),
so Cursor's own write-ahead log is never disturbed. Reports aggregate *inside* the database
and pull back only totals: prompt lengths but never prompt text, file paths but never file
contents. That is a deliberate boundary — a single `edit_file_v2` parameter holds an entire
file body, and it stays where it is.

The app holds no secret of its own. It reads `cursorAuth/accessToken` **read-only** from
Cursor's SQLite store and lets Cursor's own refresh cycle keep it valid.

## Development

```sh
swift test                                   # offline; no network and no account database
swift run CursorGauge --dry-run              # print the live reading as text
swift run CursorGauge --report out.html      # build the usage report
swift run CursorGauge --report out.json --json   # …as data instead
swift run CursorGauge --emit-preview out.png # render every menu bar state
swift run CursorGauge --emit-menu-preview out.png  # render the menu's action rows
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
