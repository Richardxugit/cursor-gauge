# Usage Report Audit Fixes Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Fix the six confirmed Usage Report output and interaction defects approved in
`docs/superpowers/specs/2026-11-10-usage-report-audit-fixes-design.md`.

**Architecture:** Small behavioral corrections across `UsageReport`, `ReportExport`,
`ReportRenderer`, `Preferences`, `ActivityCatalog`, `ReportCommand`, and `MenuContent`.
Every change starts with a failing XCTest. No performance work in this plan.

**Tech Stack:** Swift 6, SwiftUI, XCTest. Build/test run on the Mac via
`python3 /workspace/scripts/mac_ssh.py '<cmd>'` from the container; the container has no
Swift toolchain.

---

## Task 1: Stop labeling unknown activity as editor work

**Files:**
- Modify: `Sources/CursorGaugeCore/ActivityCatalog.swift:10-15`
- Modify: `Sources/CursorGaugeCore/UsageReport.swift:224-233`
- Test: `Tests/CursorGaugeCoreTests/UsageReportTests.swift`

**Step 1: Write failing test**

In `UsageReportTests`, add a test that builds a report whose events mix one known GUI chat,
one known CLI chat, one event with no conversation id, and one event whose conversation has
no local activity record. Assert:

```swift
XCTAssertNil(report.bySource[.gui]?.conversations ?? nil) // as the fixture requires
```

More precisely: assert `report.bySource[.gui]!.cents` equals only the known GUI event, and
`report.bySource[.unknown]!.cents` equals the sum of the no-id event and the unknown
conversation event, and `report.bySource[.unknown]!.conversations` equals 1.

**Step 2: Run test to verify failure**

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test --filter UsageReportTests 2>&1 | tail -6'
```

Expected: FAIL — unknown events are folded into `.gui`.

**Step 3: Write minimal implementation**

`ActivityCatalog.swift`:

```swift
public enum ActivitySource: String, Equatable, Codable, Sendable, CaseIterable {
    /// Cursor the editor, recorded in `state.vscdb`.
    case gui
    /// `cursor-agent` in a terminal, recorded under `~/.cursor/chats`.
    case cli
    /// Billed or exported work with no local record, or an event with no conversation id.
    case unknown
}
```

`UsageReport.swift` bySource loop:

```swift
let source = event.conversationID
    .flatMap { activity.byConversation[$0]?.source } ?? .unknown
```

**Step 4: Run test to verify pass** — same filter command; also run
`swift test --filter ReportExportTests` and `--filter ReportRendererTests` afterwards (no
changes expected yet).

**Step 5: Commit**

```bash
git add Sources/CursorGaugeCore/ActivityCatalog.swift Sources/CursorGaugeCore/UsageReport.swift Tests/CursorGaugeCoreTests/UsageReportTests.swift
git commit -m "fix: stop labeling unknown activity as editor work"
```

---

## Task 2: Export unknown source instead of fabricating `gui`

**Files:**
- Modify: `Sources/CursorGaugeCore/ReportExport.swift:169-192`
- Test: `Tests/CursorGaugeCoreTests/ReportExportTests.swift`
- Test: `Tests/CursorGaugeCoreTests/ReportRendererTests.swift`

**Step 1: Write failing tests**

`ReportExportTests`: ledger-only cloud event (no local record, `isCloud: true`) exports a
conversation with `source == .unknown` and `isCloud == true`, and the encoded JSON contains
`"source":"unknown"`.

`ReportRendererTests`: a report with unknown residual spend (bySource `.unknown` > 0, `.gui`
== 0, `.cli` > 0) renders the CLI split line without inventing editor cents — assert the
html does not contain the editor-side amount from unknown events (e.g. no
`Cursor the editor $1.50` for the unknown-only amount).

**Step 2: Run tests to verify failure**

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test --filter ReportExportTests 2>&1 | tail -6 && swift test --filter ReportRendererTests 2>&1 | tail -6'
```

Expected: FAIL — exported source is `gui`.

**Step 3: Write minimal implementation**

In `ReportExport.build`, compute the source once per conversation:

```swift
let source = record?.source ?? .unknown
```

use it for `source:`, and update the doc comment on `Conversation.source` to list
`gui`, `cli`, and `unknown`. No renderer change is needed — it already reads `.gui`/`.cli`
only; the new test locks that in.

**Step 4: Run tests to verify pass** — both filters above.

**Step 5: Commit**

```bash
git add Sources/CursorGaugeCore/ReportExport.swift Tests/CursorGaugeCoreTests/ReportExportTests.swift Tests/CursorGaugeCoreTests/ReportRendererTests.swift
git commit -m "fix: export unknown source instead of fabricating gui"
```

---

## Task 3: Attribute repositories by full path

**Files:**
- Modify: `Sources/CursorGaugeCore/UsageReport.swift:4-16,141-173`
- Modify: `Sources/CursorGaugeCore/ReportRenderer.swift:158-165`
- Modify: `Sources/CursorGaugeCore/ReportExport.swift:67-74,210-213`
- Test: `Tests/CursorGaugeCoreTests/UsageReportTests.swift`
- Test: `Tests/CursorGaugeCoreTests/ReportRendererTests.swift`
- Test: `Tests/CursorGaugeCoreTests/ReportExportTests.swift`

**Step 1: Write failing tests**

- `UsageReportTests`: two `ConversationActivity` records, both `workspace == "website"`,
  `workspacePath` `/clients/a/website` and `/clients/b/website`, each with its own billed
  event. Assert two `WorkspaceSpend` rows with independent cents, sessions, prompts, and
  distinct `workspacePath` values; same-path control still merges.
- `ReportRendererTests`: the duplicate-basename report's HTML contains both full paths.
- `ReportExportTests`: the JSON workspace objects carry `"workspacePath"` values.

**Step 2: Run tests to verify failure**

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test --filter UsageReportTests 2>&1 | tail -6'
```

Expected: FAIL — both chats fold into one `website` row.

**Step 3: Write minimal implementation**

Top of `UsageReport.swift` (file-private identity):

```swift
/// A repository key that cannot confuse two different directories that share a basename,
/// nor a pathless record with a path-carrying one.
private enum WorkspaceIdentity: Hashable {
    case path(String)
    case name(String)
}
```

`WorkspaceSpend`:

```swift
public let workspace: String
/// Full path of the repo directory when the local record carried one.
public let workspacePath: String?

public var id: String { workspacePath ?? "name:\(workspace)" }
```

Attribution loop keeps the existing cloud/unattributed fallthrough for unknown ids or
missing workspace names, and keys the rest:

```swift
var byWorkspace: [WorkspaceIdentity: (cents: Double, sessions: Set<String>, path: String?, name: String)] = [:]
for event in events {
    guard let id = event.conversationID, let record = activity.byConversation[id],
          let workspace = record.workspace else {
        if event.isCloud {
            cloudCents += event.cents
            if let id = event.conversationID { cloudConversations.insert(id) }
        } else {
            unattributedCents += event.cents
        }
        continue
    }
    let identity: WorkspaceIdentity = record.workspacePath.map { .path($0) } ?? .name(workspace)
    var entry = byWorkspace[identity] ?? (0, [], record.workspacePath, workspace)
    entry.cents += event.cents
    entry.sessions.insert(id)
    byWorkspace[identity] = entry
}
```

Row building passes the path through:

```swift
let workspaces = byWorkspace.map { _, entry -> WorkspaceSpend in
    let records = entry.sessions.compactMap { activity.byConversation[$0] }
    return WorkspaceSpend(
        workspace: entry.name,
        workspacePath: entry.path,
        cents: entry.cents,
        sessions: entry.sessions.count,
        prompts: records.reduce(0) { $0 + $1.prompts },
        toolCalls: records.reduce(0) { $0 + $1.toolCalls },
        linesAdded: records.reduce(0) { $0 + $1.linesAdded }
    )
}.sorted { ($0.cents, $1.workspace) > ($1.cents, $0.workspace) }
```

`ReportRenderer.workspaceSection` disambiguates only when a basename appears more than
once (the existing `note` text passes through `bar`'s escaping):

```swift
let duplicateNames = Set(Dictionary(grouping: report.workspaces, by: { $0.workspace })
    .filter { $0.value.count > 1 }.keys)
let rows = report.workspaces.map { repo in
    var note = "\(repo.sessions) chat\(repo.sessions == 1 ? "" : "s") · \(count(repo.toolCalls)) tool calls · \(count(repo.prompts)) prompts"
    if duplicateNames.contains(repo.workspace) {
        note += " · \(repo.workspacePath ?? "distinct paths")"
    }
    return bar(
        label: repo.workspace,
        value: Format.money(cents: repo.cents),
        fraction: divide(repo.cents, report.workspaces.first?.cents),
        note: note
    )
}.joined()
```

`ReportExport.Workspace` gains `public let workspacePath: String?` and the mapping passes
`workspacePath: $0.workspacePath`.

**Step 4: Run tests to verify pass** — all three filters.

**Step 5: Commit**

```bash
git add Sources/CursorGaugeCore/UsageReport.swift Sources/CursorGaugeCore/ReportRenderer.swift Sources/CursorGaugeCore/ReportExport.swift Tests/CursorGaugeCoreTests/UsageReportTests.swift Tests/CursorGaugeCoreTests/ReportRendererTests.swift Tests/CursorGaugeCoreTests/ReportExportTests.swift
git commit -m "fix: attribute repositories by full path"
```

---

## Task 4: Count zero-cost chats as free of charge

**Files:**
- Modify: `Sources/CursorGaugeCore/UsageReport.swift:242-245`
- Test: `Tests/CursorGaugeCoreTests/UsageReportTests.swift`

**Step 1: Write failing test**

Fixture: active conversation `c1` (prompts > 0) whose only event has `cents == 0`, plus a
control conversation `c2` with a 50-cent event. Assert `unbilledConversations == 1`,
`totalCents == 50`, and `ledger` contains `c1` with 0 cents.

**Step 2: Run to verify failure**

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test --filter UsageReportTests 2>&1 | tail -6'
```

Expected: FAIL — `unbilledConversations == 0`.

**Step 3: Write minimal implementation**

Reuse the per-conversation ledger already built above:

```swift
let billed = Set(perConversation.filter { $0.value.cents != 0 }.keys)
```

**Step 4: Run to verify pass** — same filter.

**Step 5: Commit**

```bash
git add Sources/CursorGaugeCore/UsageReport.swift Tests/CursorGaugeCoreTests/UsageReportTests.swift
git commit -m "fix: count zero-cost chats as free of charge"
```

---

## Task 5: Share team selection between app and CLI

**Files:**
- Modify: `Sources/CursorGauge/Preferences.swift:46-63`
- Create: `Tests/CursorGaugeTests/PreferencesTests.swift`

**Step 1: Write failing test**

`PreferencesTests` with `@testable import CursorGauge`:

```swift
func testAppBundleResolvesStandardDefaults() {
    let standard = UserDefaults(suiteName: "cursor-gauge-tests.standard")!
    let application = UserDefaults(suiteName: "cursor-gauge-tests.application")!
    let resolved = Preferences.defaultStore(
        bundleIdentifier: Preferences.applicationBundleIdentifier,
        standard: standard, application: application
    )
    XCTAssertTrue(resolved === standard)
}

func testUnbundledProcessResolvesApplicationDomain() {
    let standard = UserDefaults(suiteName: "cursor-gauge-tests.standard")!
    let application = UserDefaults(suiteName: "cursor-gauge-tests.application")!
    let resolved = Preferences.defaultStore(bundleIdentifier: nil, standard: standard, application: application)
    XCTAssertTrue(resolved === application)
}

func testUnbundledFallsBackToStandardWhenApplicationDomainMissing() {
    let standard = UserDefaults(suiteName: "cursor-gauge-tests.standard")!
    XCTAssertTrue(Preferences.defaultStore(bundleIdentifier: nil, standard: standard, application: nil) === standard)
}
```

Clean up the suites in `tearDown` with `removePersistentDomain(forName:)`.

**Step 2: Run to verify failure**

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test --filter PreferencesTests 2>&1 | tail -6'
```

Expected: compile failure — `defaultStore` does not exist (compiled-language scaffolding red).

**Step 3: Write minimal implementation**

```swift
/// The installed app's bundle identifier. The CLI has no bundle, so it must resolve the
/// app's domain explicitly to share the menu's team selection.
static let applicationBundleIdentifier = "com.pxu.cursorgauge"

init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Preferences.defaultStore()
    // existing reads unchanged
}

static func defaultStore(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    standard: UserDefaults = .standard,
    application: UserDefaults? = UserDefaults(suiteName: applicationBundleIdentifier)
) -> UserDefaults {
    if bundleIdentifier == applicationBundleIdentifier { return standard }
    return application ?? standard
}
```

Existing `Preferences()` call sites (app, `--report`, `--dry-run`) are unchanged.

**Step 4: Run to verify pass** — `--filter PreferencesTests` plus `--filter ReportCommandTests`
and `--filter DryRunTests`.

**Step 5: Commit**

```bash
git add Sources/CursorGauge/Preferences.swift Tests/CursorGaugeTests/PreferencesTests.swift
git commit -m "fix: share team selection between app and CLI"
```

---

## Task 6: State prompt-text export coverage

**Files:**
- Modify: `Sources/CursorGaugeCore/ActivityCatalog.swift:575-595`
- Modify: `Sources/CursorGaugeCore/ReportExport.swift:24-36,146-147,152-159,169-192,240-251`
- Modify: `Sources/CursorGauge/ReportCommand.swift:69-81`
- Test: `Tests/CursorGaugeCoreTests/ActivityCatalogTests.swift`
- Test: `Tests/CursorGaugeCoreTests/ReportExportTests.swift`
- Test: `Tests/CursorGaugeTests/ReportCommandTests.swift`

**Step 1: Write failing tests**

- `ActivityCatalogTests`: existing `promptText(since:)` call sites switch to
  `.promptText(since:).texts`; add: missing database file returns `unavailable == false`
  with empty texts; an existing non-SQLite file returns `unavailable == true`.
- `ReportExportTests`: with `promptTextCoverage` passed, the encoded JSON contains
  `"promptTextCoverage":{"gui":"complete","cli":"unsupported"}`; without it the string
  `promptTextCoverage` is absent; an opted-in CLI conversation has `promptText == nil`
  while an opted-in GUI conversation without text has `[]`; a `gui:"unavailable"`
  coverage is preserved.
- `ReportCommandTests`: a `write` with JSON + prompts passes coverage into the exported
  file (decode the written JSON and assert `promptTextCoverage`).

**Step 2: Run to verify failure**

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test --filter ReportExportTests 2>&1 | tail -6'
```

Expected: compile failure — `PromptTextCoverage` does not exist.

**Step 3: Write minimal implementation**

`ActivityCatalog.swift`:

```swift
/// The prompts themselves, by conversation, plus whether the read completed.
public struct PromptTextResult {
    public let texts: [String: [String]]
    /// True when the store exists but the prompt read did not run to completion.
    public let unavailable: Bool
}

public func promptText(since: Date) -> PromptTextResult {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
        return PromptTextResult(texts: [:], unavailable: false)
    }
    guard let database = ReadOnlyDatabase(url: databaseURL) else {
        return PromptTextResult(texts: [:], unavailable: true)
    }
    var found: [String: [String]] = [:]
    database.query(/* existing SQL */) { row in
        /* existing consumption */
    }
    return PromptTextResult(texts: found, unavailable: database.hadQueryFailure)
}
```

`ReportExport.swift`:

```swift
public struct PromptTextCoverage: Encodable {
    /// `complete` or `unavailable` for the editor store.
    public let gui: String
    /// Always `unsupported`: this export does not claim to recover CLI prompt text.
    public let cli: String
}
```

- ReportExport property: `public let promptTextCoverage: PromptTextCoverage?` after
  `includesPromptText`, documented as present only when export was requested.
- `build` parameter: `promptTextCoverage: PromptTextCoverage? = nil` before `timeZone`.
- Conversation mapping: capture `let source = record?.source ?? .unknown` and set

```swift
promptText: promptText == nil ? nil : (source == .gui ? promptText?[id] ?? [] : nil)
```

- Pass `promptTextCoverage: promptTextCoverage` in the final initializer.

`ReportCommand.swift` JSON branch:

```swift
case .json(let withPromptText):
    let promptResult = withPromptText ? catalog.promptText(since: snapshot.cycleStart) : nil
    contents = try ReportExport.build(
        report: report,
        activity: activity,
        promptText: promptResult?.texts,
        promptTextCoverage: withPromptText
            ? PromptTextCoverage(
                gui: promptResult?.unavailable == true ? "unavailable" : "complete",
                cli: "unsupported"
            )
            : nil
    ).json()
```

**Step 4: Run to verify pass** — the three filters above.

**Step 5: Commit**

```bash
git add Sources/CursorGaugeCore/ActivityCatalog.swift Sources/CursorGaugeCore/ReportExport.swift Sources/CursorGauge/ReportCommand.swift Tests/CursorGaugeCoreTests/ActivityCatalogTests.swift Tests/CursorGaugeCoreTests/ReportExportTests.swift Tests/CursorGaugeTests/ReportCommandTests.swift
git commit -m "fix: state prompt export coverage honestly"
```

---

## Task 7: Surface report open failures

**Files:**
- Modify: `Sources/CursorGauge/ReportCommand.swift:87-116`
- Modify: `Sources/CursorGauge/MenuContent.swift:445-453`
- Test: `Tests/CursorGaugeTests/ReportCommandTests.swift`

**Step 1: Write failing test**

```swift
func testOpenReturnsOpenerResult() {
    var recorded: [URL] = []
    let url = URL(fileURLWithPath: "/tmp/report.html")
    XCTAssertTrue(ReportCommand.open(url) { recorded.append($0); return true })
    XCTAssertFalse(ReportCommand.open(url) { recorded.append($0); return false })
    XCTAssertEqual(recorded, [url, url])
}
```

**Step 2: Run to verify failure**

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test --filter ReportCommandTests 2>&1 | tail -6'
```

Expected: compile failure — `open` does not exist.

**Step 3: Write minimal implementation**

```swift
/// Opens the written report, reporting whether the opener succeeded.
static func open(_ url: URL, using opener: (URL) -> Bool = NSWorkspace.shared.open) -> Bool {
    opener(url)
}
```

In `run`, keep the printed path, then:

```swift
if case .html = format, !open(written) {
    FileHandle.standardError.write(Data("error: report written to \(written.path) but could not be opened\n".utf8))
    exitCode = 1
}
```

`MenuContent.buildReport`:

```swift
let written = try await ReportCommand.write(
    to: ReportCommand.defaultDestination(),
    preferredTeamID: preferences.selectedTeamID
)
if !ReportCommand.open(written) {
    reportError = "The report was written to \(written.path) but could not be opened."
}
```

**Step 4: Run to verify pass** — `--filter ReportCommandTests`.

**Step 5: Commit**

```bash
git add Sources/CursorGauge/ReportCommand.swift Sources/CursorGauge/MenuContent.swift Tests/CursorGaugeTests/ReportCommandTests.swift
git commit -m "fix: surface report open failures"
```

---

## Task 8: Documentation and full verification

**Files:**
- Modify: `README.md` — team selection now shared with CLI reports and `--dry-run`;
  `--with-prompts` coverage semantics; `unknown` source; repository path identity; free of
  charge includes zero-cent billed chats; open-failure handling.

**Steps:**

1. Update README sections to match implemented behavior.
2. Full Mac verification:

```bash
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift test > /tmp/cg-final.log 2>&1; rc=$?; grep -E "Executed [0-9]+ tests" /tmp/cg-final.log | tail -2; echo REMOTE_EXIT=$rc; exit $rc'
python3 /workspace/scripts/mac_ssh.py 'cd ~/Documents/HermesSandbox/workspace/cursor-gauge && swift build -c release'
git diff --check
git status --porcelain
```

Expected: all tests pass (previous baseline 263, plus new ones), release build succeeds,
clean worktree.

3. Commit:

```bash
git add README.md
git commit -m "docs: document report audit fixes"
```

---

## Cross-cutting notes

- `swift test` inside one repository must not run concurrently from two terminals; the
  three reviewers run sequentially.
- All commits group implementation with its tests; messages follow the project's
  short-and-meaningful convention.
- Do not touch polling, refresh cadence, team discovery, or performance paths.
