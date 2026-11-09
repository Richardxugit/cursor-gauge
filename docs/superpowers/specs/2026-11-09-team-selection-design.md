# Team Selection — Settings Dropdown and Most-Usage Default

Status: approved
Date: 2026-11-09

## Problem

A Mac restart left the menu bar showing the wrong numbers: usage `$0.00` and limit `$200`
while the dashboard showed usage `$25` and limit `$400`. Both v1.0.0 and v1.0.1 are
affected; it is not a regression introduced by the summary-refresh work.

Root cause is team selection. The user belongs to several teams (e.g. `bugbot` and
`tech-digital`). `discoverIdentity()` walks the teams list in API order and returns the
**first team whose member row publishes a limit**. After the restart the first
limit-bearing team was a quiet one (limit 200, zero spend) while the team the user
actually works in (limit 400, real spend) sits later in the list. The app therefore
reads a team it should not.

The current picker cannot know which team the user considers "theirs", and any
heuristic that ranks teams by limit alone can be wrong. So:

1. Make the choice **explicit**: a Team dropdown in Settings, persisted across
   launches.
2. Give the choice a sensible **default**: when the user has not picked a team, show
   the team with the **most usage** (highest `overallSpendCents`).

## Behaviour

### Selection

For each team in `/api/dashboard/teams` (API order), fetch `get-team-spend` and find
the member row for the signed-in user. A team with a matching row is a candidate.

Pick, in order:

1. **Explicit preference** — `preferredTeamID` matches a candidate. The Settings
   dropdown writes this; it is persisted in `UserDefaults` and survives restarts.
2. **Most usage** — the candidate with the highest `overallSpendCents`. Ties are
   broken by: has a limit, then API order. This is the default for every existing
   user (no preference stored), so installing the fix immediately shows the right
   team without touching Settings.
3. No candidate at all → `noTeamFound`, unchanged.

The old rule ("first team with a limit") is removed.

### Identity cache

`CursorAPI` caches the discovered identity in memory. The cache is now scoped to the
`preferredTeamID` it was discovered with: a different preference (or a preference
appearing for the first time) triggers rediscovery. `forgetIdentity()` clears the
cache as before.

### Team options

`CursorAPI.teamOptions` exposes the teams list (`id`, `name`) captured during
discovery. It costs nothing extra — discovery already reads the teams endpoint — and
feeds the Settings dropdown.

### Store

- `UsageStore.preferredTeamID` is read on every refresh and passed to
  `fetchSnapshot(detail:preferredTeamID:)`.
- `UsageStore.selectTeam(_ id: Int?)` sets the preference, clears the current
  snapshot/metrics (so one team's figures are never shown as another's), and the
  caller kicks a refresh. Clearing matters: showing stale numbers from the old team
  while the new reading is in flight would read as the same bug this feature fixes.
- `UsageStore.teamOptions` mirrors the API's list for the dropdown.

### Settings UI

A "Team" section with a picker:

- `Auto — most usage` (nil) is the first entry and the default.
- One entry per team in `teamOptions`, tagged with the team id.
- Only shown once teams are known; a single team still shows the picker (it is also
  the documentation of which team is being displayed).

## Out of scope

- Per-team team switchers elsewhere in the UI. The menu bar always shows the selected
  team; the dropdown is the single source of truth.
- Automatic re-selection when the user joins or leaves a team. A stale stored
  preference falls back to the most-usage rule until the user picks again.
- Changing any refresh cadence.

## Acceptance

- With `bugbot` (limit 200, spend 0) listed before `tech-digital` (limit 400,
  spend 25): no preference → `tech-digital` wins. This is the reported bug scenario.
- A stored preference for `bugbot` → `bugbot` wins even though it has less usage.
- A stored preference for a team id that no longer exists → most-usage fallback.
- `fetchSnapshot` issued with a preference uses that team for spend, aggregates and
  events (assert the `teamId` in request bodies).
- Identity cache: rediscovery happens when the preference changes; repeated calls
  with the same preference hit the network once.
- `teamOptions` reflects the teams endpoint in API order.
- Store: `selectTeam` clears the old snapshot immediately; the next refresh reads
  the new team.
- Settings persists the pick across launches (UserDefaults).
- Full suite stays green; menu bar, cadence and report behaviour are untouched.
