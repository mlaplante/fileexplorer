# V6 M2 — Git Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Git awareness in every pane — status-badge dots on rows/cells, branch + change count in the status bar, dimmed gitignored entries with a persisted "Hide ignored" filter toggle.

**Architecture:** Pure Core first: `GitStatusParser` (porcelain-v2 → `GitRepoStatus`), `GitStatusIndex` (path lookup + folder aggregation), `GitRepoLocator` (ancestor `.git` walk). A `@MainActor @Observable` `GitStatusModel` per pane runs `/usr/bin/git status --porcelain=v2 --branch --ignored=matching -z` detached, debounced off the pane's existing reload/watcher events, with a generation counter against stale results. Views do pure lookups.

**Tech Stack:** Swift 6, SwiftUI, SPM, CLT-only toolchain. Spec: `docs/superpowers/specs/2026-07-09-git-integration-design.md`. Branch: `v6-git-integration` off main (after M1 merges).

---

## HARD TOOLCHAIN CONSTRAINTS (read first)

- **No Xcode — CLT only.** `swift build`; NEVER `xcodebuild` or `swift test`.
- **`@State`/`@FocusState` DO NOT COMPILE.** Transient UI state lives on `@Observable` models.
- Tests: `swift run FileExplorerTests` — exit 0 + `PASS (N assertions)`; register suites in `Sources/FileExplorerTests/main.swift`.
- Redirect test output to a file and read it (`swift run FileExplorerTests > /tmp/fx-m2-tests.log 2>&1; tail -5 /tmp/fx-m2-tests.log`).
- Swift 6 strict concurrency: hop subprocess results to the main actor; no non-Sendable captures in detached tasks.
- Integration tests may shell out to real `git` (`/usr/bin/git`) in temp dirs — set `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`, and `-c user.name=t -c user.email=t@t -c commit.gpgsign=false` on every command so host git config can't break tests.
- Commit after each task. Do not push.

### Task 1: GitStatusParser (pure porcelain-v2 parsing)

**Files:**
- Create: `Sources/FileExplorerCore/GitStatusParser.swift`
- Test: `Sources/FileExplorerTests/GitStatusParserTests.swift`, register `await gitStatusParserTests()`

- [ ] **Step 1: Failing tests** — build fixture porcelain-v2 output as `Data` (NUL-separated: `-z` terminates records with NUL; renamed entries carry a second NUL-separated path). Public surface:

```swift
public enum GitFileState: Int, Comparable, Sendable {
    case clean = 0, ignored = 1, untracked = 2, modified = 3, staged = 4, conflicted = 5
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}
public struct GitRepoStatus: Equatable, Sendable {
    public var branch: String?          // nil when detached
    public var detachedOID: String?     // short OID when detached
    public var states: [String: GitFileState]  // repo-relative path → state (no clean entries)
    public var ignored: Set<String>     // repo-relative ignored paths
    public var changedCount: Int        // non-ignored changed paths
}
public enum GitStatusParser {
    public static let outputCap = 2 * 1024 * 1024
    public static func parse(_ data: Data) -> GitRepoStatus
}
```

  Assert: (a) `# branch.head main` → branch "main"; `# branch.head (detached)` + `# branch.oid abc123…` → branch nil, detachedOID first 7 chars; (b) ordinary records `1 .M …` → `.modified`, `1 M. …` → `.staged`, `1 MM …` → `.staged` (index change wins per spec priority), `u …` → `.conflicted`, `? path` → `.untracked`, `! path` → `.ignored` (into `ignored`, not `states`); (c) renamed record `2 R. … <newpath>NUL<origpath>` → newpath `.staged`, origpath absent; (d) `changedCount` counts `states` entries only; (e) empty input → empty status; (f) input larger than `outputCap` → parse only the first cap bytes truncated at the last complete NUL record, branch header still parsed (put it first in the fixture); (g) paths containing spaces and UTF-8 survive.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (split on NUL, dispatch on first field; porcelain-v2 ordinary record layout: `1 XY sub mH mI mW hH hI path`; states: X=index char, Y=worktree char; submodule `sub != "N..."` with any change → `.modified` unless index char sets staged). **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: GitStatusParser porcelain-v2 parsing`

### Task 2: GitStatusIndex (lookup + folder aggregation)

**Files:**
- Create: `Sources/FileExplorerCore/GitStatusIndex.swift`
- Test: `Sources/FileExplorerTests/GitStatusIndexTests.swift`, register `await gitStatusIndexTests()`

- [ ] **Step 1: Failing tests** — built from a `GitRepoStatus` + repo root URL:

```swift
public struct GitStatusIndex: Sendable {
    public init(status: GitRepoStatus, repoRoot: URL)
    public func state(for url: URL) -> GitFileState          // files: direct; dirs: aggregate
    public func isIgnored(_ url: URL) -> Bool                // true for ignored paths AND descendants of ignored dirs
    public var branchLabel: String?                          // "main" / "detached abc1234"
    public var changedCount: Int
}
```

  Assert: (a) file lookups map through repo-relative paths (`url.standardizedFileURL.path` minus root path — trailing-slash safe: reuse the standardized-path-string convention from TreeFlattener); (b) folder aggregation returns the max-priority state among descendants (`Comparable` on `GitFileState`), `.clean` when none; (c) repo root URL itself aggregates everything; (d) URL outside the repo → `.clean`, `isIgnored` false; (e) `isIgnored` true for `build/obj.o` when `build/` is in the ignored set (porcelain reports the directory once); (f) aggregation ignores `.ignored` entries.
  Implementation note: precompute in init a directory-aggregate dictionary by walking each state path's ancestor chain once (O(paths × depth)), so `state(for:)` is O(1) — panes call it per visible row.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: GitStatusIndex path lookup and folder aggregation`

### Task 3: GitRepoLocator (ancestor walk)

**Files:**
- Create: `Sources/FileExplorerCore/GitRepoLocator.swift`
- Test: `Sources/FileExplorerTests/GitRepoLocatorTests.swift`, register `await gitRepoLocatorTests()`

- [ ] **Step 1: Failing tests** — `GitRepoLocator.repoRoot(containing url: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL?`: (a) folder with `.git` dir → itself (drive with injected closure AND a real temp dir + `git init`); (b) deep descendant → the ancestor root; (c) `.git` **file** (worktree pattern) → found (fileExists doesn't distinguish); (d) no repo all the way up → nil, and the walk terminates at "/" (guard against the `deletingLastPathComponent` root infinite loop — stop when `path == "/"`); (e) result standardized.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: GitRepoLocator ancestor discovery`

### Task 4: GitStatusModel (subprocess + debounce + generation guard)

**Files:**
- Create: `Sources/FileExplorerCore/GitStatusModel.swift` (Foundation-only — Core so the test target sees it; confirm the tests target imports Core only, as in M1)
- Test: `Sources/FileExplorerTests/GitStatusModelTests.swift`, register `await gitStatusModelTests()`

- [ ] **Step 1: Failing tests** — real temp repos (helper `makeRepo()` runs `git init -q`, config-isolated per the constraints header, initial commit). `@MainActor @Observable public final class GitStatusModel`:

```swift
public private(set) var index: GitStatusIndex?   // nil = not a repo / not loaded
public var isInRepo: Bool { index != nil }
public func refresh(for folder: URL, debounce: Duration = .milliseconds(250))
public func refreshNow(for folder: URL) async     // test seam, no debounce
```

  Assert: (a) non-repo temp folder → `refreshNow` leaves `index` nil; (b) repo with one modified + one untracked + one staged + one committed-clean file → states via `index?.state(for:)` match (.modified/.untracked/.staged/.clean); (c) `.gitignore` containing `build/` + created `build/x.o` → `isIgnored(build dir URL)` true; (d) branchLabel "main" (init with `-b main` to pin) and changedCount correct; (e) two `refresh` calls 10 ms apart with a 50 ms debounce → exactly one subprocess run (count via a run-counter seam: inject `runner: (URL) async -> Data?` closure defaulting to the real subprocess — tests stub it); (f) results for a superseded folder are discarded (navigate A → slow stub → navigate B; A's late data never lands) via generation counter.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement: injectable `runner` closure; default runner = `Process` on `/usr/bin/git` with args `["-C", root.path, "status", "--porcelain=v2", "--branch", "--ignored=matching", "-z"]`, stdout collected to `Data` capped at `GitStatusParser.outputCap`, nonzero exit/missing binary → nil. Repo discovery via `GitRepoLocator` cached `[String: URL?]` by folder path. Debounce: store a pending `Task` (sleep + run), cancel-and-replace on re-entry. Generation counter incremented per `refresh*` call; compare before publishing.
- [ ] **Step 4:** Run → PASS (poll with deadline loops, not fixed sleeps). **Step 5:** Commit: `feat: GitStatusModel debounced git status subprocess`

### Task 5: FilterState.hideGitIgnored + PaneState wiring

**Files:**
- Modify: `Sources/FileExplorerCore/FilterState.swift`, `Sources/FileExplorerCore/PaneState.swift`
- Test: extend `Sources/FileExplorerTests/PaneFilterTests.swift` + `Sources/FileExplorerTests/SessionSnapshotTests.swift`

- [ ] **Step 1: Failing tests** — (a) `FilterState` gains `public var hideGitIgnored: Bool?`; include it in `isActive` (non-nil-true counts as active); JSON without the key decodes nil (synthesized Codable — same contract as `tags`; add the decode-literal test); round-trip preserves true. (b) `PaneState` owns a `public let gitStatus = GitStatusModel()`; after `refreshNow` in a temp repo with an ignored file, setting `filter.hideGitIgnored = true` removes the ignored entry from `visibleEntries` while a clean file stays; toggling back restores. (c) With no repo, the toggle is a no-op (nothing filtered).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement: in `recomputeVisible()` (read it first — apply wherever FilterEngine output lands), when `filter.hideGitIgnored == true && gitStatus.index != nil`, drop entries where `gitStatus.index!.isIgnored(entry.url)`. Hook refresh: in `navigate(to:)` and `reload()` call `gitStatus.refresh(for: currentFolder)`; in the watcher callback (find where the existing `DirectoryWatcher` triggers reload around line 383) the reload path already re-enters → no extra hook. After `gitStatus` publishes (its `refreshNow`/debounced task tail), call the pane's `recomputeVisible()` — give `GitStatusModel` an `onChange: (() -> Void)?` the pane sets.
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit: `feat: gitignored-aware filtering in pane pipeline`

### Task 6: Badges, dimming, branch display, filter toggle (view layer)

**Files:**
- Modify: `Sources/FileExplorer/FileEntryLabel.swift` (badge dot + dimming), `Sources/FileExplorer/ThumbnailGridView.swift` (cell badge — pass the pane/git index down the same way tags reach cells), `Sources/FileExplorer/PaneView.swift` (status bar suffix; dot lookup for list rows), `Sources/FileExplorer/FilterBarView.swift` ("Hide ignored" toggle)
- Test: none new (view layer); full suite stays green

- [ ] **Step 1: Badge dot** — `FileEntryLabel` gains `var gitState: GitFileState = .clean`. After the name (before tag dots): when state ∈ {modified: `.orange`, staged: `.green`, untracked: `.blue`, conflicted: `.red`} render `Circle().fill(color).frame(width: 7, height: 7).help("Git: <state>")`. When the entry `isIgnored` (pass `var gitIgnored = false`), apply `.opacity(0.5)` to the whole label. Callers: `PaneView` list rows and `ThumbnailGridView` cells resolve via `pane.gitStatus.index` (nil → defaults); columns view (`ColumnBrowserView`) uses `FileEntryLabel` too — check and thread the same lookup if its signature allows without contortions, else leave columns badge-less with a code comment stating the constraint.
- [ ] **Step 2: Status bar** — in `PaneView.statusBar` (line ~239), append when `pane.gitStatus.index != nil`: `Text("⎇ \(branchLabel) · \(changedCount) changed")` with `changedCount == 0` → just `⎇ branchLabel`. Secondary style matching existing status text.
- [ ] **Step 3: Filter toggle** — `FilterBarView` gains a "Hide ignored" `Toggle`/button visible only when `pane.gitStatus.isInRepo`, bound to `filter.hideGitIgnored ?? false` via manual Binding (set false → nil to keep `isActive` honest). Follow the bar's existing chip/control style.
- [ ] **Step 4:** `swift build` clean; full tests PASS; `swift run FileExplorer` in this repo — badges on modified files, branch in status bar, toggle hides `.build/`.
- [ ] **Step 5:** Commit: `feat: git badges, branch status, and hide-ignored toggle in panes`

### Task 7: README + walkthrough notes

- [ ] README: "Git awareness" bullet list under Finder power features (badge colors, branch display, hide-ignored toggle; read-only by design).
- [ ] Full test suite PASS; `./Scripts/bundle.sh` builds.
- [ ] Commit: `docs: git integration usage notes`. Manual walkthrough items: badge correctness in a busy repo, ignored dimming, status-bar branch on worktrees, huge-repo responsiveness.
