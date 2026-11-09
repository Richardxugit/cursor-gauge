# Refresh Performance and Report Reliability Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Remove duplicate/main-actor session processing and make team and completeness state consistent across the menu, reports, and dry-run.

**Architecture:** Keep the existing refresh and reporting pipelines. Add a merge-oriented API entry point that defers session resolution, perform one background build after merging, pass the stored team preference through command boundaries, and add explicit per-source activity availability without changing the JSON schema version.

**Tech Stack:** Swift 5.9, SwiftUI/Observation, XCTest, SwiftPM, SQLite3, macOS 14.

Spec: `docs/superpowers/specs/2026-11-10-refresh-report-reliability.md`.
Branch: `feat/refresh-report-reliability` from `master`.

All tests run on the Mac host through:

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test'
```

Use `swift test --filter TypeName` for focused runs. Record compile-red separately from behavioral-red when adding a new API, per the Swift two-stage TDD workflow.

---

### Task 1: Add the merge-oriented API contract

**Objective:** Let `UsageStore` fetch full/top-up events without constructing a session tree that it will discard.

**Files:**
- Modify: `Sources/CursorGaugeCore/CursorAPI.swift`
- Test: `Tests/CursorGaugeCoreTests/CursorAPITests.swift`

**Steps:**
1. Add a test that calls `fetchSnapshotForMerge(detail: .full, preferredTeamID: nil, eventsSince: nil)` and asserts correct headline/events plus `sessions == .empty` and zero naming lookups.
2. Run `swift test --filter CursorAPITests`; record the missing-method compile red.
3. Add only the internal method and a private shared implementation switch, preserving the old behavior; run again if a behavioral red is needed.
4. Route `fetchSnapshotForMerge` through the same network code with session resolution disabled. Keep public `fetchSnapshot` resolving sessions exactly as before.
5. Verify `CursorAPITests` green. Do not commit separately; this is part of the performance commit after Task 2.

### Task 2: Build once off the main actor

**Objective:** Make each published menu refresh perform one background naming/session pass.

**Files:**
- Modify: `Sources/CursorGaugeCore/UsageStore.swift`
- Modify: `Sources/CursorGaugeCore/CursorAPI.swift`
- Test: `Tests/CursorGaugeCoreTests/UsageStoreTests.swift`
- Test: `Tests/CursorGaugeCoreTests/CursorAPITests.swift`

**Steps:**
1. Add a thread-safe naming probe and inject it through the store test helper. Assert one lookup per full publish, no lookup for summary, `Thread.isMainThread == false`, and unchanged session totals/names on whole-window and top-up responses.
2. Run focused tests and observe assertion red against the current duplicate/main-actor path.
3. Switch the store to `fetchSnapshotForMerge`. Compute the prospective merged events, then use one `Task.detached` to call `sessionRecords` and `SessionBreakdown.build`; return the rebuilt snapshot and merged events.
4. Await the detached result, recheck `selectionGeneration`, and only then update merge state and publish. Preserve the existing repeat-on-supersession loop and all reconciliation counters.
5. Run `swift test --filter UsageStoreTests` and `swift test --filter CursorAPITests`, then the full suite.
6. Commit: `perf: resolve menu sessions once in background`.

### Task 3: Propagate team selection to reports

**Objective:** Make menu-generated and CLI reports use the stored team override.

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/CursorGauge/MenuContent.swift`
- Modify: `Sources/CursorGauge/ReportCommand.swift`
- Create: `Tests/CursorGaugeTests/ReportCommandTests.swift`

**Steps:**
1. Add a `CursorGaugeTests` test target dependent on the executable target. Add a report test using a recording transport, temporary destination, and temporary/empty local-store fixtures; assert every team-scoped request uses the explicit ID and that nil preserves Auto.
2. Run `swift test --filter ReportCommandTests`; record compile red for the new target/seam, then behavioral red for the missing preference propagation.
3. Add `preferredTeamID: Int? = nil` to `ReportCommand.write` and pass it to `fetchSnapshot(..., eventsSince: nil)`. Add internal optional API/catalog injection only where required by the test.
4. Pass `preferences.selectedTeamID` from `MenuContent.buildReport` and `Preferences().selectedTeamID` from `ReportCommand.run`.
5. Run focused and full tests. Commit: `fix: apply team selection to usage reports`.

### Task 4: Propagate team selection to dry-run

**Objective:** Make `--dry-run` print the same team context as the menu.

**Files:**
- Modify: `Sources/CursorGauge/DryRun.swift`
- Create: `Tests/CursorGaugeTests/DryRunTests.swift`

**Steps:**
1. Add a test around an internal async dry-run reading method with injected credentials/API and captured output; assert explicit and nil team choices in identity and snapshot requests.
2. Run focused tests and record the compile/behavioral red sequence.
3. Extract the existing async reading/printing body minimally; keep `run() -> Never` responsible only for preference loading, error-to-exit handling, and process termination.
4. Pass the preference to both `discoverIdentity` and `fetchSnapshot`. Do not change printed fields or formatting.
5. Run focused and full tests. Commit: `fix: apply team selection to dry run`.

### Task 5: Model readable-empty versus unavailable local stores

**Objective:** Carry per-source availability from local catalogs into report models.

**Files:**
- Modify: `Sources/CursorGaugeCore/ActivityCatalog.swift`
- Modify: `Sources/CursorGaugeCore/CliCatalog.swift`
- Modify: `Sources/CursorGaugeCore/UsageReport.swift`
- Test: `Tests/CursorGaugeCoreTests/ActivityCatalogTests.swift`
- Test: `Tests/CursorGaugeCoreTests/CliCatalogTests.swift`
- Test: `Tests/CursorGaugeCoreTests/UsageReportTests.swift`

**Steps:**
1. Add tests for readable-empty GUI/CLI stores, unreadable existing stores, mixed available/unavailable merges, and `UsageReport.unavailableActivitySources`.
2. Run each focused suite and observe red for the new state/behavior.
3. Add `unavailableSources: Set<ActivitySource> = []` to `ActivityDigest`; union it in `merging`. Keep all existing memberwise call sites source-compatible.
4. Mark only actual read/schema failures unavailable. Missing CLI root remains available-empty; preserve all activity figures and best-effort partial data.
5. Run the three focused suites and full suite. Commit: `fix: distinguish quiet and unreadable activity stores`.

### Task 6: Render truthful HTML and JSON states

**Objective:** Expose availability and short-feed partial state without changing unrelated report output.

**Files:**
- Modify: `Sources/CursorGaugeCore/CursorAPI.swift`
- Modify: `Sources/CursorGaugeCore/ReportRenderer.swift`
- Modify: `Sources/CursorGaugeCore/ReportExport.swift`
- Test: `Tests/CursorGaugeCoreTests/CursorAPITests.swift`
- Test: `Tests/CursorGaugeCoreTests/ReportRendererTests.swift`
- Test: `Tests/CursorGaugeCoreTests/ReportExportTests.swift`

**Steps:**
1. Add a short-page/larger-total API test; update renderer/export tests so `.empty` is quiet and an explicit unavailable digest is blind. Cover GUI-only, CLI-only, both, and mixed-with-data cases; assert schema remains `cursor-gauge/report/1`.
2. Run focused tests and observe the expected assertion reds.
3. Set `truncated = collected.count < reportedTotal` after paging, preserving the page-cap bound.
4. Render source-specific unavailable warnings and a neutral readable-quiet note. Add `activityAvailability` with `gui`/`cli` states to JSON; leave `hasActivity` and prompt inclusion unchanged.
5. Run focused tests, then full suite. Commit: `fix: report incomplete activity and event data`.

### Task 7: Documentation and final verification

**Objective:** Document the corrected behavior and verify the integrated result.

**Files:**
- Modify: `README.md`
- Modify only if behavior notes need correction: the approved spec/plan

**Steps:**
1. Update report availability/JSON documentation and note that report/dry-run honor the selected team. Do not claim a measured UI latency improvement without a real benchmark.
2. Run CJK and whitespace checks, `swift test`, and `swift build` on the Mac host.
3. Review the final diff against the spec, including the deferred team-discovery behavior to prove item 4 was not changed.
4. Commit: `docs: describe report availability states`.
5. Merge the verified branch to `master` and push. Do not create a release unless separately requested.
6. Start the separate Usage Report optimization audit only after this integrated result is green.
