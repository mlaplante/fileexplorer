# V6 M3 — Disk Usage Analyzer + Duplicate Finder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two folder tools — Analyze Disk Usage (ranked size bars with drill-down and trash) and Find Duplicates (size+SHA-256 groups with keep strategies) — composing the existing `FolderSizer`/`FileHasher` posture into sheets.

**Architecture:** Core engines are `@MainActor @Observable` models doing their enumeration/hashing off-actor (`Task.detached`) and publishing incremental results back on the main actor with generation guards (DirectoryLoader posture). Ranking and keep-strategy math are pure enums. Sheets follow the `SyncPreviewSheet`/`BatchRenameSheet` presentation pattern; destructive actions route through the existing PaneState trash path so undo + Put Back apply.

**Tech Stack:** Swift 6, SwiftUI, SPM, CLT-only. Spec: `docs/superpowers/specs/2026-07-09-disk-usage-duplicates-design.md`. Branch: `v6-disk-usage-duplicates` off main (after M2 merges).

---

## HARD TOOLCHAIN CONSTRAINTS (read first)

- **No Xcode — CLT only.** `swift build`; NEVER `xcodebuild` or `swift test`.
- **`@State`/`@FocusState` DO NOT COMPILE.** Sheet visibility/selection state lives on `@Observable` models.
- Tests: `swift run FileExplorerTests`; register suites in `Sources/FileExplorerTests/main.swift`; redirect output to a file and read it.
- Swift 6 strict concurrency: detached scan tasks capture only Sendable values; publish via `Task { @MainActor in … }` or `MainActor.run`.
- Async tests poll with deadline loops (see SpringLoadModel tests), never fixed sleeps.
- Commit after each task. Do not push.

### Task 1: UsageRanking (pure rows + proportions)

**Files:**
- Create: `Sources/FileExplorerCore/UsageRanking.swift`
- Test: `Sources/FileExplorerTests/UsageRankingTests.swift`, register `await usageRankingTests()`

- [ ] **Step 1: Failing tests** —

```swift
public struct UsageRow: Equatable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let bytes: Int64
    public let itemCount: Int      // files under this child (1 for a file row)
    public let proportion: Double  // 0…1 of the LARGEST child
    public var id: URL { url }
}
public enum UsageRanking {
    public static func rows(childTotals: [URL: (bytes: Int64, items: Int, isDirectory: Bool)]) -> [UsageRow]
    public static func subtracting(_ url: URL, bytes: Int64, from rows: [UsageRow]) -> [UsageRow]
}
```

  Assert: (a) sort by bytes descending, ties broken by localized name ascending; (b) proportion = bytes / max child bytes, max row = 1.0; all-zero children → proportions all 0 (no divide-by-zero); (c) file rows carry isDirectory false, itemCount 1; (d) `subtracting` removes the row for a trashed URL and rescales the remaining proportions.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: UsageRanking pure row math`

### Task 2: UsageScanner (incremental child totals)

**Files:**
- Create: `Sources/FileExplorerCore/UsageScanner.swift`
- Test: `Sources/FileExplorerTests/UsageScannerTests.swift`, register `await usageScannerTests()`

- [ ] **Step 1: Failing tests** — real temp trees (helper writing files with known byte counts):

```swift
@MainActor @Observable public final class UsageScanner {
    public private(set) var rows: [UsageRow] = []
    public private(set) var totalBytes: Int64 = 0
    public private(set) var isScanning = false
    public private(set) var isPartial = false      // hit entryCap
    public static let entryCap = 250_000
    public func scan(root: URL)                     // cancels any prior scan
    public func cancel()
}
```

  Assert: (a) `root/a/deep/file(100B)` + `root/a/x(50B)` + `root/b(10B)` + `root/f.txt(5B)` → rows: a=150B/2 items, b=10B/1, f.txt=5B/1, ordered a,b,f.txt; totalBytes 165; (b) hidden dotfile bytes counted; (c) symlink to a big file contributes 0 (not followed — enumerate with no `.skipsHiddenFiles`, symlinks yield their own tiny size only; assert the target's bytes are NOT attributed); (d) unreadable subfolder (chmod 0o000, restore in defer) skipped, sibling totals intact; (e) `scan` twice quickly → results reflect the second root only (generation guard); (f) `cancel()` mid-scan of a large synthetic tree (a few thousand tiny files) stops publication: rows stop changing and `isScanning` flips false; (g) entryCap exercised with a test-only seam `scan(root:cap:)` — cap 10 on a 50-file tree → `isPartial` true.
  Implementation notes: single `FileManager.enumerator` pass; attribute each visited URL's bytes to the immediate child of `root` on its path (compute via path-prefix match against the enumeration root — reuse the standardized-path convention); publish rows every 200 entries and at completion via `UsageRanking.rows`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: UsageScanner incremental folder usage`

### Task 3: DuplicateKeepPlanner (pure keep math)

**Files:**
- Create: `Sources/FileExplorerCore/DuplicateKeepPlanner.swift`
- Test: `Sources/FileExplorerTests/DuplicateKeepPlannerTests.swift`, register `await duplicateKeepPlannerTests()`

- [ ] **Step 1: Failing tests** —

```swift
public struct DuplicateGroup: Equatable, Identifiable, Sendable {
    public let hash: String
    public let size: Int64
    public let members: [DuplicateMember]           // sorted modified desc
    public var id: String { hash }
    public var wastedBytes: Int64 { size * Int64(members.count - 1) }
}
public struct DuplicateMember: Equatable, Sendable {
    public let url: URL
    public let modified: Date
}
public enum KeepStrategy: Equatable, Sendable { case newest, oldest, custom(keep: Set<URL>) }
public enum DuplicateKeepPlanner {
    /// URLs to trash, or nil when the strategy would empty the group.
    public static func trashPlan(group: DuplicateGroup, strategy: KeepStrategy) -> [URL]?
    public static func combinedPlan(_ selections: [(DuplicateGroup, KeepStrategy)]) -> [URL]
}
```

  Assert: (a) newest keeps max-modified, trashes rest (fixture dates); (b) oldest inverse; (c) modified ties broken by path ascending so the plan is deterministic; (d) custom keeps exactly the checked set; (e) custom with empty keep set → nil; custom keeping everything → `[]`; (f) combinedPlan concatenates, skipping nil groups.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: DuplicateKeepPlanner keep-strategy math`

### Task 4: DuplicateFinder (size → hash two-stage scan)

**Files:**
- Create: `Sources/FileExplorerCore/DuplicateFinder.swift`
- Test: `Sources/FileExplorerTests/DuplicateFinderTests.swift`, register `await duplicateFinderTests()`

- [ ] **Step 1: Failing tests** — real temp trees:

```swift
@MainActor @Observable public final class DuplicateFinder {
    public private(set) var groups: [DuplicateGroup] = []   // wastedBytes desc
    public private(set) var isScanning = false
    public private(set) var isPartial = false
    public private(set) var scannedFileCount = 0
    public static let fileCap = 100_000
    public func scan(root: URL)
    public func cancel()
}
```

  Assert: (a) two identical 1 KB files in different subfolders → one group, members sorted modified desc; (b) same-size different-content files → no group; (c) 0-byte files never grouped; symlink to a member not counted twice; (d) three groups rank by wastedBytes desc (make sizes/counts differ); (e) unreadable file (chmod 0o000) silently dropped, its size-mate ungrouped; (f) cancel mid-scan stops publication; second `scan` supersedes the first (generation guard); (g) cap via test seam `scan(root:cap:)` → `isPartial`.
  Implementation: stage 1 enumerate regular files collecting `[Int64: [URL]]`; stage 2 for sizes with ≥2 URLs run `FileHasher.sha256` (off-actor, sequential is fine — hashing already streams); build groups where a hash repeats. Publish groups once per completed size-bucket so big scans fill in progressively.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: DuplicateFinder two-stage duplicate scan`

### Task 5: Trash integration (undo + Put Back through the pane path)

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift` (public entry to trash an explicit URL list — check whether `trashSelected`'s core is reusable; if it already factors into a `trash(urls:)` helper, expose that; otherwise extract it without changing `trashSelected` behavior)
- Test: extend `Sources/FileExplorerTests/PaneBatchToolsTests.swift` (or a new `UsageTrashTests.swift` if cleaner), register accordingly

- [ ] **Step 1: Failing tests** — `pane.trash(urls:)` on temp files: (a) files land in trash, originals gone; (b) undo restores them (UndoRecorder pairs registered); (c) TrashRegistry has Put Back records; (d) a URL that fails (already deleted) surfaces through the existing failure posture (`errorMessage`/`OperationFailureSummary` — match whatever `trashSelected` does) without aborting the rest.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement the minimal extraction. **Step 4:** Run → PASS. **Step 5:** Commit: `refactor: reusable pane trash(urls:) entry point`

### Task 6: UsageSheet + DuplicatesSheet + wiring

**Files:**
- Create: `Sources/FileExplorer/UsageSheet.swift`, `Sources/FileExplorer/DuplicatesSheet.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift` (Tools/File menu: "Analyze Disk Usage…", "Find Duplicates…" acting on the active pane's folder; sheet presentation models owned app-lifetime like SyncPreviewModel — read how `SyncPreviewSheet` presents first and copy that shape), `Sources/FileExplorer/FileActionsMenu.swift` (folder context: both commands on a single selected folder, targeting it), `Sources/FileExplorer/PaletteCoordinator.swift` (palette entries)
- Test: none new (view layer); full suite stays green

- [ ] **Step 1: UsageSheet** — header: scanned path + running total + spinner while `isScanning` + "partial results" footnote when `isPartial`. Rows (plain `List`): name, `GeometryReader`-free proportion bar (a `Rectangle` in an `.overlay` sized by `proportion` × fixed bar width, tinted `.tint`), human size (reuse the app's existing `ByteCountFormatter` usage — grep for it and use the same style), item count. Folder rows: click drills down (`scanner.scan(root: row.url)` + breadcrumb push; breadcrumb entries re-scan upward). Row context menu / trailing buttons: "Reveal in Pane" (navigate active pane to parent, select item, dismiss sheet), "Move to Trash" (pane.trash(urls:[url]) then `UsageRanking.subtracting`). Cancel scan on dismiss.
- [ ] **Step 2: DuplicatesSheet** — while scanning: progress ("N files scanned") + incremental groups. Each group: header (size × count, wasted bytes), segmented picker Newest/Oldest/Custom bound to a per-group strategy dictionary on the sheet's model, member rows (relative path, modified date; checkboxes only in Custom mode). Footer: total reclaimable bytes for current selections + "Move N to Trash" button (disabled at 0 or while any group's custom keep-set is empty — planner returns nil) → `DuplicateKeepPlanner.combinedPlan` → `pane.trash(urls:)` → dismiss. Empty result state: "No duplicates found."
- [ ] **Step 3: Wiring** — menu items disabled when the active pane has no folder (shouldn't happen — mirror how Compare Panes guards); folder context menu targets the clicked folder. Palette entries route the same handlers.
- [ ] **Step 4:** `swift build` clean; full tests PASS; `swift run FileExplorer` — analyze this repo's folder (`.build` should dominate), find duplicates in a test folder.
- [ ] **Step 5:** Commit: `feat: disk usage and duplicates sheets wired to menus and palette`

### Task 7: README + walkthrough notes

- [ ] README: bullets for both tools (scope = current folder, caps, undo-able trash).
- [ ] Full suite PASS; `./Scripts/bundle.sh` builds.
- [ ] Commit: `docs: disk usage and duplicate finder notes`. Manual walkthrough: big-folder scan feel, cancel responsiveness, drill-down breadcrumbs, duplicate trash → Put Back.
