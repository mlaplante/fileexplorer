# Milestone 14 — Finder Power Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship gap-analysis items 8–14 (Group By, Put Back, Finder comments, Tags sidebar, preview pane, Share menu, spring-loaded folders) as v4.0.0.

**Architecture:** Same posture as M13: pure Core logic first (Grouper, TrashRegistry, CommentWriter, spring-load timing), thin SwiftUI/AppKit wiring second. New AppKit bridge only for `NSSharingServicePicker` (QuickLookController posture). All new session-snapshot fields optional so v3/M13 `session.json` still decodes — add a backward-compat decode test for every field.

**Tech Stack:** Swift 6, SwiftUI, SPM, CLT-only toolchain (no `@State`/`@FocusState`). Tests: `swift run FileExplorerTests`, suites registered in `Sources/FileExplorerTests/main.swift`.

**Branch:** create `v4.0-m14` off the merged M13 `main`. Spec: `docs/superpowers/specs/2026-07-08-fileexplorer-v4-design.md`. Prerequisite: M13 merged (Task 5 reuses the Sort By menu shape; grid keyboard focus plumbing helps Task 7).

---

### Task 1: Grouper (Group By core)

**Files:**
- Create: `Sources/FileExplorerCore/Grouper.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift` (`groupBy: Grouper.Axis` with `didSet` re-derive, like `showHidden`), `Sources/FileExplorerCore/SessionSnapshot.swift` (+ optional `groupBy` on the pane snapshot, decode-defaulting to `.none`)
- Test: `Sources/FileExplorerTests/GrouperTests.swift`, register `await grouperTests()`

- [ ] **Step 1: Failing tests** — `Grouper.group(entries, by:)` where `Axis: String, Codable, CaseIterable = none|kind|dateModified|size`. Fixtures: hand-built `FileEntry` values (see `FilterEngineTests` for the entry-fixture pattern). Assert: (a) `.none` → single unnamed group preserving input order; (b) `.kind` → groups titled by `entry.kind`, alphabetical, folders group first; (c) `.dateModified` → buckets Today/Yesterday/Previous 7 Days/Previous 30 Days/Earlier computed against an injected `now: Date` (parameter, NOT `Date()` — keep it pure), newest bucket first, empty buckets omitted; (d) `.size` → buckets 0–1 MB/1–100 MB/100 MB–1 GB/>1 GB, largest first, folders (size nil/0) in a "Folders" bucket; (e) within every group, input (already-sorted) order is preserved; (f) snapshot with `groupBy` absent decodes to `.none` (paste a v3-era pane-snapshot JSON literal and decode it).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement `Grouper` (`struct FileGroup: Equatable { let title: String?; let entries: [FileEntry] }`). **Step 4:** Run → PASS.
- [ ] **Step 5:** Add `PaneState.groupBy` (didSet triggers the same re-derive path as `showHidden`), expose `groupedEntries: [FileGroup]` computed from the already-filtered/sorted `entries` with `now: Date()` injected at the call site, and persist through `SessionSnapshot` (+ round-trip + backward-compat tests in `SessionSnapshotTests.swift`).
- [ ] **Step 6:** Build + tests PASS. Commit: `feat: Grouper core with kind/date/size axes and snapshot persistence`

### Task 2: Group By UI (list sections, grid headers, View menu)

**Files:**
- Modify: `Sources/FileExplorer/PaneView.swift` (Table sections), `Sources/FileExplorer/ThumbnailGridView.swift` (header rows), `Sources/FileExplorer/FileExplorerApp.swift` (View ▸ Group By submenu, mirroring M13's Sort By menu)
- Test: none new (view layer) — existing suites must stay green

- [ ] **Step 1:** List view: when `pane.groupBy != .none`, render `Table` with one `Section(group.title ?? "")` per `FileGroup` (macOS `Table` supports `Section` inside rows content; if the compiler disagrees on this toolchain, fall back to a flat table with full-width non-selectable header rows — decide by compiling, not guessing).
- [ ] **Step 2:** Grid: interleave a section-header `Text` row (spanning the grid width via `Section` in `LazyVGrid`) per group. Rubber-band frames and `GridNavigator` keep working because cell frames are unchanged (verify by running the app).
- [ ] **Step 3:** View menu: `Menu("Group By")` with a checkmark on `pane.groupBy`, same construction as Sort By.
- [ ] **Step 4:** `swift build` + full tests PASS. Commit: `feat: Group By in list, grid, and View menu`

### Task 3: TrashRegistry + Put Back

**Files:**
- Create: `Sources/FileExplorerCore/TrashRegistry.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift` (record on trash; `putBackSelected`), `Sources/FileExplorer/FileActionsMenu.swift` ("Put Back" item), `Sources/FileExplorerCore/SessionPersister.swift` ONLY if it owns the App Support path helper (reuse its directory-injection pattern for the registry file)
- Test: `Sources/FileExplorerTests/TrashRegistryTests.swift`, register `await trashRegistryTests()`

- [ ] **Step 1: Failing tests** — registry API: `record(original:trashed:)`, `original(forTrashed:) -> URL?`, `remove(trashed:)`, `load(from:)/save(to:)` (injectable directory, atomic). Assert: (a) record → lookup round-trips through save+load; (b) corrupt JSON file → empty registry, no throw; (c) `prune()` drops entries whose trashed file no longer exists on disk (create + delete a real temp file); (d) `isInTrash(URL)` true for paths with a `.Trash` or `Trash` path component, false otherwise.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (value-type store + JSON persister, `SessionPersister` failure posture). **Step 4:** Run → PASS.
- [ ] **Step 5: Failing integration tests** — drive `PaneState` in a temp dir: (a) trash a file via the pane → registry contains the pair (hook the record call in `trashSelected` right where `UndoRecorder.recordTrash` gets its `(original, trashed)` pairs); (b) `putBackSelected` on the trashed URL restores to the original path (`FileOperationService.relocate(_:toExactly:)`) and removes the record; (c) original path occupied → failure lands in `errorMessage`, record kept; (d) undo after Put Back re-trashes (register inverse with `UndoRecorder.recordMove`-style pair back to the trashed URL).
- [ ] **Step 6:** Implement → tests PASS.
- [ ] **Step 7:** Menu: show `Button("Put Back")` in `FileActionsMenu` when every selected URL satisfies `TrashRegistry.isInTrash` and has a record. Registry singleton owned by `FileExplorerApp` alongside the other app-lifetime models, loaded at launch, saved on record/remove (debounced like session autosave if a debouncer is handy; synchronous save is acceptable at this write rate).
- [ ] **Step 8:** Build + tests PASS. Commit: `feat: Put Back for app-trashed items via persisted trash registry`

### Task 4: Finder comments (read + write)

**Files:**
- Create: `Sources/FileExplorerCore/CommentWriter.swift`
- Modify: `Sources/FileExplorerCore/InfoGatherer.swift` (+ `finderComment`), `Sources/FileExplorerCore/GetInfoModel.swift`, `Sources/FileExplorer/GetInfoView.swift` (editable Comments row — text field bound via manual `@Observable` binding, NOT `@State`; commit on Return/blur like `RenameSheet` does)
- Test: `Sources/FileExplorerTests/CommentTests.swift`, register `await commentTests()`

- [ ] **Step 1: Failing tests** — (a) `CommentWriter.encode("hello")` produces a binary plist decoding to the string (round-trip via `PropertyListSerialization`); (b) `CommentWriter.write("hello", to: url)` then `CommentWriter.read(from: url)` == "hello" on a temp file (xattr `com.apple.metadata:kMDItemFinderComment` — read back with `getxattr` in the test, mirroring `TagWriter`'s test approach — read `TagWriterTests` equivalent in `DailyOpsTests.swift`/`InfoGathererTests.swift` first and copy its xattr helpers); (c) write failure on a nonexistent path returns a failure, not a crash; (d) `read` on a file with no comment → nil.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement `CommentWriter` cloning `TagWriter`'s xattr code (setxattr/getxattr, binary plist payload). **Step 4:** Run → PASS.
- [ ] **Step 5:** `InfoGatherer` gains `finderComment` populated via `CommentWriter.read` (skip `MDItem` — one code path for read and write beats two). `GetInfoView` Comments row: `TextField` with manual binding to a `commentDraft` on `GetInfoModel`; commit writes via `CommentWriter.write`, failure → the pane's `reportTagFailure` posture (reuse that exact mechanism if `GetInfoModel` holds a pane reference; otherwise surface inline in the panel).
- [ ] **Step 6:** Build + tests PASS. Commit: `feat: read/write Finder comments in Get Info`

### Task 5: Tags in the sidebar

**Files:**
- Modify: `Sources/FileExplorerCore/SettingsStore.swift` (+ `knownTags: [String]`, defaulted so old `settings.json` decodes), `Sources/FileExplorer/SidebarView.swift` (Tags section), `Sources/FileExplorerCore/PaneState.swift` (fold listing tags into `knownTags` where entries reload)
- Test: extend `Sources/FileExplorerTests/SettingsModelTests.swift` + `Sources/FileExplorerTests/TagFilterTests.swift`

- [ ] **Step 1: Failing tests** — (a) `SettingsStore` with `knownTags` absent in JSON decodes to `[]` (paste an old settings JSON literal); (b) round-trip persists tags sorted, deduped, case-preserving; (c) `PaneState`-level: loading entries with tags `["Red", "projx"]` merges them into the settings model's `knownTags` (drive with the injected-settings pattern the existing settings tests use).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** `SidebarView`: `Section("Tags")` after Presets listing `NSWorkspace.shared.fileLabels ∪ settings.settings.knownTags` (labels first, then extras alphabetical), each row a colored dot (reuse the color mapping in `TagDotsView.swift` — extract it to Core if it's view-local) + name. Click: if `session.activePane.filter.tags == [tag]` clear it, else set it (route through the same code path `FilterBarView` uses so `filterExtensionsText` conventions stay intact).
- [ ] **Step 6:** Build + tests PASS. Commit: `feat: Tags sidebar section filters the active pane`

### Task 6: Preview pane

**Files:**
- Create: `Sources/FileExplorer/PreviewPaneView.swift`
- Modify: `Sources/FileExplorerCore/TabState.swift` (`showsPreviewPane: Bool`), `Sources/FileExplorerCore/SessionSnapshot.swift` (optional field + compat test), `Sources/FileExplorer/TabBarView.swift` (trailing column in `PaneAreaView`), `Sources/FileExplorerCore/ShortcutRegistry.swift` (+ `previewPane` command, default ⌥⌘P), `Sources/FileExplorer/FileExplorerApp.swift` (menu item)
- Test: extend `SessionSnapshotTests.swift` (persistence) + `ShortcutTests` (new command in the registry has a default chord, no conflicts)

- [ ] **Step 1: Failing tests** — snapshot round-trip with `showsPreviewPane: true`; v3-era tab-snapshot JSON literal decodes with `false`; `ShortcutRegistry.Command.previewPane` exists with default chord ⌥⌘P and the conflict detector reports none against defaults.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement model + registry changes. **Step 4:** Run → PASS.
- [ ] **Step 5:** `PreviewPaneView`: fixed-width (280 pt) trailing column inside `PaneAreaView`'s `HSplitView` content; single selection → large preview (reuse `PreviewRenderer` for image/PDF; otherwise `ThumbnailStore`'s `QLThumbnailGenerator` at 512 px) above an `InfoGatherer`-fed metadata block (kind, size, dates, tags — reuse `GetInfoModel`'s on-demand machinery, do not duplicate the gather code); multi-selection → "N items selected"; empty → "No Selection". Owned model: follow the app's rule — any `@Observable` it needs is created in `FileExplorerApp`/`TabState`, not the view struct.
- [ ] **Step 6:** Wire the ⌥⌘P command through the same registry-driven path as `getInfo` (menu + palette + customizable shortcut come for free — confirm the palette picks up new registry commands automatically; if the palette has its own command list, add it there too — check `PaletteCoordinator.swift`).
- [ ] **Step 7:** Build + tests PASS. Commit: `feat: toggleable preview pane with metadata (⌥⌘P)`

### Task 7: Share menu (incl. AirDrop)

**Files:**
- Create: `Sources/FileExplorer/ShareBridge.swift`
- Modify: `Sources/FileExplorer/FileActionsMenu.swift` ("Share…" item after "Open With")
- Test: none automatable (AppKit panel + TCC) — manual walkthrough

- [ ] **Step 1:** `ShareBridge`: an `NSViewRepresentable` producing a zero-size `NSView` anchor + a `@MainActor` helper `present(urls: [URL], from view: NSView)` that instantiates `NSSharingServicePicker(items: urls)` and calls `show(relativeTo: .zero, of: view, preferredEdge: .minY)`. Keep a strong reference to the picker for the duration of presentation (delegate callback or a held property — dropping it early dismisses the menu; mirror how `QuickLookController` holds its panel).
- [ ] **Step 2:** Menu item `Button("Share…") { … }` passing the selected URLs. The context menu itself can't host the anchor view — embed the `ShareBridge` anchor in each row's label (it's zero-size) or at the pane level with the anchor positioned at the selection; simplest correct v1: pane-level anchor, picker appears near the pane — acceptable, note it in the walkthrough doc.
- [ ] **Step 3:** `swift build` clean; full tests PASS (no regressions).
- [ ] **Step 4:** Commit: `feat: Share menu via NSSharingServicePicker`

### Task 8: Spring-loaded folders

**Files:**
- Create: `Sources/FileExplorerCore/SpringLoad.swift` (pure timing decision), `Sources/FileExplorer/SpringLoadModel.swift` (timer holder)
- Modify: `Sources/FileExplorer/PaneView.swift` + `Sources/FileExplorer/ThumbnailGridView.swift` (per-folder-row `dropDestination` `isTargeted` handlers)
- Test: `Sources/FileExplorerTests/SpringLoadTests.swift`, register `await springLoadTests()`

- [ ] **Step 1: Failing tests** — pure part: `SpringLoad.shouldSpring(hoverStart: Date, now: Date, delay: 0.7)` true at ≥ 0.7 s, false before; `SpringLoad.delay` == 0.7. Model part (runs fine in the harness — it's just a timer): `SpringLoadModel.beginHover(folder:) → fire callback after delay` using a shortened injected delay (0.05 s) and `Task.sleep`-based assertion; `endHover()` before expiry → callback never fires; a second `beginHover` on a different folder resets the clock.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (model: `Task`-based timer, cancelled on `endHover`/`deinit`; callback `onSpring: (URL) -> Void`). **Step 4:** Run → PASS.
- [ ] **Step 5:** Wire: folder rows/cells that already act as drop targets get `isTargeted:` bindings feeding `beginHover`/`endHover`; `onSpring` navigates the pane (`Task { await pane.navigate(to: folder) }`). If rows are not currently individual drop targets (drop may be pane-level — VERIFY in `PaneView.swift` first), add per-row `.dropDestination(for: URL.self)` that both handles the drop into that folder (route through the existing `DropDecision` + `FileOperationService` path) and provides the `isTargeted` signal — this also gives Finder-parity "drop onto a folder row", note it in the commit message.
- [ ] **Step 6:** Build + tests PASS (gesture behavior → manual walkthrough). Commit: `feat: spring-loaded folders on drag hover`

### Task 9: Version bump + docs

- [ ] Bump `CFBundleShortVersionString` to `4.0.0`; README: preview pane (⌥⌘P), Group By/Sort By, Share, Put Back, Tags/Recents sidebar, comments.
- [ ] Full `swift run FileExplorerTests` PASS; `./Scripts/bundle.sh` builds.
- [ ] Commit: `chore: bump version to 4.0.0`. No tag/release — human runs the manual walkthrough first (Share/AirDrop, spring-load drag, preview pane, Put Back on real Trash, comment visible in Finder, group headers in both views, tag click filtering).
