# Usage Report Audit Fixes Design

Status: approved for implementation on 2026-11-10.

## Scope

Fix the six confirmed Usage Report output and interaction defects from the read-only audit.
Do not change polling, team discovery, refresh cadence, report styling, or performance in
this work item. Performance findings remain measurement-only follow-ups.

## 1. Unknown activity is not editor activity

`ActivitySource` gains an explicit `unknown` case. Billing events whose conversation has no
local activity record, and events with no conversation id, accumulate under `unknown` in
`UsageReport.bySource`; they must not increment GUI cents or conversation counts.

The HTML editor/CLI split continues to display known GUI and CLI figures only. Cloud and
unattributed residuals remain in their existing buckets and are not relabelled as editor
work. A ledger-only or cloud conversation without a local record exports `source:
"unknown"`, including when `isCloud` is true.

The report schema remains `cursor-gauge/report/1`; `unknown` is a newly documented source
value rather than a fabricated `gui` fallback.

## 2. Repository identity uses the full path

Usage attribution keys repositories by `ConversationActivity.workspacePath` when present.
The basename is a display label, not an identity. Two chats at `/clients/a/website` and
`/clients/b/website` therefore produce separate rows with independent cost and activity.
Chats at the same full path continue to merge.

`WorkspaceSpend` and the JSON workspace object retain both `workspace` (the basename) and an
optional `workspacePath`. Their stable identity is the full path when available. Records
without a path fall back to a name-scoped identity and cannot collide with a path-scoped
record. When duplicate basenames are rendered, the HTML row includes the full path so the
rows are visibly distinguishable; unique names retain the existing compact presentation.

## 3. Zero-cost conversations count as free

A locally active conversation is free of charge when its ledger total is zero, including
when zero-cent billing events are present. Presence of any event no longer makes a
conversation billed. Positive-cost controls remain billed, and free conversations continue
to add no spend. Reuse the already-built per-conversation ledger rather than adding another
event aggregation.

## 4. App and CLI share team selection

`Preferences` resolves its default store from the application bundle identifier
`com.pxu.cursorgauge`:

- In the installed app bundle, use `UserDefaults.standard` as before.
- In `swift run` or another unbundled CLI process, use
  `UserDefaults(suiteName: "com.pxu.cursorgauge")` so reports and `--dry-run` read the same
  persisted team selection as the app.
- Injected `UserDefaults` remain unchanged for tests. If suite creation unexpectedly fails,
  retain the existing standard-defaults fallback.

Existing app settings require no migration because the app's standard domain already uses
this identifier. Selection semantics remain explicit team first, otherwise Auto; discovery
still considers all teams. Tests must cover the bundle-vs-CLI resolver itself in addition to
the existing downstream request propagation tests. Native process verification is reported
separately from unit evidence.

## 5. Prompt-text export states its coverage

The default report remains content-free. Prompt text is read only for an explicit JSON
`--with-prompts` request.

When requested, the export adds `promptTextCoverage`:

- `gui: "complete"`: the editor prompt query ran to completion, including a valid empty
  result.
- `gui: "unavailable"`: an existing editor store could not be opened or its prompt query
  failed; any text already read is retained, but the export is explicitly incomplete.
- `cli: "unsupported"`: this export does not claim to recover CLI prompt text. Encrypted or
  otherwise opaque CLI blobs are never decrypted or fabricated.

When prompt export is not requested, `promptTextCoverage` is absent and existing
`includesPromptText: false` behavior is unchanged. A missing editor database is readable
empty, consistent with activity availability. For an opted-in CLI conversation,
`promptText` is absent rather than an empty array that would falsely mean "known to have no
text." Editor conversations retain their existing array behavior. Documentation states
these limits instead of claiming that every prompt was exported.

## 6. Browser-open failure is visible

Wrap report opening in a small injectable `ReportCommand` helper that returns the opener's
Boolean result. Production uses `NSWorkspace.shared.open`; tests use a recording closure.

The menu treats `false` as `reportError` and clears its busy state through the existing
`defer`. The CLI prints the written path as before, emits a visible error for an open
failure, and exits nonzero because the requested report interaction did not complete. A
successfully written report is never deleted or misreported as unwritten. JSON export keeps
its existing no-open behavior.

## Testing and verification

Each behavioral change starts with a focused XCTest that fails for the stated reason, then
the minimal implementation, focused green, and full-suite green. New API scaffolding is
separated from behavioral red where required by compiled-language TDD.

Required fixtures:

- Known GUI + known CLI + cloud + unattributed events, asserting source totals, HTML split,
  and JSON source.
- Same-basename/different-path repositories plus same-path controls, asserting independent
  aggregates and visible paths.
- Active conversations with zero-cent events and positive-cost controls.
- Bundle and unbundled preference resolution without touching real user defaults.
- Prompt coverage for complete, empty, failed, and unsupported sources, with prompt privacy
  unchanged by default.
- Recording openers for success and failure at both interaction call sites.

Finish on the Mac with the complete `swift test`, `swift build -c release`, `git diff
--check`, and a clean worktree. Real Cursor account/browser behavior remains a native
validation limit because the audit environment has no Cursor installation or credentials.

## Non-goals

- No CLI plaintext prompt extraction or encryption work.
- No performance optimization or new benchmarks in this item.
- No argument-parser redesign, filename-collision change, or report visual redesign.
- No schema-version change; new fields and the `unknown` value are documented additive
  corrections.
