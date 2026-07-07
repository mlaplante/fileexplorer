# FileExplorer Milestone 6a (File Operations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real file manipulation: move/copy/rename/trash/new-folder via a tested Core service, undo for moves/trashes/copies/new-folders (⌘Z), context menus in both view modes, "Move/Copy to Other Pane" in dual mode, inline rename, and drag & drop out of the app.

**Architecture:** Core gains `FileOperationService` (static, blocking, off-main via Task.detached; returns per-item results) and `UndoRecorder` (@MainActor, wraps a supplied `UndoManager` with inverse operations — testable headless since UndoManager works without UI). PaneState gains thin async wrappers that run ops, reload, and record undo. App target: context menus (table + grid share one menu builder), Edit-menu undo via the window's undoManager reached through `@Environment(\.undoManager)` inside PaneView (property wrapper, not a macro — compiles on this toolchain; verify early), rename sheet driven by an @Observable model (no @State), `.draggable`/`onDrag` for drag-out.

**Tech Stack:** Swift 6 SPM (CLT-only — NO `@State`/`@FocusState`). Tests: `swift run FileExplorerTests` (214 at start; recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-6a-file-ops`.

**Design decisions (approved):**
- Trash via `FileManager.trashItem(at:resultingItemURL:)` — returns the trash URL, enabling undo-restore.
- Undo scope: move (inverse move), trash (restore from trash URL), copy + new folder (undo = trash the created item). Redo comes free from UndoManager symmetry.
- Cross-pane commands appear only when the active tab is dual; they act from the ACTIVE pane into the other pane's current folder.
- Name-collision policy v1: operations FAIL with a clear error (no auto-rename, no overwrite). Batch results aggregate failures.
- Drag OUT of the app (to Finder/other apps) v1; drop INTO panes deferred to M6b (needs modifier-key semantics).
- Inline rename via a small sheet (one text field), not in-table editing (Table cell editing needs focus machinery this toolchain can't express).

---

### Task 1: FileOperationService (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/FileOperationService.swift`
- Create: `Sources/FileExplorerTests/FileOperationTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/FileOperationTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func fileOperationTests() async {
    let fm = FileManager.default

    await test("move relocates files and reports per-item results") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        let dst = dir.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: false)
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        try Data().write(to: src.appendingPathComponent("a.txt"))
        try Data().write(to: src.appendingPathComponent("b.txt"))
        try Data().write(to: dst.appendingPathComponent("b.txt"))   // collision

        let results = FileOperationService.move(
            [src.appendingPathComponent("a.txt"), src.appendingPathComponent("b.txt")],
            into: dst)
        expectEqual(results.count, 2, "one result per item")

        let moved = results.first { $0.source.lastPathComponent == "a.txt" }!
        switch moved.outcome {
        case .success(let newURL):
            expectEqual(newURL.lastPathComponent, "a.txt", "moved to dst")
            expect(fm.fileExists(atPath: dst.appendingPathComponent("a.txt").path),
                   "file exists at destination")
            expect(!fm.fileExists(atPath: src.appendingPathComponent("a.txt").path),
                   "gone from source")
        case .failure:
            expect(false, "a.txt should move cleanly")
        }

        let collided = results.first { $0.source.lastPathComponent == "b.txt" }!
        if case .success = collided.outcome {
            expect(false, "collision must fail, not overwrite")
        } else {
            expect(fm.fileExists(atPath: src.appendingPathComponent("b.txt").path),
                   "source untouched on collision")
        }
    }

    await test("copy duplicates; rename renames; newFolder creates uniquely") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("orig.txt"))

        let copies = FileOperationService.copy(
            [dir.appendingPathComponent("orig.txt")], into: dir)
        if case .failure = copies[0].outcome {
            expect(true, "copy into same folder collides with itself — failure OK")
        }
        let dst = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        let copied = FileOperationService.copy(
            [dir.appendingPathComponent("orig.txt")], into: dst)
        if case .success(let url) = copied[0].outcome {
            expect(fm.fileExists(atPath: url.path), "copy exists")
            expect(fm.fileExists(atPath: dir.appendingPathComponent("orig.txt").path),
                   "original remains")
        } else { expect(false, "copy should succeed") }

        let renamed = FileOperationService.rename(
            dir.appendingPathComponent("orig.txt"), to: "renamed.txt")
        if case .success(let url) = renamed {
            expectEqual(url.lastPathComponent, "renamed.txt", "renamed")
        } else { expect(false, "rename should succeed") }
        if case .success = FileOperationService.rename(
            dir.appendingPathComponent("renamed.txt"), to: "renamed.txt") {
            expect(false, "rename to same name should fail")
        }

        let folder1 = FileOperationService.newFolder(in: dir)
        let folder2 = FileOperationService.newFolder(in: dir)
        if case .success(let f1) = folder1, case .success(let f2) = folder2 {
            expect(f1 != f2, "second untitled folder gets a unique name")
            expect(fm.fileExists(atPath: f2.path), "both exist")
        } else { expect(false, "newFolder should succeed twice") }
    }

    await test("trash returns the trash location for undo") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let doomed = dir.appendingPathComponent("doomed.txt")
        try Data().write(to: doomed)

        let results = FileOperationService.trash([doomed])
        if case .success(let trashURL) = results[0].outcome {
            expect(!fm.fileExists(atPath: doomed.path), "gone from folder")
            expect(fm.fileExists(atPath: trashURL.path), "exists in trash")
            // restore (what undo will do)
            if case .success = FileOperationService.move([trashURL], into: dir)[0].outcome {
                expect(fm.fileExists(atPath: dir.appendingPathComponent(
                    trashURL.lastPathComponent).path), "restorable")
            } else { expect(false, "restore should succeed") }
        } else {
            expect(false, "trash should succeed")
        }
    }
}
```

Add `await fileOperationTests()` to `main.swift` after `await hoverPreviewModelTests()`.

- [ ] **Step 2: Verify red.**

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/FileOperationService.swift`**

```swift
import Foundation

/// Blocking filesystem mutations — call off the main actor for big batches.
/// Collision policy: fail loudly, never overwrite or auto-rename (v1).
public enum FileOperationService {
    public struct ItemResult: Sendable {
        public let source: URL
        public let outcome: Result<URL, FileOpError>
    }

    public struct FileOpError: Error, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }

        init(_ message: String) { self.message = message }
        init(_ error: Error) { message = error.localizedDescription }
    }

    public static func move(_ sources: [URL], into destination: URL) -> [ItemResult] {
        perform(sources, into: destination) { source, target in
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    public static func copy(_ sources: [URL], into destination: URL) -> [ItemResult] {
        perform(sources, into: destination) { source, target in
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    public static func rename(_ url: URL, to newName: String) -> Result<URL, FileOpError> {
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard newName != url.lastPathComponent else {
            return .failure(FileOpError("Name is unchanged."))
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(FileOpError("“\(newName)” already exists."))
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return .success(target)
        } catch {
            return .failure(FileOpError(error))
        }
    }

    public static func trash(_ sources: [URL]) -> [ItemResult] {
        sources.map { source in
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
                if let trashed = resulting as URL? {
                    return ItemResult(source: source, outcome: .success(trashed))
                }
                return ItemResult(source: source,
                                  outcome: .failure(FileOpError("No trash location returned.")))
            } catch {
                return ItemResult(source: source, outcome: .failure(FileOpError(error)))
            }
        }
    }

    /// Creates "untitled folder", "untitled folder 2", … and returns it.
    public static func newFolder(in directory: URL) -> Result<URL, FileOpError> {
        let fm = FileManager.default
        var name = "untitled folder"
        var counter = 1
        var target = directory.appendingPathComponent(name)
        while fm.fileExists(atPath: target.path) {
            counter += 1
            name = "untitled folder \(counter)"
            target = directory.appendingPathComponent(name)
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            return .success(target)
        } catch {
            return .failure(FileOpError(error))
        }
    }

    private static func perform(_ sources: [URL], into destination: URL,
                                _ operation: (URL, URL) throws -> Void) -> [ItemResult] {
        sources.map { source in
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                return ItemResult(source: source, outcome: .failure(
                    FileOpError("“\(source.lastPathComponent)” already exists in the destination.")))
            }
            do {
                try operation(source, target)
                return ItemResult(source: source, outcome: .success(target))
            } catch {
                return ItemResult(source: source, outcome: .failure(FileOpError(error)))
            }
        }
    }
}
```

- [ ] **Step 4: Verify green ×2** (~226, recount honestly).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: FileOperationService with per-item results"`

---

### Task 2: UndoRecorder + PaneState op wrappers (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/UndoRecorder.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerTests/UndoTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/UndoTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func undoTests() async {
    let fm = FileManager.default

    await test("PaneState move + undo round-trips through the UndoManager") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("m.txt"))

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.moveSelected([dir.appendingPathComponent("m.txt")], into: sub)
        expect(fm.fileExists(atPath: sub.appendingPathComponent("m.txt").path),
               "moved into sub")
        expect(undoManager.canUndo, "undo registered")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))   // undo op is async inside
        expect(fm.fileExists(atPath: dir.appendingPathComponent("m.txt").path),
               "undo moved it back")
        expect(undoManager.canRedo, "redo available")
    }

    await test("PaneState trash + undo restores the file") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let doomed = dir.appendingPathComponent("t.txt")
        try Data("keep me".utf8).write(to: doomed)

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.trashSelected([doomed])
        expect(!fm.fileExists(atPath: doomed.path), "trashed")
        expect(undoManager.canUndo, "undo registered")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(fm.fileExists(atPath: doomed.path), "restored from trash")
        expectEqual(try? String(contentsOf: doomed, encoding: .utf8), "keep me",
                    "contents intact")
    }

    await test("newFolder undo trashes the created folder; failures don't register undo") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.createNewFolder()
        let created = dir.appendingPathComponent("untitled folder")
        expect(fm.fileExists(atPath: created.path), "folder created")
        expect(undoManager.canUndo, "undo registered")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: created.path), "undo removed the folder")

        let before = undoManager.canUndo
        await pane.moveSelected([dir.appendingPathComponent("nope.txt")], into: dir)
        expectEqual(undoManager.canUndo, before,
                    "an all-failure operation registers no undo")
        expect(pane.errorMessage != nil, "failure surfaced to errorMessage")
    }
}
```

Add `await undoTests()` to `main.swift` after `await fileOperationTests()`.

- [ ] **Step 2: Verify red.**

- [ ] **Step 3: Implement.** Create `Sources/FileExplorerCore/UndoRecorder.swift`:

```swift
import Foundation

/// Registers inverse file operations on an UndoManager. All closures hop back
/// to the MainActor and re-drive PaneState so undo also reloads/refreshes.
@MainActor
public enum UndoRecorder {
    public static func recordMove(_ moves: [(from: URL, to: URL)],
                                  on undoManager: UndoManager,
                                  pane: PaneState) {
        guard !moves.isEmpty else { return }
        undoManager.registerUndo(withTarget: pane) { pane in
            MainActor.assumeIsolated {
                Task {
                    for move in moves {
                        _ = FileOperationService.move(
                            [move.to], into: move.from.deletingLastPathComponent())
                    }
                    await pane.reload()
                    UndoRecorder.recordMove(
                        moves.map { (from: $0.to, to: $0.from) },
                        on: undoManager, pane: pane)
                }
            }
        }
        undoManager.setActionName("Move")
    }

    public static func recordTrash(_ trashes: [(original: URL, trashed: URL)],
                                   on undoManager: UndoManager,
                                   pane: PaneState) {
        guard !trashes.isEmpty else { return }
        undoManager.registerUndo(withTarget: pane) { pane in
            MainActor.assumeIsolated {
                Task {
                    var restored: [(from: URL, to: URL)] = []
                    for item in trashes {
                        let parent = item.original.deletingLastPathComponent()
                        if case .success(let back) =
                            FileOperationService.move([item.trashed], into: parent)[0].outcome {
                            restored.append((from: item.original, to: back))
                        }
                    }
                    await pane.reload()
                    // Redo of a restore = trash again.
                    UndoRecorder.recordCreation(restored.map(\.to),
                                                actionName: "Move to Trash",
                                                on: undoManager, pane: pane)
                }
            }
        }
        undoManager.setActionName("Move to Trash")
    }

    /// Undo for created items (copies, new folders): trash them.
    public static func recordCreation(_ created: [URL],
                                      actionName: String,
                                      on undoManager: UndoManager,
                                      pane: PaneState) {
        guard !created.isEmpty else { return }
        undoManager.registerUndo(withTarget: pane) { pane in
            MainActor.assumeIsolated {
                Task {
                    let results = FileOperationService.trash(created)
                    let trashed = results.compactMap { result -> (URL, URL)? in
                        if case .success(let url) = result.outcome {
                            return (result.source, url)
                        }
                        return nil
                    }
                    await pane.reload()
                    UndoRecorder.recordTrash(
                        trashed.map { (original: $0.0, trashed: $0.1) },
                        on: undoManager, pane: pane)
                }
            }
        }
        undoManager.setActionName(actionName)
    }
}
```

In `PaneState.swift` add:

```swift
    /// Window-level UndoManager, injected by the UI (or tests).
    @ObservationIgnored public weak var undoManager: UndoManager?
```

and the async op wrappers (near `reload()`):

```swift
    public func moveSelected(_ urls: [URL], into destination: URL) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.move(urls, into: destination)
        }.value
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordMove(
                successes.map { (from: $0.source, to: $0.destination) },
                on: undoManager, pane: self)
        }
        await reload()
    }

    public func copySelected(_ urls: [URL], into destination: URL) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.copy(urls, into: destination)
        }.value
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordCreation(successes.map(\.destination),
                                        actionName: "Copy",
                                        on: undoManager, pane: self)
        }
        await reload()
    }

    public func trashSelected(_ urls: [URL]) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.trash(urls)
        }.value
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordTrash(
                successes.map { (original: $0.source, trashed: $0.destination) },
                on: undoManager, pane: self)
        }
        selection.removeAll()
        await reload()
    }

    public func renameSelected(_ url: URL, to newName: String) async {
        switch FileOperationService.rename(url, to: newName) {
        case .success(let newURL):
            if let undoManager {
                UndoRecorder.recordMove([(from: url, to: newURL)],
                                        on: undoManager, pane: self)
                undoManager.setActionName("Rename")
            }
            errorMessage = nil
            selection = [newURL.standardizedFileURL]
        case .failure(let error):
            errorMessage = error.message
        }
        await reload()
    }

    public func createNewFolder() async {
        switch FileOperationService.newFolder(in: currentURL) {
        case .success(let url):
            if let undoManager {
                UndoRecorder.recordCreation([url], actionName: "New Folder",
                                            on: undoManager, pane: self)
            }
            errorMessage = nil
            selection = [url.standardizedFileURL]
        case .failure(let error):
            errorMessage = error.message
        }
        await reload()
    }

    private struct OperationSuccess {
        let source: URL
        let destination: URL
    }

    private func finishOperation(
        results: [FileOperationService.ItemResult],
        recordUndo: ([OperationSuccess]) -> Void
    ) {
        let successes = results.compactMap { result -> OperationSuccess? in
            if case .success(let url) = result.outcome {
                return OperationSuccess(source: result.source, destination: url)
            }
            return nil
        }
        let failures = results.filter {
            if case .failure = $0.outcome { return true }
            return false
        }
        if failures.isEmpty {
            errorMessage = nil
        } else {
            let details = failures.prefix(3).compactMap { result -> String? in
                if case .failure(let error) = result.outcome { return error.message }
                return nil
            }.joined(separator: " ")
            let suffix = failures.count > 3 ? " (+\(failures.count - 3) more)" : ""
            errorMessage = details + suffix
        }
        recordUndo(successes)
    }
```

NOTE: `errorMessage` is currently used by the overlay for LOAD errors; op failures reuse it — the overlay only shows when `visibleEntries.isEmpty`, so surface op failures in the status bar too: that's Task 3's UI job. Core-side this is fine.

- [ ] **Step 4: Verify green ×2** (~239, recount honestly). The undo closures are async — the tests sleep 400 ms after `undoManager.undo()`; if flaky once, re-run; persistent → investigate.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: undoable move/copy/trash/rename/new-folder on PaneState"`

---

### Task 3: Context menus + Edit/File menu wiring + rename sheet

**Files:**
- Create: `Sources/FileExplorer/FileActionsMenu.swift`
- Create: `Sources/FileExplorer/RenameSheet.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/ThumbnailGridView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

UI glue — no unit tests. NO @State/@FocusState.

- [ ] **Step 1: Create `Sources/FileExplorer/RenameSheet.swift`**

```swift
import SwiftUI
import FileExplorerCore

/// Sheet state for single-item rename (no @State on this toolchain).
@MainActor
@Observable
final class RenameSheetModel {
    var target: URL?
    var draftName = ""

    var isPresented: Bool { target != nil }

    func present(for url: URL) {
        target = url
        draftName = url.lastPathComponent
    }

    func dismiss() {
        target = nil
        draftName = ""
    }
}

struct RenameSheet: View {
    @Bindable var model: RenameSheetModel
    var onConfirm: (URL, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename")
                .font(.headline)
            TextField("Name", text: $model.draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { confirm() }
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draftName.isEmpty)
            }
        }
        .padding(20)
    }

    private func confirm() {
        guard let target = model.target, !model.draftName.isEmpty else { return }
        let newName = model.draftName
        model.dismiss()
        onConfirm(target, newName)
    }
}
```

- [ ] **Step 2: Create `Sources/FileExplorer/FileActionsMenu.swift`** — shared context-menu builder used by table and grid:

```swift
import SwiftUI
import AppKit
import FileExplorerCore

/// Context-menu actions for a set of selected URLs in a pane. Used by both
/// the table (contextMenu forSelectionType) and the grid.
@MainActor
struct FileActions {
    let pane: PaneState
    let otherPane: PaneState?
    let renameModel: RenameSheetModel

    @ViewBuilder
    func menu(for urls: Set<URL>) -> some View {
        let targets = Array(urls)
        Button("Open") {
            for url in targets { NSWorkspace.shared.open(url) }
        }
        .disabled(targets.isEmpty)
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("Rename…") {
            if let url = targets.first { renameModel.present(for: url) }
        }
        .disabled(targets.count != 1)
        Button("New Folder") {
            Task { await pane.createNewFolder() }
        }
        if let otherPane {
            Divider()
            Button("Move to Other Pane") {
                Task { await pane.moveSelected(targets, into: otherPane.currentURL) }
            }
            .disabled(targets.isEmpty)
            Button("Copy to Other Pane") {
                Task { await pane.copySelected(targets, into: otherPane.currentURL) }
            }
            .disabled(targets.isEmpty)
        }
        Divider()
        Button("Move to Trash") {
            Task { await pane.trashSelected(targets) }
        }
        .disabled(targets.isEmpty)
    }
}
```

- [ ] **Step 3: Wire into `Sources/FileExplorer/PaneView.swift`.**

Add stored properties (after `hoverModel`):

```swift
    var otherPane: PaneState?
    private let renameModel = RenameSheetModel()
```

(`otherPane` is passed by PaneAreaView — Step 5.)

Give PaneView the window's undo manager and inject it (add inside the struct):

```swift
    @Environment(\.undoManager) private var undoManager
```

and at the END of `body`'s VStack chain append:

```swift
        .onAppear { pane.undoManager = undoManager }
        .onChange(of: pane.currentURL) { _, _ in pane.undoManager = undoManager }
        .sheet(isPresented: Binding(
            get: { renameModel.isPresented },
            set: { if !$0 { renameModel.dismiss() } })) {
            RenameSheet(model: renameModel) { url, newName in
                Task { await pane.renameSelected(url, to: newName) }
            }
        }
```

(If `@Environment(\.undoManager)` fails to compile — it's a property wrapper, expected to work — fall back to `NSApp.keyWindow?.undoManager` inside onAppear and report.)

Replace the empty `.contextMenu(forSelectionType: URL.self) { _ in ... }` on the table with:

```swift
        .contextMenu(forSelectionType: URL.self) { urls in
            FileActions(pane: pane, otherPane: otherPane,
                        renameModel: renameModel).menu(for: urls)
        } primaryAction: { urls in
            open(urls)
        }
```

Add keyboard delete: append to the same `Group` that has `.onKeyPress(.space)`:

```swift
        .onKeyPress(.init("\u{7F}"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let targets = Array(pane.selection)
            guard !targets.isEmpty else { return .ignored }
            Task { await pane.trashSelected(targets) }
            return .handled
        }
```

(If `KeyEquivalent("\u{7F}")` misbehaves, use `.onKeyPress(.delete)` if available, or attach ⌘⌫ to a File-menu item instead — report which shipped. A File-menu "Move to Trash" ⌘⌫ item is ALSO added in Step 6 regardless, so the menu path always works.)

- [ ] **Step 4: Grid context menu — `Sources/FileExplorer/ThumbnailGridView.swift`.**

ThumbnailGridView gains the same properties (`var otherPane: PaneState?`, and receive `renameModel` — simplest: give ThumbnailGridView `let actions: FileActions` built by PaneView). Change ThumbnailGridView:

```swift
struct ThumbnailGridView: View {
    @Bindable var pane: PaneState
    var actions: FileActions
    var open: (Set<URL>) -> Void
```

and replace the empty `.contextMenu { }` on cells with:

```swift
                        .contextMenu {
                            actions.menu(for: pane.selection.contains(entry.url)
                                         ? pane.selection : [entry.url])
                        }
```

In PaneView's body, update the call site:

```swift
                ThumbnailGridView(
                    pane: pane,
                    actions: FileActions(pane: pane, otherPane: otherPane,
                                         renameModel: renameModel)) { open($0) }
```

- [ ] **Step 5: Pass `otherPane` — `Sources/FileExplorer/TabBarView.swift`.** In `PaneAreaView.pane(at:)`, change the `PaneView(pane: paneState)` construction to:

```swift
            PaneView(pane: paneState,
                     otherPane: tab.isDual ? tab.panes[1 - index] : nil)
```

- [ ] **Step 6: File menu items — `Sources/FileExplorer/FileExplorerApp.swift`.** In `CommandGroup(after: .newItem)` (with New Tab/Close Tab), add before New Tab:

```swift
                Button("New Folder") {
                    Task { await session.activePane.createNewFolder() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Move to Trash") {
                    let targets = Array(session.activePane.selection)
                    guard !targets.isEmpty else { return }
                    Task { await session.activePane.trashSelected(targets) }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                Divider()
```

(SwiftUI provides Undo/Redo in the Edit menu automatically via the responder chain's undoManager — verify at runtime that ⌘Z shows "Undo Move" after a move; if the Edit menu is missing them, note for walkthrough.)

- [ ] **Step 7: Verify** — `swift build` clean; greps clean; `swift run FileExplorerTests` PASS (unchanged); launch check.

- [ ] **Step 8: Commit** — `git add -A && git commit -m "feat: context menus, rename sheet, trash/new-folder commands with undo"`

---

### Task 4: Drag out of the app

**Files:**
- Modify: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/ThumbnailGridView.swift`

- [ ] **Step 1: Table rows.** SwiftUI `Table` on macOS supports row drag via `TableColumn` content `.draggable(...)`? No — the supported hook is `.itemProvider` on ForEach-style content or `Table`'s `TableRow` init. Our Table uses the collection initializer, so attach to the Name cell's HStack in PaneView:

```swift
                .draggable(entry.url)
```

(URL conforms to Transferable.) If `.draggable` on a cell view compiles but drags only the cell visual, that's acceptable v1 (dragging exports the file URL — Finder accepts it as a copy).

- [ ] **Step 2: Grid cells.** In ThumbnailGridView's ForEach cell chain add `.draggable(entry.url)` before the gestures. NOTE: `.draggable` adds its own drag gesture — verify the tap/double-tap gestures still fire (build + walkthrough); if they conflict badly, keep `.draggable` ONLY on the grid image portion, or drop grid drag support and report.

- [ ] **Step 3: Verify** — build clean, tests unchanged, launch check. Actual drag behavior → walkthrough.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: drag files out to Finder"`

---

### Task 5: Interactive verification + merge prep

- [ ] **Step 1:** `swift run FileExplorerTests` ×2; `./Scripts/bundle.sh`; idle check.
- [ ] **Step 2:** Interactive (UI automation works on this machine — System Events menu clicks, AX reads, screenshots; synthetic raw mouse clicks are unreliable, prefer menu/keyboard/AX):
  - New Folder via File menu in a temp-ish folder (navigate via ⌘G to a temp dir created for the test); verify "untitled folder" appears (AX row read).
  - Rename… via context menu is mouse-bound — use the File-menu-less path: select the folder via AX, invoke rename through the sheet? Context menus need right-click (unreliable) — verify the RENAME SHEET opens if achievable, else mark MANUAL.
  - Move to Trash via File menu (⌘⌫): select the untitled folder (AX), File → Move to Trash, verify gone; **Edit menu: does it show "Undo New Folder"/"Undo Move to Trash"? Click Undo — folder returns?** This is the headline check (undo through the real window UndoManager).
  - Dual pane: ⇧⌘D, verify "Move to Other Pane"/"Copy to Other Pane" exist in the context menu (AX menu inspection if possible) — else MANUAL.
  - Clean up all test artifacts.
- [ ] **Step 3:** Fix small real bugs found (commit `fix: … (milestone 6a verification)`); structural → report.
