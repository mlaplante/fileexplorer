# V6 M4 — Archive Browsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Browse Archive…" opens a read-only sheet over any `ArchiveKind`-supported archive — navigate its tree, Quick Look/Open single entries via on-demand temp extraction, Extract Selected into a chosen folder, Extract All via the existing Unarchiver.

**Architecture:** Pure `ArchiveCatalogParser` (bsdtar `-tvf` text → sanitized entry list) + pure `ArchiveCatalog` (path-keyed tree queries). Blocking `ArchiveExtractor` (bsdtar/ditto subprocess into a fresh destination). `@MainActor @Observable` `ArchiveBrowserModel` owns the listing run, navigation path, temp-preview lifecycle. Sheet UI follows the existing sheet presentation pattern.

**Tech Stack:** Swift 6, SwiftUI, SPM, CLT-only. Spec: `docs/superpowers/specs/2026-07-09-archive-browsing-design.md`. Branch: `v6-archive-browsing` off main (after M3 merges).

---

## HARD TOOLCHAIN CONSTRAINTS (read first)

- **No Xcode — CLT only.** `swift build`; NEVER `xcodebuild` or `swift test`.
- **`@State`/`@FocusState` DO NOT COMPILE.** Sheet state lives on `@Observable` models.
- Tests: `swift run FileExplorerTests`; register suites in `Sources/FileExplorerTests/main.swift`; redirect output to a file and read it.
- Swift 6 strict concurrency: subprocess work in `Task.detached`, results hopped to the main actor.
- Fixture archives in tests: build with `ditto -c -k --sequesterRsrc` (zip) and `/usr/bin/tar -czf` (tar.gz) — never assume `/usr/bin/zip` exists.
- Commit after each task. Do not push.

### Task 1: ArchiveCatalogParser (pure listing parse + sanitization)

**Files:**
- Create: `Sources/FileExplorerCore/ArchiveCatalogParser.swift`
- Test: `Sources/FileExplorerTests/ArchiveCatalogParserTests.swift`, register `await archiveCatalogParserTests()`

- [ ] **Step 1: Failing tests** —

```swift
public struct ArchiveEntry: Equatable, Sendable {
    public let path: String        // normalized, no leading "./", no trailing "/"
    public let name: String        // last component
    public let isDirectory: Bool
    public let size: Int64         // 0 for directories
    public let modified: Date?
}
public struct ParsedCatalog: Equatable, Sendable {
    public let entries: [ArchiveEntry]
    public let hadSuspiciousPaths: Bool
    public let isPartial: Bool
}
public enum ArchiveCatalogParser {
    public static let entryCap = 100_000
    public static func parse(listing: String, cap: Int = entryCap) -> ParsedCatalog
}
```

  bsdtar `-tvf` emits `ls -l`-style lines: `-rw-r--r--  0 user group    1024 Jul  9 10:30 dir/file.txt` (recent files) and `… Jul  9  2024 …` (older files — year instead of time). Assert: (a) file line → entry with size/path/name, `isDirectory` false; (b) `d` mode char or trailing `/` → directory, size 0; (c) both date shapes parse (inject a calendar/year for the time-form via a `referenceDate:` parameter so tests are deterministic — when the format lacks a year, assume the reference year); unparseable date → nil modified, entry kept; (d) `./`-prefixed paths normalized; (e) paths containing spaces survive (path = everything after the date columns — parse by column position from the right, not by splitting on spaces); (f) implicit parents: `a/b/c.txt` alone synthesizes directories `a` and `a/b`; explicit dir entries not duplicated; (g) absolute (`/etc/x`) and traversal (`a/../../x`) paths dropped + `hadSuspiciousPaths` true; (h) symlink lines (`l` mode) dropped (not extractable targets in a read-only browser; avoids link-target games); (i) more than `cap` entries → first cap kept, `isPartial` true; (j) empty listing → empty catalog, no flags.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: ArchiveCatalogParser bsdtar listing parse`

### Task 2: ArchiveCatalog (tree queries)

**Files:**
- Create: `Sources/FileExplorerCore/ArchiveCatalog.swift`
- Test: `Sources/FileExplorerTests/ArchiveCatalogTests.swift`, register `await archiveCatalogTests()`

- [ ] **Step 1: Failing tests** —

```swift
public struct ArchiveCatalog: Sendable {
    public init(parsed: ParsedCatalog)
    public func children(of path: String) -> [ArchiveEntry]   // "" = root
    public func entry(at path: String) -> ArchiveEntry?
    public func descendantFiles(of path: String) -> [ArchiveEntry]  // recursive, files only
    public var fileCount: Int
    public var hadSuspiciousPaths: Bool
    public var isPartial: Bool
}
```

  Assert: (a) root children of a nested fixture; (b) children sorted folders-first then localized name ascending; (c) `entry(at:)` nested lookup; (d) `descendantFiles` of a folder returns all files beneath it (for Extract Selected of a folder); of a file path → that file; (e) unknown path → empty/nil.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (dictionary parent-path → children built once in init). **Step 4:** Run → PASS. **Step 5:** Commit: `feat: ArchiveCatalog tree queries`

### Task 3: ArchiveExtractor (subprocess extraction)

**Files:**
- Create: `Sources/FileExplorerCore/ArchiveExtractor.swift`
- Test: `Sources/FileExplorerTests/ArchiveExtractorTests.swift`, register `await archiveExtractorTests()`

- [ ] **Step 1: Failing tests** — fixtures: helper builds a temp tree (`a/one.txt` = "ONE", `a/b/two.bin` = 1 KB random, `top.txt`), zips it with `ditto -c -k` and tars it with `tar -czf`; run every assertion against BOTH archives:

```swift
public enum ArchiveExtractor {
    /// Extract entries (archive-relative paths) under destination, preserving
    /// relative paths. Blocking — call off the main actor.
    public static func extract(entries: [String], from archive: URL, into destination: URL)
        -> Result<Void, FileOperationService.FileOpError>
    /// Extract one entry into `tempRoot/<uuid>/`, returning the extracted file URL.
    public static func extractForPreview(entry: ArchiveEntry, from archive: URL, tempRoot: URL)
        -> Result<URL, FileOperationService.FileOpError>
    public static let previewByteCap: Int64 = 512 * 1024 * 1024
}
```

  Assert: (a) extracting `["a/one.txt"]` lands `destination/a/one.txt` with bytes "ONE"; (b) extracting `["a"]`'s descendant file list preserves `a/b/two.bin` bytes; (c) preview extraction returns a URL whose contents match, under a fresh uuid dir; (d) entry over `previewByteCap` (pass a doctored `ArchiveEntry` with a huge size — no need for a real 512 MB file) → failure mentioning the cap before any subprocess runs; (e) corrupt archive (write garbage bytes with a .zip name) → failure carrying stderr excerpt; (f) zip path uses bsdtar too (`tar -xf` reads zip) — one code path, asserted by both fixtures passing.
  Implementation: `tar -xf <archive> -C <dest> --include <path>` per batch (bsdtar `--include` matches exactly when patterns contain no globs; pass each entry path). Verify expected outputs exist post-run; missing → failure.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit: `feat: ArchiveExtractor selective and preview extraction`

### Task 4: ArchiveBrowserModel (listing run + navigation + temp lifecycle)

**Files:**
- Create: `Sources/FileExplorerCore/ArchiveBrowserModel.swift`
- Test: `Sources/FileExplorerTests/ArchiveBrowserModelTests.swift`, register `await archiveBrowserModelTests()`

- [ ] **Step 1: Failing tests** — real fixture archives:

```swift
@MainActor @Observable public final class ArchiveBrowserModel {
    public private(set) var archiveURL: URL?
    public private(set) var catalog: ArchiveCatalog?
    public private(set) var currentPath = ""              // "" = root
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var isPresented = false
    public func open(archive: URL)                         // lists via bsdtar -tvf
    public func navigate(into path: String)
    public func navigateUp()
    public func close()                                    // clears state, deletes temp root
    public func previewTempRoot() -> URL                   // lazily created per open
}
```

  Assert: (a) `open` on the zip fixture → `isPresented` true once loaded, catalog children at root match; (b) `navigate(into:)`/`navigateUp` walk the tree and clamp at root; (c) corrupt archive → `errorMessage` set, `isPresented` false; (d) `close()` removes the temp root from disk and clears catalog; (e) reopening after close works (fresh temp root); (f) listing runs off the main actor (subprocess) — poll `isLoading` transitions with a deadline loop.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (listing subprocess mirrors Unarchiver's Process posture; `tar -tvf` stdout capped read; parse via `ArchiveCatalogParser` with `referenceDate: Date()`). **Step 4:** Run → PASS. **Step 5:** Commit: `feat: ArchiveBrowserModel listing and navigation`

### Task 5: ArchiveBrowserSheet + wiring

**Files:**
- Create: `Sources/FileExplorer/ArchiveBrowserSheet.swift`
- Modify: `Sources/FileExplorer/FileActionsMenu.swift` ("Browse Archive…" when the selection is exactly one `ArchiveKind`-detected file, next to the existing extract item — find where Unarchiver is invoked from the menu), `Sources/FileExplorer/FileExplorerApp.swift` (File menu item + app-lifetime `ArchiveBrowserModel`, sheet presentation on the main window content — copy the SyncPreviewSheet mounting), `Sources/FileExplorer/PaletteCoordinator.swift` (palette command, enabled under the same selection condition)
- Test: none new (view layer); full suite stays green

- [ ] **Step 1: Sheet UI** — toolbar: archive name + breadcrumb of `currentPath` components (click segment → navigate); footnotes for `isPartial` ("listing truncated") and `hadSuspiciousPaths` ("some entries hidden: unsafe paths"). Body: `List` with multi-selection over `children(of: currentPath)` — folder rows (folder icon, name) and file rows (generic doc icon via `NSWorkspace.icon(for: .init(filenameExtension:))` or the plain doc symbol, name, formatted size, formatted date). Interactions: double-click folder / Return → `navigate(into:)`; ⌘↑ → `navigateUp`; Space on a single selected file → detached `extractForPreview` → QuickLookController on the temp URL (read how QuickLookController is driven from PaneView and reuse); double-click file / ⌘O → same extraction then `NSWorkspace.shared.open`. Buttons: "Extract Selected…" (disabled on empty selection; NSOpenPanel folder pick → detached `ArchiveExtractor.extract` of the selection's `descendantFiles` paths with a spinner; error → alert), "Extract All" (delegates to the existing Unarchiver menu path — invoke the same handler `FileActionsMenu` uses today), "Done" (→ `close()`).
- [ ] **Step 2: Wiring** — context-menu item, File-menu item (disabled unless active pane selection is one archive), palette entry. All call `archiveBrowser.open(archive:)`.
- [ ] **Step 3:** `swift build` clean; full tests PASS; `swift run FileExplorer` — browse a real zip and tar.gz: navigate, Quick Look, extract selected, extract all, corrupt-file alert.
- [ ] **Step 4:** Commit: `feat: archive browser sheet with preview and selective extraction`

### Task 6: README + walkthrough notes

- [ ] README: "Browse archives" bullet (read-only, Quick Look inside, selective extraction; encrypted zips list but don't extract).
- [ ] Full suite PASS; `./Scripts/bundle.sh` builds.
- [ ] Commit: `docs: archive browsing notes`. Manual walkthrough: big archive listing speed, preview of images/PDF inside zips, extract-selected collision behavior, corrupt/encrypted archives.
