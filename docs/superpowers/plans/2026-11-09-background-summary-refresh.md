# Background Summary Refresh Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make closed-menu polling fetch only headline usage and one latest-event timestamp while preserving full menu and report data.

**Architecture:** Add a detail parameter to the existing snapshot fetch rather than a second API stack. Let `UsageStore` choose summary/full from menu visibility and upgrade an in-flight summary when the menu opens. Wire the existing menu view lifecycle to that state.

**Tech Stack:** Swift 6.2, SwiftUI MenuBarExtra, Observation, XCTest, URLSession protocols with stub transports.

---

### Task 1: Add summary snapshot reads

**Objective:** Keep full fetch behavior unchanged while allowing a read that avoids event pagination and local session-name queries.

**Files:**
- Modify: `Sources/CursorGaugeCore/CursorAPI.swift`
- Test: `Tests/CursorGaugeCoreTests/CursorAPITests.swift`

**Step 1: Write the failing API test**

Add a test that routes the normal healthy fixture, calls
`sessionAPI(naming).fetchSnapshot(detail: .summary)`, decodes the recorded filtered-event
request body, and asserts:

```swift
XCTAssertEqual(eventRequests.count, 1)
XCTAssertEqual(body?["pageSize"] as? Int, 1)
XCTAssertEqual(body?["page"] as? Int, 1)
XCTAssertTrue(naming.askedFor.isEmpty)
XCTAssertEqual(snapshot.lastActivity, Date(timeIntervalSince1970: 1_785_658_176.745))
XCTAssertTrue(snapshot.events.isEmpty)
XCTAssertTrue(snapshot.sessions.ranked.isEmpty)
XCTAssertEqual(snapshot.liveSpendCents, 251, accuracy: 0.001)
```

Also assert the existing full snapshot request still uses `pageSize: 500` and returns four
raw events.

**Step 2: Run the test and verify RED**

Run on macOS:

```bash
cd ~/Documents/HermesSandbox/workspace/cursor-gauge
swift test --filter CursorAPITests/testSummarySnapshotFetchesOnlyLatestEventWithoutNaming
```

Expected: FAIL because `fetchSnapshot(detail:)` does not exist yet.

**Step 3: Implement the minimal API change**

Add a public nested mode and a default full parameter:

```swift
public enum SnapshotDetail {
    case summary
    case full
}

public func fetchSnapshot(detail: SnapshotDetail = .full) async throws -> UsageSnapshot
```

Give `events` explicit `pageSize` and `maxPages` arguments with the current defaults. In
`fetchSnapshot`, use `1/1` for summary and `500/3` for full. Build sessions and expose raw
events only in full mode:

```swift
let sessions: SessionBreakdown
if detail == .full {
    let conversationIDs = Set(cycleEvents.events.compactMap(\.conversationId))
    let records = conversationIDs.isEmpty ? [:] : naming.records(for: Array(conversationIDs))
    sessions = SessionBreakdown.build(events: cycleEvents.events, records: records)
} else {
    sessions = .empty
}

return UsageSnapshot(
    settledSpendCents: mine.overallSpendCents?.value ?? 0,
    liveSpendCents: cycle.totalCostCents?.value ?? 0,
    limitDollars: (mine.effectivePerUserLimitDollars ?? mine.monthlyLimitDollars)?.value,
    cycleStart: cycleStart,
    cycleEnd: cycleEnd,
    todayCents: today.totalCostCents?.value ?? 0,
    models: models,
    lastActivity: feed.events.map(\.timestamp).max(),
    capturedAt: now,
    sessions: sessions,
    sessionsTruncated: detail == .full && feed.truncated,
    events: detail == .full ? feed.events : []
)
```

Keep `lastActivity` derived from the one returned summary event and keep aggregate model
usage in both modes.

**Step 4: Run focused and complete Core tests**

```bash
swift test --filter CursorAPITests
swift test
```

Expected: all tests pass; existing tests require no expectation changes.

**Step 5: Commit**

```bash
git add Sources/CursorGaugeCore/CursorAPI.swift Tests/CursorGaugeCoreTests/CursorAPITests.swift
git commit -m "perf: add summary snapshot reads"
```

---

### Task 2: Select detail from menu visibility

**Objective:** Use summary polling only while the menu is closed and guarantee a full read when the menu opens during an in-flight summary.

**Files:**
- Modify: `Sources/CursorGaugeCore/UsageStore.swift`
- Test: `Tests/CursorGaugeCoreTests/UsageStoreTests.swift`

**Step 1: Write failing store tests**

Extend `SwitchableTransport` to record requests and optionally stall only the next filtered
usage-event request. Add these tests:

```swift
func testBackgroundAndMenuRefreshesUseTheExpectedDetail() async {
    let transport = SwitchableTransport()
    let store = makeStore(transport: transport, deadline: 1)

    XCTAssertTrue(await store.refresh())
    store.setMenuOpen(true)
    XCTAssertTrue(await store.refresh())
    store.setMenuOpen(false)
    XCTAssertTrue(await store.refresh())

    XCTAssertEqual(transport.eventPageSizes, [1, 500, 1])
}

func testOpeningDuringAStalledSummaryUpgradesToFullAfterTimeout() async {
    let transport = SwitchableTransport()
    transport.stallNextEventRequest()
    let store = makeStore(transport: transport, deadline: 0.3)

    async let refreshed = store.refresh()
    await Task.yield()
    store.setMenuOpen(true)

    XCTAssertTrue(await refreshed)
    XCTAssertEqual(transport.eventPageSizes, [1, 500])
    XCTAssertEqual(store.status, .ready)
}
```

Add a third test that leaves the menu open across two refreshes and asserts both are full.

**Step 2: Run the store tests and verify RED**

```bash
swift test --filter UsageStoreTests
```

Expected: FAIL because `setMenuOpen` is missing and background reads still use full mode.

**Step 3: Implement menu state and the upgrade loop**

Add private state and a public visibility setter:

```swift
private var menuIsOpen = false
private var needsDetailedRefresh = false

public func setMenuOpen(_ open: Bool) {
    menuIsOpen = open
    if open { needsDetailedRefresh = true }
}
```

Keep the existing in-flight guard. Wrap the current do/catch in a small repeat loop. Each
iteration selects `.full` when `menuIsOpen`, otherwise `.summary`; clear
`needsDetailedRefresh` when full starts. After the attempt, repeat only when
`menuIsOpen && needsDetailedRefresh`:

```swift
var succeeded = false
repeat {
    let detail: CursorAPI.SnapshotDetail = menuIsOpen ? .full : .summary
    if detail == .full { needsDetailedRefresh = false }
    succeeded = false
    do {
        let fresh = try await withDeadline(deadline) { [api] in
            try await api.fetchSnapshot(detail: detail)
        }
        snapshot = fresh
        lastUpdated = fresh.capturedAt
        status = .ready
        consecutiveFailures = 0
        recomputeMetrics()
        succeeded = true
    } catch {
        // Preserve the existing failure and reauthentication handling verbatim.
    }
} while menuIsOpen && needsDetailedRefresh
return succeeded
```

Do not add a second polling task or concurrent detail request.

**Step 4: Run store and complete tests**

```bash
swift test --filter UsageStoreTests
swift test
```

Expected: all tests pass, including both existing deadline/recovery tests.

**Step 5: Commit**

```bash
git add Sources/CursorGaugeCore/UsageStore.swift Tests/CursorGaugeCoreTests/UsageStoreTests.swift
git commit -m "perf: poll summaries while menu is closed"
```

---

### Task 3: Wire menu lifecycle and verify the app

**Objective:** Trigger the full read on a real menu open and restore summary reads after close.

**Files:**
- Modify: `Sources/CursorGauge/MenuContent.swift`

**Step 1: Add lifecycle wiring**

Attach these handlers to `MenuContent.body`:

```swift
.onAppear {
    store.setMenuOpen(true)
    Task { await store.refresh() }
}
.onDisappear {
    store.setMenuOpen(false)
}
```

Do not change the existing `start()` call in `CursorGaugeApp` or add a second timer.

**Step 2: Build and run all tests on macOS**

```bash
swift test
swift build
```

Expected: build and complete test suite succeed.

**Step 3: Exercise real behavior**

Launch the app and verify the five UI/report paths in
`docs/superpowers/specs/2026-11-09-background-summary-refresh-design.md`.
In particular, open during the initial refresh and leave the menu open across a timer.
Confirm that sessions remain populated and reports remain complete.

**Step 4: Commit**

```bash
git add Sources/CursorGauge/MenuContent.swift
git commit -m "perf: refresh details when menu opens"
```

---

## Task 4: Package and publish the release

**Files:**
- Modify: `VERSION`

- [ ] Bump `VERSION` from `1.0.0` to `1.0.1` and commit `chore: release 1.0.1`.
- [ ] On the Mac, run the full `swift test` suite again, then `./package.sh`.
- [ ] Verify `dist/CursorGauge-1.0.1.dmg` with `hdiutil verify`, inspect the bundled
      version and universal binary, and record the SHA-256 checksum.
- [ ] Fast-forward `master` to the tested branch, rerun the full suite on the exact
      release commit, then push `master` and tag `v1.0.1`.
- [ ] Create GitHub Release `v1.0.1` titled `CursorGauge 1.0.1`, attach the DMG, and
      include concise notes covering background summary polling, on-demand session
      details, unchanged report exports, and any signing/notarization limitation.
- [ ] Download the published asset through the Release URL and compare its checksum
      with the packaged DMG before reporting the release URL to the user.
