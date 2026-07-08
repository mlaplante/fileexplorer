# Milestone 13 — Finder-Parity Quick Wins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship gap-analysis items 1–7 (grid arrow keys, eject, Recents, Make Alias, free space, Sort By menu, New Folder with Selection) as v3.1.0.

**Architecture:** Each feature = one pure/testable Core piece + a thin SwiftUI wiring layer, following the established v1–v3 patterns (`FileOperationService` + `UndoRecorder` for mutations, status-bar error aggregation, `@Observable` models owned by `FileExplorerApp`, NO `@State`/`@FocusState`).

**Tech Stack:** Swift 6, SwiftUI, SPM, CLT-only toolchain. Tests: `swift run FileExplorerTests` (executable harness — `await test("…") { expectEqual(…) }` convention, register each new suite in `Sources/FileExplorerTests/main.swift`).

**Branch:** create `v4.0-m13` off `main` before Task 1. Spec: `docs/superpowers/specs/2026-07-08-fileexplorer-v4-design.md`.

---

### Task 1: Make Alias (symlink creation)

**Files:**
- Modify: `Sources/FileExplorerCore/FileOperationService.swift`
- Modify: `Sources/FileExplorerCore/CollisionNamer.swift` (only if no suffix helper fits)
- Modify: `Sources/FileExplorerCore/PaneState.swift` (new `makeAliasSelected` following `duplicateSelected`'s shape: off-main op, `UndoRecorder.recordCreation`, reload + select outputs, error aggregation)
- Modify: `Sources/FileExplorer/FileActionsMenu.swift` (menu item "Make Alias" after "Duplicate")
- Test: `Sources/FileExplorerTests/AliasTests.swift` (new), register `await aliasTests()` in `main.swift`

- [ ] **Step 1: Write failing tests** — in a temp dir (copy the pattern from `FileOperationTests.swift`): (a) `FileOperationService.symlink([file])` creates `file alias` whose `destination(ofSymbolicLink:)` is the source path and returns `.success`; (b) with `file alias` already present, a second call creates `file alias 2`; (c) symlinking a folder works and the link resolves; (d) undo path: `recordCreation` deletion restores the pre-state (mirror the existing creation-undo test in `UndoTests`-equivalent file).

```swift
import Foundation
import FileExplorerCore

@MainActor
func aliasTests() async {
    await test("symlink creates 'name alias' pointing at source") {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: src.path, contents: Data("x".utf8))
        let results = FileOperationService.symlink([src])
        guard case .success(let link) = results[0].outcome else {
            return fail("symlink failed: \(results[0].outcome)")
        }
        expectEqual(link.lastPathComponent, "file alias", "Finder-style name")
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        expectEqual(URL(fileURLWithPath: dest, relativeTo: dir).standardizedFileURL.path,
                    src.standardizedFileURL.path, "resolves to source")
    }
    await test("collision appends counter") {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: src.path, contents: Data())
        _ = FileOperationService.symlink([src])
        let second = FileOperationService.symlink([src])
        guard case .success(let link) = second[0].outcome else { return fail("second symlink failed") }
        expectEqual(link.lastPathComponent, "file alias 2", "suffix increments")
    }
}
```

(Adapt `tempDir()`/`fail` to the harness's actual helpers — check `FileOperationTests.swift` first and reuse its temp-directory helper verbatim.)

- [ ] **Step 2:** `swift run FileExplorerTests` → new tests FAIL (symbol missing).
- [ ] **Step 3: Implement** `FileOperationService.symlink`:

```swift
/// Creates "name alias" symlinks next to each source (Finder's Make Alias,
/// realized as POSIX symlinks — the app's symlink-first posture). Collisions
/// get " 2", " 3", … suffixes. The link stores the source's absolute path.
public static func symlink(_ sources: [URL]) -> [ItemResult] {
    let fm = FileManager.default
    return sources.map { source in
        let dir = source.deletingLastPathComponent()
        let existing = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        let name = CollisionNamer.sequentialName(
            base: source.lastPathComponent + " alias", existing: existing)
        let target = dir.appendingPathComponent(name)
        do {
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
            return ItemResult(source: source, outcome: .success(target))
        } catch {
            return ItemResult(source: source, outcome: .failure(FileOpError(error)))
        }
    }
}
```

Note: `CollisionNamer.sequentialName(base:existing:)` already exists (used by `newFile`). Verify its suffix format produces `file alias 2`; if it inserts before the extension, add a plain-suffix variant instead of changing its behavior.

- [ ] **Step 4:** `swift run FileExplorerTests` → PASS.
- [ ] **Step 5:** Wire `PaneState.makeAliasSelected(_ targets: [URL])` (copy `duplicateSelected`'s structure exactly: run op off-main, `UndoRecorder.recordCreation(successes, …)`, reload, select created links, aggregate failures to `errorMessage`) and add the `Button("Make Alias")` to `FileActionsMenu` beside Duplicate.
- [ ] **Step 6:** `swift build` clean; `swift run FileExplorerTests` all PASS.
- [ ] **Step 7:** Commit: `feat: Make Alias creates collision-safe symlinks with undo`

### Task 2: Sort By menu

**Files:**
- Create: `Sources/FileExplorerCore/SortMenu.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift` (View menu — next to the existing view-mode pickers)
- Test: `Sources/FileExplorerTests/SortMenuTests.swift`, register `await sortMenuTests()`

- [ ] **Step 1: Failing tests** — `SortMenu` is a pure mapping between a menu axis (`name|size|kind|dateModified`) and `[KeyPathComparator<FileEntry>]`: (a) `axis(of: pane.sortOrder)` recovers the axis and direction from the comparator `PaneState` holds; (b) `comparators(for: .size, ascending: false)` round-trips through `SortTokenCoder` (encode → decode → equal); (c) "selecting the active axis flips direction" — `toggledOrder(current:selecting:)` returns same axis, reversed order; selecting a different axis returns it ascending.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `SortMenu` (enum `Axis: String, CaseIterable` + the three pure functions above; reuse the key paths `PaneState.sortOrder` already uses — read `PaneState.swift:28` for the default comparator and `SortTokenCoder` for the encodable token mapping).
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Add `Menu("Sort By")` in the View `CommandMenu` in `FileExplorerApp.swift`: one `Toggle`/checkmark item per axis reflecting `SortMenu.axis(of: session.activePane.sortOrder)`, action `pane.sortOrder = SortMenu.toggledOrder(current: pane.sortOrder, selecting: axis)`. Follow the existing menu-item style in that file (direct `session.activePane` access, `.keyboardShortcut` omitted).
- [ ] **Step 6:** Build + tests PASS. Commit: `feat: Sort By menu drives sortOrder in all view modes`

### Task 3: Free space in the status bar

**Files:**
- Create: `Sources/FileExplorerCore/VolumeSpace.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift` (fetch on navigate/reload → `availableSpaceText: String?`)
- Modify: `Sources/FileExplorer/PaneView.swift` (`statusBar`, trailing side)
- Test: `Sources/FileExplorerTests/VolumeSpaceTests.swift`, register `await volumeSpaceTests()`

- [ ] **Step 1: Failing tests** — pure formatting: `VolumeSpace.label(bytes: 1_500_000_000)` == `"1.5 GB available"` (use `ByteCountFormatter` with `.useGB`-style adaptive counts — assert via the formatter's own output to stay locale-stable: `expectEqual(VolumeSpace.label(bytes: n), ByteCountFormatter.string(fromByteCount: n, countStyle: .file) + " available")`); `label(bytes: nil)` == `nil`. Plus an integration-ish test: `VolumeSpace.availableBytes(for: FileManager.default.temporaryDirectory)` returns non-nil > 0 on the local volume.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `VolumeSpace`: `availableBytes(for url: URL) -> Int64?` reading `.volumeAvailableCapacityForImportantUsageKey` resource value; `label(bytes: Int64?) -> String?`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** In `PaneState`, set `availableSpaceText` wherever entries reload (the single reload path — find the method `DirectoryWatcher` and `navigate` both funnel through), computing off-main with the entries load. In `PaneView.statusBar`, append `Spacer()` + `Text(pane.availableSpaceText ?? "")` styled like the item-count text.
- [ ] **Step 6:** Build + tests PASS. Commit: `feat: status bar shows volume free space`

### Task 4: Recents sidebar section

**Files:**
- Modify: `Sources/FileExplorerCore/SessionState.swift` (`clearRecentFolders()`)
- Modify: `Sources/FileExplorer/SidebarView.swift` (section between Favorites and Volumes)
- Test: extend `Sources/FileExplorerTests/SessionStateTests.swift` (a `recentsTests()` suite already exists — add there if that's where recents live; check first)

- [ ] **Step 1: Failing tests** — (a) `clearRecentFolders()` empties the list and the next snapshot round-trip stays empty; (b) a helper `SessionState.recentPlaces(limit: 8, excluding: Set<String>)` returns at most 8, skips excluded standardized paths (the built-in favorites), preserves MRU order.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement both members. **Step 4:** Run → PASS.
- [ ] **Step 5:** In `SidebarView`, add `Section("Recents")` after Favorites: rows via the existing `row(_:)` helper with `systemImage: "clock"`, from `session.recentPlaces(limit: 8, excluding: builtInFavoritePaths)`; `.contextMenu { Button("Clear Recents") { session.clearRecentFolders() } }` on the section content. Hide the section when empty (match the Presets-section pattern).
- [ ] **Step 6:** Build + tests PASS. Commit: `feat: Recents section in sidebar with Clear Recents`

### Task 5: Eject volumes

**Files:**
- Modify: `Sources/FileExplorer/SidebarView.swift` (`VolumesModel` + volume-row context menu)
- Test: none automatable (hardware + TCC) — manual walkthrough. Keep the ejectable-flag read in `VolumesModel.refresh` trivial enough to review by eye.

- [ ] **Step 1:** In `VolumesModel.refresh`, add `.volumeIsEjectableKey, .volumeIsRemovableKey` to `keys`; extend `StandardPlaces.Place` usage with a parallel `ejectableVolumes: Set<URL>` on the model (do NOT add fields to `StandardPlaces.Place` unless it already has room — check `StandardPlaces.swift`; a side set keyed by URL avoids touching the shared type). Root volume (`"/"`) is never ejectable.
- [ ] **Step 2:** Volume rows: `.contextMenu { if volumesModel.isEjectable(place.url) { Button("Eject") { volumesModel.eject(place.url, reportingTo: session.activePane) } } }`. Implement `eject` as: `Task.detached` → `try NSWorkspace.shared.unmountAndEjectDevice(at: url)` → on failure hop to main and set `pane.errorMessage = "Couldn't eject \(name): \(error.localizedDescription)"`. The mount-notification observer already refreshes the list on success.
- [ ] **Step 3:** `swift build` clean; existing tests PASS (no regressions).
- [ ] **Step 4:** Commit: `feat: eject removable volumes from the sidebar`

### Task 6: New Folder with Selection

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift` (`newFolderWithSelection(_ targets: [URL])`)
- Modify: `Sources/FileExplorer/FileActionsMenu.swift` (item under "New Folder", selection non-empty)
- Test: `Sources/FileExplorerTests/NewFolderWithSelectionTests.swift`, register `await newFolderWithSelectionTests()`

- [ ] **Step 1: Failing tests** (temp-dir, driving `PaneState` directly like `paneBatchToolsTests` does): (a) after `newFolderWithSelection([a, b])`, an `untitled folder` exists containing `a` and `b`, and the pane selection is the new folder; (b) ONE `undo()` on the pane's `UndoManager` restores `a`/`b` to the original folder AND removes the created folder (grouping works); (c) redo re-applies both; (d) a locked/immovable item leaves the folder in place with the failure aggregated in `errorMessage` and the movable item moved.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement on `PaneState` (mirror the sync-executor grouping): `undoManager.beginUndoGrouping()`; `FileOperationService.newFolder(in: currentURL)` → `UndoRecorder.recordCreation`; `FileOperationService.move(targets, into: folder)` → `UndoRecorder.recordMove`; `undoManager.endUndoGrouping()`; reload; select folder; trigger the rename sheet (reuse whatever flag `RenameSheet` presentation already keys on — find it in `PaneView.swift` and set it for the new folder).
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Menu item: `Button("New Folder with Selection (\(targets.count) Item\(targets.count == 1 ? "" : "s"))")` shown when `!targets.isEmpty`, placed next to "New Folder".
- [ ] **Step 6:** Build + tests PASS. Commit: `feat: New Folder with Selection with single-step undo`

### Task 7: Icon-grid arrow-key navigation

**Files:**
- Create: `Sources/FileExplorerCore/GridNavigator.swift`
- Modify: `Sources/FileExplorer/ThumbnailGridView.swift` (key handling)
- Test: `Sources/FileExplorerTests/GridNavigatorTests.swift`, register `await gridNavigatorTests()`

- [ ] **Step 1: Failing tests** — build a synthetic 3×3 frame map (100 pt cells, 20 pt gutters, third row has 1 cell — ragged). Assert: (a) `.right` from (0,0) → (1,0); (b) `.down` from (1,0) → (1,1); (c) `.down` from (1,1) → the ragged row's only cell (nearest by horizontal distance); (d) `.down` from the last row → nil (no wrap); (e) `.left` at column 0 → nil; (f) `target(from: nil, …)` (empty current) → topmost-leftmost cell. Signature: `GridNavigator.target(from current: URL?, direction: Direction, frames: [URL: CGRect]) -> URL?` with `enum Direction { case up, down, left, right }`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement: vertical moves pick the nearest frame in the adjacent "row band" (frames whose midY differs by more than half a cell height), minimizing |midX delta| then |midY delta|; horizontal moves stay within the same row band, nearest midX in the chosen direction. Pure geometry, no view types beyond `CGRect`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** In `ThumbnailGridView`, attach `.onMoveCommand { direction in … }` on the grid's focusable container (the view already participates in key handling for rubber-band/⌘A — follow how `PaneView`'s table gets key events; if the grid lacks focus, wrap in a focusable representable the way existing key handling does — check `FileExplorerApp.swift`'s key-routing first). Plain move: `pane.selection = [next]`, update `selectionAnchor`. ⇧ (via `.onKeyPress` arrow cases with `.shift` modifiers if `onMoveCommand` can't see modifiers on this toolchain — verify): extend from `selectionAnchor` using the same range semantics `SelectionResolver` provides for ⇧-click. Scroll the target into view with `ScrollViewReader.scrollTo(next)`.
- [ ] **Step 6:** Build + tests PASS; note ⇧-extension needs the MANUAL walkthrough.
- [ ] **Step 7:** Commit: `feat: arrow-key navigation in icon grid`

### Task 8: Version bump + release notes

- [ ] Bump `CFBundleShortVersionString` to `3.1.0` in `Resources/Info.plist`; update README shortcut table (Sort By menu, Make Alias).
- [ ] Full `swift run FileExplorerTests` PASS; `./Scripts/bundle.sh` builds.
- [ ] Commit: `chore: bump version to 3.1.0`. Do NOT tag/release — the human does the release + manual walkthrough (grid arrows incl. ⇧, eject a real USB volume, Recents section, free-space label, New Folder with Selection undo as one step, Make Alias badge in Finder).
