# Plan — Team Selection (Settings Dropdown + Most-Usage Default)

Spec: `docs/superpowers/specs/2026-11-09-team-selection-design.md`
Branch: `fix/zero-limit-diagnose`

Strict red-green TDD throughout. Each task: write failing tests first, run them
filtered (RED), implement, run filtered (GREEN), then the full suite. Swift runs on
the Mac via SSH; the container has no toolchain. Never invent tool output.

## Task 1 — API: preference + most-usage picker (core)

Files: `Sources/CursorGaugeCore/CursorAPI.swift`,
`Tests/CursorGaugeCoreTests/CursorAPITests.swift`

- Add `TeamOption { id, name }` and `public private(set) var teamOptions: [TeamOption]`,
  populated by every discovery from the teams endpoint (API order).
- `discoverIdentity(preferredTeamID: Int? = nil)`:
  - candidates = teams with a member row for `me.id`;
  - pick: explicit preference match → max `overallSpendCents` (ties: limit present,
    then API order) → none → `noTeamFound`.
- Cache scoped to the preference: store the `preferredTeamID` the cached identity was
  discovered with; mismatch → rediscover. `forgetIdentity()` unchanged.
- `fetchSnapshot(detail: SnapshotDetail = .full, preferredTeamID: Int? = nil)` passes
  the preference through.

Tests (RED → GREEN):
1. Fixture where `bugbot` (first, limit 200, spend 0) must lose to `tech-digital`
   (limit 400, spend 251): assert `teamID == 27362705`. (Reported bug scenario.)
2. Preference for `bugbot` wins despite lower usage.
3. Preference for a nonexistent id falls back to most usage.
4. Cache: same preference → no extra requests; changed preference → rediscovery;
   changed again → rediscovery.
5. `teamOptions` equals `[(28605405, "bugbot"), (27362705, "tech-digital")]`.
6. `fetchSnapshot(preferredTeamID: 28605405)` → the aggregate/events/spend request
   bodies for the snapshot carry `teamId: 28605405`.

## Task 2 — Store: preference plumbing + selectTeam (core)

Files: `Sources/CursorGaugeCore/UsageStore.swift`,
`Tests/CursorGaugeCoreTests/UsageStoreTests.swift`

- `public var preferredTeamID: Int?` (settable), passed to every `fetchSnapshot`.
- `public func selectTeam(_ id: Int?)`: set preference, clear `snapshot`/`metrics`/
  `lastUpdated`, `status = .loading`. Does **not** refresh itself; the caller (UI)
  kicks `refresh()`.
- `public var teamOptions: [CursorAPI.TeamOption] { api.teamOptions }`.

Tests:
1. Refresh with `preferredTeamID = bugbot` uses bugbot's figures (assert snapshot
   limit/spend from the bugbot route; assert event/aggregate bodies carry its id).
2. `selectTeam` clears the old snapshot immediately and leaves status `.loading`.
3. After `selectTeam` + `refresh()`, snapshot shows the new team's numbers.
4. Auto (nil) path still picks most usage (regression).

## Task 3 — App: persistence + Settings dropdown

Files: `Sources/CursorGauge/Preferences.swift`,
`Sources/CursorGauge/SettingsView.swift`, `Sources/CursorGauge/CursorGaugeApp.swift`

- `Preferences.selectedTeamID: Int?` backed by `UserDefaults` key `selectedTeamID`
  (nil = auto), following the existing didSet-persist pattern.
- `SettingsView`: "Team" section with a picker over `store.teamOptions` plus an
  `Auto — most usage` entry (tag `nil`). `onChange` writes the preference and calls
  `store.selectTeam` + refresh. Hidden while `teamOptions` is empty.
- `CursorGaugeApp.init`: `store.preferredTeamID = preferences.selectedTeamID` before
  `start()`.

Verification (Mac): `swift test` full suite green; `swift build`; launch app and
confirm Settings renders the dropdown (no Cursor account on the build Mac, so
team-dependent rendering is covered by unit tests + previews only).

## Task 4 — Release v1.0.2

- `VERSION` → `1.0.2`; commit `chore: release 1.0.2`.
- Full suite green on the exact release commit; `package.sh` → `dist/CursorGauge-1.0.2.dmg`.
- `hdiutil verify`; mount-check version, universal arch, ad-hoc signature.
- GitHub Release `v1.0.2`: publish via the logged-in browser (OpenCLI), upload the
  DMG, release notes mention the team dropdown + most-usage default and the
  Gatekeeper note; re-download and compare SHA-256.
- Real-account verification happens on the user's machine: install 1.0.2, confirm
  the menu shows 400/25 without touching Settings (auto), then switch teams in
  Settings and confirm the numbers follow.
