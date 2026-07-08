# FileExplorer Milestone 9 (Daily-Driver Ops + App Icon) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the everyday Finder-parity gaps — clipboard copy/paste of files, duplicate, new file, copy path, Open With, archive extraction, a Get Info panel — and give the app a real, reproducibly-generated icon.

**Architecture:** Pure naming/detection logic lands in Core as unit-testable helpers (`CollisionNamer`, `ArchiveKind`); blocking work follows the existing service pattern (`Unarchiver`, `InfoGatherer` beside `Zipper`/`FolderSizer`); `PaneState` gains thin async wrappers that reload + record undo exactly like the M6 ops. Clipboard and Open With are AppKit bridges in the app target. The icon is drawn by a new `IconGen` executable target and baked to `.icns` by a script; the generated `.icns` is committed.

**Tech Stack:** Swift 6 SPM, CLT-only toolchain — **NO `@State`/`@FocusState`** (transient UI state lives on `@Observable` models), no `xcodebuild`/`swift test`. Tests: `swift run FileExplorerTests` (462 assertions at start; counts are estimates — recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-9-daily-driver`.

**Approved decisions (v3 spec `docs/superpowers/specs/2026-07-08-fileexplorer-v3-design.md`):**
- ⌘V pastes as **copy** with Finder-style auto-rename on collision ("name copy.ext"); ⌥⌘V pastes as **move** (collisions fail loudly via the existing `move`). ⌘C writes real file URLs so copy/paste interoperates with Finder both ways.
- ⌘D duplicates next to the source with the same "name copy" naming. ⌥⌘N creates an empty `untitled` file (no prompt — created selected, Return renames, same flow as New Folder).
- Extraction: zip via `ditto -x -k`, tarballs via `tar -xf`, into a collision-suffixed folder named after the archive stem; the folder registers delete-as-undo.
- Get Info is a **read-only** panel window (⌘I) following the active pane's selection. SHA-256 arrives in M11, not here.
- Icon drawn in code (CoreGraphics, dual-pane motif), rendered by `Scripts/make-icon.sh` (`sips` + `iconutil`), `.icns` **committed** so `bundle.sh` never depends on regeneration.

**File map:**
- Create: `Sources/FileExplorerCore/CollisionNamer.swift`, `ArchiveKind.swift`, `Unarchiver.swift`, `InfoGatherer.swift`, `GetInfoModel.swift`
- Create: `Sources/FileExplorer/PasteboardOps.swift`, `GetInfoView.swift`
- Create: `Sources/IconGen/main.swift`, `Scripts/make-icon.sh`, `Resources/FileExplorer.icns` (generated, committed)
- Modify: `Sources/FileExplorerCore/FileOperationService.swift`, `PaneState.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`, `FileActionsMenu.swift`
- Modify: `Package.swift`, `Resources/Info.plist`, `Scripts/bundle.sh`, `README.md`
- Create tests: `Sources/FileExplorerTests/CollisionNamerTests.swift`, `ArchiveTests.swift`, `InfoGathererTests.swift`, `DailyOpsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

---

### Task 1: CollisionNamer (pure naming, TDD)

**Files:**
- Create: `Sources/FileExplorerCore/CollisionNamer.swift`
- Create: `Sources/FileExplorerTests/CollisionNamerTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Branch**

```bash
cd /Users/mlaplante/Sites/fileexplorer
git checkout main && git checkout -b milestone-9-daily-driver
```

- [ ] **Step 2: Failing tests — `Sources/FileExplorerTests/CollisionNamerTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func collisionNamerTests() async {
    await test("copyName leaves a free name unchanged") {
        expectEqual(CollisionNamer.copyName(for: "photo.jpg", existing: []),
                    "photo.jpg", "free name passes through")
    }

    await test("copyName appends ' copy' before the extension") {
        expectEqual(CollisionNamer.copyName(for: "photo.jpg", existing: ["photo.jpg"]),
                    "photo copy.jpg", "first collision")
        expectEqual(CollisionNamer.copyName(
                        for: "photo.jpg",
                        existing: ["photo.jpg", "photo copy.jpg"]),
                    "photo copy 2.jpg", "second collision counts from 2")
        expectEqual(CollisionNamer.copyName(
                        for: "photo.jpg",
                        existing: ["photo.jpg", "photo copy.jpg", "photo copy 2.jpg"]),
                    "photo copy 3.jpg", "counter keeps climbing")
    }

    await test("copyName handles extensionless and dotfile names") {
        expectEqual(CollisionNamer.copyName(for: "Makefile", existing: ["Makefile"]),
                    "Makefile copy", "no extension → suffix at end")
        expectEqual(CollisionNamer.copyName(for: ".env", existing: [".env"]),
                    ".env copy", "dotfile keeps the whole name as stem")
    }

    await test("sequentialName finds the first free numbered name") {
        expectEqual(CollisionNamer.sequentialName(base: "untitled", existing: []),
                    "untitled", "free base name")
        expectEqual(CollisionNamer.sequentialName(base: "untitled",
                                                  existing: ["untitled"]),
                    "untitled 2", "first collision → 2")
        expectEqual(CollisionNamer.sequentialName(
                        base: "untitled", existing: ["untitled", "untitled 2"]),
                    "untitled 3", "keeps climbing")
    }
}
```

- [ ] **Step 3: Register** — in `Sources/FileExplorerTests/main.swift`, add `await collisionNamerTests()` after `await fuzzyMatcherTests()`.

- [ ] **Step 4: Run to verify failure** — `swift run FileExplorerTests 2>&1 | tail -5`; expect a compile error (`CollisionNamer` undefined).

- [ ] **Step 5: Implement — `Sources/FileExplorerCore/CollisionNamer.swift`**

```swift
import Foundation

/// Pure collision-free naming. Callers pass the set of names already taken
/// in the destination (from a directory listing); the actual filesystem
/// operation is still the authority and fails loudly if a race slips a
/// collision past the listing.
public enum CollisionNamer {
    /// Splits "name.ext" into ("name", ".ext"). Dotfiles and extensionless
    /// names keep the whole name as the stem.
    static func split(_ name: String) -> (stem: String, ext: String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        guard !ext.isEmpty, !stem.isEmpty else { return (name, "") }
        return (stem, "." + ext)
    }

    /// Finder-style duplicate/paste naming: "photo.jpg" → "photo copy.jpg"
    /// → "photo copy 2.jpg" → … Returns `name` unchanged when it's free.
    public static func copyName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let (stem, ext) = split(name)
        var candidate = "\(stem) copy\(ext)"
        var counter = 1
        while existing.contains(candidate) {
            counter += 1
            candidate = "\(stem) copy \(counter)\(ext)"
        }
        return candidate
    }

    /// "untitled" → "untitled 2" → "untitled 3" → … (New File, extraction
    /// folder). Matches the counting style newFolder has always used.
    public static func sequentialName(base: String, existing: Set<String>) -> String {
        var candidate = base
        var counter = 1
        while existing.contains(candidate) {
            counter += 1
            candidate = "\(base) \(counter)"
        }
        return candidate
    }
}
```

- [ ] **Step 6: Run tests** — `swift run FileExplorerTests 2>&1 | tail -3`; expect `PASS`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FileExplorerCore/CollisionNamer.swift \
        Sources/FileExplorerTests/CollisionNamerTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: CollisionNamer for Finder-style duplicate/paste naming"
```

---

### Task 2: New File, Duplicate, collision-safe copy (service + pane, TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/FileOperationService.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerTests/DailyOpsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/DailyOpsTests.swift`**

Follow the temp-directory pattern from `FileOperationTests.swift`: create a scratch dir under `FileManager.default.temporaryDirectory`, remove it after each test.

```swift
import Foundation
import FileExplorerCore

@MainActor
func dailyOpsTests() async {
    func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-dailyops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func write(_ name: String, in dir: URL, contents: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    await test("newFile creates untitled, then untitled 2") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FileOperationService.newFile(in: dir)
        guard case .success(let firstURL) = first else {
            return expect(false, "first newFile succeeds")
        }
        expectEqual(firstURL.lastPathComponent, "untitled", "first name")
        expect(FileManager.default.fileExists(atPath: firstURL.path), "file exists")
        let second = FileOperationService.newFile(in: dir)
        guard case .success(let secondURL) = second else {
            return expect(false, "second newFile succeeds")
        }
        expectEqual(secondURL.lastPathComponent, "untitled 2", "second name")
    }

    await test("copyAvoidingCollisions renames instead of failing") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("a.txt", in: dir, contents: "hello")
        let results = FileOperationService.copyAvoidingCollisions([source], into: dir)
        guard case .success(let copy) = results[0].outcome else {
            return expect(false, "copy into own folder succeeds via rename")
        }
        expectEqual(copy.lastPathComponent, "a copy.txt", "Finder-style name")
        expectEqual(try String(contentsOf: copy, encoding: .utf8), "hello",
                    "contents copied")
    }

    await test("copyAvoidingCollisions still refuses a folder into itself") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let results = FileOperationService.copyAvoidingCollisions([dir], into: dir)
        guard case .failure = results[0].outcome else {
            return expect(false, "folder-into-itself is rejected")
        }
        expect(true, "rejected")
    }

    await test("pane duplicateSelected copies next to source, selects, undoes") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("doc.txt", in: dir)
        let pane = PaneState(url: dir)
        let undo = UndoManager()
        pane.undoManager = undo
        await pane.duplicateSelected([source])
        let copy = dir.appendingPathComponent("doc copy.txt")
        expect(FileManager.default.fileExists(atPath: copy.path), "duplicate exists")
        expectEqual(pane.selection, [copy.standardizedFileURL],
                    "duplicate is selected")
        expect(undo.canUndo, "duplicate registered undo")
        undo.undo()
        try? await Task.sleep(for: .milliseconds(100))
        expect(!FileManager.default.fileExists(atPath: copy.path),
               "undo trashed the duplicate")
    }

    await test("pane createNewFile selects the new file and undoes") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneState(url: dir)
        let undo = UndoManager()
        pane.undoManager = undo
        await pane.createNewFile()
        let created = dir.appendingPathComponent("untitled")
        expect(FileManager.default.fileExists(atPath: created.path), "file created")
        expectEqual(pane.selection, [created.standardizedFileURL], "selected")
        undo.undo()
        try? await Task.sleep(for: .milliseconds(100))
        expect(!FileManager.default.fileExists(atPath: created.path),
               "undo trashed the new file")
    }

    await test("pane pasteCopy into same folder auto-renames and undoes") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("p.txt", in: dir)
        let pane = PaneState(url: dir)
        let undo = UndoManager()
        pane.undoManager = undo
        await pane.pasteCopy([source])
        let pasted = dir.appendingPathComponent("p copy.txt")
        expect(FileManager.default.fileExists(atPath: pasted.path), "pasted copy exists")
        expect(pane.opErrorMessage == nil, "no error reported")
        expect(undo.canUndo, "paste registered undo")
    }
}
```

- [ ] **Step 2: Register** — in `main.swift`, add `await dailyOpsTests()` after `await collisionNamerTests()`.

- [ ] **Step 3: Run to verify failure** — `swift run FileExplorerTests 2>&1 | tail -5`; expect compile errors (`newFile`, `copyAvoidingCollisions`, `duplicateSelected` undefined).

- [ ] **Step 4: Implement service additions — `Sources/FileExplorerCore/FileOperationService.swift`**

Add after `newFolder(in:)`:

```swift
    /// Creates "untitled", "untitled 2", … empty file and returns it.
    public static func newFile(in directory: URL) -> Result<URL, FileOpError> {
        let fm = FileManager.default
        let existing = Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
        let name = CollisionNamer.sequentialName(base: "untitled", existing: existing)
        let target = directory.appendingPathComponent(name)
        guard fm.createFile(atPath: target.path, contents: Data()) else {
            return .failure(FileOpError("Couldn't create “\(name)”."))
        }
        return .success(target)
    }

    /// Copies into `destination`, auto-renaming Finder-style ("name copy.ext")
    /// instead of failing on collisions — paste/duplicate semantics, where a
    /// collision is expected rather than an error. The folder-into-itself
    /// guard matches `perform`.
    public static func copyAvoidingCollisions(_ sources: [URL],
                                              into destination: URL) -> [ItemResult] {
        let fm = FileManager.default
        return sources.map { source in
            let sourcePath = source.standardizedFileURL.path
            let destinationPath = destination.standardizedFileURL.path
            if destinationPath == sourcePath
                || destinationPath.hasPrefix(sourcePath + "/") {
                return ItemResult(source: source, outcome: .failure(FileOpError(
                    "Can't put “\(source.lastPathComponent)” inside itself.")))
            }
            let existing = Set(
                (try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
            let name = CollisionNamer.copyName(for: source.lastPathComponent,
                                               existing: existing)
            let target = destination.appendingPathComponent(name)
            do {
                try fm.copyItem(at: source, to: target)
                return ItemResult(source: source, outcome: .success(target))
            } catch {
                return ItemResult(source: source, outcome: .failure(FileOpError(error)))
            }
        }
    }
```

- [ ] **Step 5: Implement pane wrappers — `Sources/FileExplorerCore/PaneState.swift`**

Add after `createNewFolder()`, following its exact structure (reload first, then bookkeeping — see the NOTE comment above `moveSelected`):

```swift
    public func createNewFile() async {
        let result = FileOperationService.newFile(in: currentURL)
        await reload()
        switch result {
        case .success(let url):
            if let undoManager {
                UndoRecorder.recordCreation([url], actionName: "New File",
                                            on: undoManager, pane: self)
            }
            opErrorMessage = nil
            selection = [url.standardizedFileURL]
        case .failure(let error):
            opErrorMessage = error.message
        }
    }

    /// Duplicates each item next to itself ("name copy.ext"), selects the
    /// duplicates, one undo step (trash the copies).
    public func duplicateSelected(_ urls: [URL]) async {
        let results = await Task.detached(priority: .userInitiated) {
            urls.flatMap { url in
                FileOperationService.copyAvoidingCollisions(
                    [url], into: url.deletingLastPathComponent())
            }
        }.value
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordCreation(successes.map(\.destination),
                                        actionName: "Duplicate",
                                        on: undoManager, pane: self)
        }
        let created = results.compactMap { result -> URL? in
            if case .success(let url) = result.outcome { return url }
            return nil
        }
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }

    /// Paste-as-copy into the current folder: collisions auto-rename
    /// (Finder ⌘V). Paste-as-move (⌥⌘V) reuses `moveSelected`, whose
    /// fail-loudly collision policy matches Finder's move-paste prompt.
    public func pasteCopy(_ urls: [URL]) async {
        let destination = currentURL
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.copyAvoidingCollisions(urls, into: destination)
        }.value
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordCreation(successes.map(\.destination),
                                        actionName: "Paste",
                                        on: undoManager, pane: self)
        }
    }
```

- [ ] **Step 6: Run tests** — `swift run FileExplorerTests 2>&1 | tail -3`; expect `PASS`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FileExplorerCore/FileOperationService.swift \
        Sources/FileExplorerCore/PaneState.swift \
        Sources/FileExplorerTests/DailyOpsTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: new file, duplicate, and collision-safe paste-copy operations"
```

---

### Task 3: Clipboard commands + menu wiring (⌘C/⌘V/⌥⌘V/⌘D/⌥⌘N, Copy Path)

**Files:**
- Create: `Sources/FileExplorer/PasteboardOps.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`
- Modify: `Sources/FileExplorer/FileActionsMenu.swift`

No new unit tests — this task is AppKit/menu glue over the Task 2 logic; behavior lands on the manual walkthrough (Task 8). Build must stay green.

- [ ] **Step 1: Create `Sources/FileExplorer/PasteboardOps.swift`**

```swift
import AppKit

/// File-URL clipboard bridge. URLs are written as NSURL pasteboard objects
/// so copy/paste interoperates with Finder in both directions.
///
/// The app-level Edit commands below replace SwiftUI's default pasteboard
/// group, which would otherwise swallow ⌘C/⌘V from text fields (rename
/// sheet, filter bar). Each command therefore checks whether a field editor
/// owns focus and forwards to it via the responder chain instead of acting
/// on files.
@MainActor
enum PasteboardOps {
    static func copyToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    static func copyString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func readFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    /// True when a text field editor owns focus in the key window.
    static var textEditingIsActive: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    static func forwardToFieldEditor(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
```

- [ ] **Step 2: Add the Edit commands — `Sources/FileExplorer/FileExplorerApp.swift`**

Inside `.commands { … }`, add a new group (place it before the existing `CommandGroup(after: .newItem)`):

```swift
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    PasteboardOps.forwardToFieldEditor(#selector(NSText.cut(_:)))
                }
                .keyboardShortcut("x", modifiers: .command)
                Button("Copy") {
                    if PasteboardOps.textEditingIsActive {
                        PasteboardOps.forwardToFieldEditor(#selector(NSText.copy(_:)))
                    } else {
                        PasteboardOps.copyToPasteboard(
                            Array(session.activePane.selection))
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    if PasteboardOps.textEditingIsActive {
                        PasteboardOps.forwardToFieldEditor(#selector(NSText.paste(_:)))
                    } else {
                        let urls = PasteboardOps.readFileURLs()
                        guard !urls.isEmpty else { return }
                        Task { await session.activePane.pasteCopy(urls) }
                    }
                }
                .keyboardShortcut("v", modifiers: .command)
                Button("Move Item Here") {
                    let urls = PasteboardOps.readFileURLs()
                    guard !urls.isEmpty else { return }
                    let pane = session.activePane
                    Task { await pane.moveSelected(urls, into: pane.currentURL) }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                Button("Select All") {
                    if PasteboardOps.textEditingIsActive {
                        PasteboardOps.forwardToFieldEditor(
                            #selector(NSText.selectAll(_:)))
                    } else {
                        session.activePane.selection =
                            Set(session.activePane.visibleEntries.map(\.url))
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
            }
```

- [ ] **Step 3: Add Duplicate and New File to the File commands — `FileExplorerApp.swift`**

In `CommandGroup(after: .newItem)`, after the "New Folder" button:

```swift
                Button("New File") {
                    Task { await session.activePane.createNewFile() }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Duplicate") {
                    let targets = Array(session.activePane.selection)
                    guard !targets.isEmpty else { return }
                    Task { await session.activePane.duplicateSelected(targets) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session.activePane.selection.isEmpty)
```

- [ ] **Step 4: Context-menu additions — `Sources/FileExplorer/FileActionsMenu.swift`**

After the "Reveal in Finder" button (before the first `Divider()`):

```swift
        Button("Copy") {
            PasteboardOps.copyToPasteboard(targets)
        }
        .disabled(targets.isEmpty)
        Button("Duplicate") {
            Task { await pane.duplicateSelected(targets) }
        }
        .disabled(targets.isEmpty)
        Menu("Copy Path") {
            Button("POSIX Path") {
                PasteboardOps.copyString(
                    targets.map(\.path).joined(separator: "\n"))
            }
            Button("Abbreviated (~) Path") {
                PasteboardOps.copyString(
                    targets.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        .joined(separator: "\n"))
            }
        }
        .disabled(targets.isEmpty)
```

And after the "New Folder" button:

```swift
        Button("New File") {
            Task { await pane.createNewFile() }
        }
```

- [ ] **Step 5: Build and run tests** — `swift build 2>&1 | tail -3 && swift run FileExplorerTests 2>&1 | tail -3`; expect clean build, `PASS`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FileExplorer/PasteboardOps.swift \
        Sources/FileExplorer/FileExplorerApp.swift \
        Sources/FileExplorer/FileActionsMenu.swift
git commit -m "feat: clipboard file ops, duplicate/new-file commands, copy path"
```

---

### Task 4: Open With submenu

**Files:**
- Modify: `Sources/FileExplorer/FileActionsMenu.swift`

Manual-walkthrough feature (menu glue only). `NSWorkspace.urlsForApplications(toOpen:)` is macOS 12+, fine for the 15+ target.

- [ ] **Step 1: Add the submenu — `FileActionsMenu.swift`**

Directly after the "Open" button:

```swift
        Menu("Open With") {
            // Candidate apps come from the FIRST item's type (spec decision);
            // the chosen app opens the whole selection.
            if let url = targets.first {
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
                    .sorted {
                        appDisplayName($0).localizedCaseInsensitiveCompare(
                            appDisplayName($1)) == .orderedAscending
                    }
                if let defaultApp {
                    Button("\(appDisplayName(defaultApp)) (default)") {
                        openWith(targets, app: defaultApp)
                    }
                    Divider()
                }
                ForEach(apps.filter { $0 != defaultApp }, id: \.self) { app in
                    Button(appDisplayName(app)) { openWith(targets, app: app) }
                }
                if apps.isEmpty && defaultApp == nil {
                    Text("No Available Applications")
                }
            }
        }
        .disabled(targets.isEmpty)
```

- [ ] **Step 2: Add the helpers** — private methods on `FileActions` (bottom of the struct):

```swift
    private func appDisplayName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path)
    }

    private func openWith(_ urls: [URL], app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
```

- [ ] **Step 3: Build and run tests** — `swift build 2>&1 | tail -3 && swift run FileExplorerTests 2>&1 | tail -3`; expect clean build, `PASS`.

- [ ] **Step 4: Commit**

```bash
git add Sources/FileExplorer/FileActionsMenu.swift
git commit -m "feat: Open With submenu listing capable applications"
```

---

### Task 5: Archive extraction (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/ArchiveKind.swift`, `Sources/FileExplorerCore/Unarchiver.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Modify: `Sources/FileExplorer/FileActionsMenu.swift`
- Create: `Sources/FileExplorerTests/ArchiveTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/ArchiveTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func archiveTests() async {
    await test("ArchiveKind detects supported archives") {
        expectEqual(ArchiveKind.detect("a.zip"), .zip, "zip")
        expectEqual(ArchiveKind.detect("A.ZIP"), .zip, "case-insensitive")
        expectEqual(ArchiveKind.detect("src.tar"), .tarball, "tar")
        expectEqual(ArchiveKind.detect("src.tar.gz"), .tarball, "tar.gz")
        expectEqual(ArchiveKind.detect("src.tgz"), .tarball, "tgz")
        expectEqual(ArchiveKind.detect("src.tar.bz2"), .tarball, "tar.bz2")
        expectEqual(ArchiveKind.detect("src.tar.xz"), .tarball, "tar.xz")
        expect(ArchiveKind.detect("photo.jpg") == nil, "jpg is not an archive")
        expect(ArchiveKind.detect("notes.gz") == nil,
               "bare .gz (not a tarball) is unsupported")
    }

    await test("ArchiveKind.stem strips the archive suffix") {
        expectEqual(ArchiveKind.stem("Photos.zip"), "Photos", "zip stem")
        expectEqual(ArchiveKind.stem("src.tar.gz"), "src", "tar.gz stem")
        expectEqual(ArchiveKind.stem("src.tgz"), "src", "tgz stem")
    }

    await test("Unarchiver round-trips a zip made by Zipper") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = dir.appendingPathComponent("hello.txt")
        try "hello".write(to: payload, atomically: true, encoding: .utf8)
        guard case .success(let archive) = Zipper.compress([payload], in: dir) else {
            return expect(false, "zip created")
        }
        guard case .success(let extracted) = Unarchiver.extract(archive) else {
            return expect(false, "extraction succeeds")
        }
        expectEqual(extracted.lastPathComponent, "Archive", "folder named after stem")
        let inner = extracted.appendingPathComponent("hello.txt")
        expectEqual(try String(contentsOf: inner, encoding: .utf8), "hello",
                    "payload round-trips")
        // A second extraction must not collide.
        guard case .success(let second) = Unarchiver.extract(archive) else {
            return expect(false, "second extraction succeeds")
        }
        expectEqual(second.lastPathComponent, "Archive 2", "collision-suffixed")
    }

    await test("Unarchiver extracts a tarball") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-tar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "world".write(to: dir.appendingPathComponent("w.txt"),
                          atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = dir
        tar.arguments = ["-czf", "bundle.tar.gz", "w.txt"]
        try tar.run()
        tar.waitUntilExit()
        guard case .success(let extracted) =
            Unarchiver.extract(dir.appendingPathComponent("bundle.tar.gz")) else {
            return expect(false, "tar extraction succeeds")
        }
        expectEqual(extracted.lastPathComponent, "bundle", "stem folder")
        let inner = extracted.appendingPathComponent("w.txt")
        expectEqual(try String(contentsOf: inner, encoding: .utf8), "world",
                    "payload round-trips")
    }

    await test("Unarchiver reports corrupt archives and cleans up") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("broken.zip")
        try "not a zip".write(to: fake, atomically: true, encoding: .utf8)
        guard case .failure = Unarchiver.extract(fake) else {
            return expect(false, "corrupt zip fails")
        }
        expect(!FileManager.default.fileExists(
                   atPath: dir.appendingPathComponent("broken").path),
               "partial output folder removed")
    }
}
```

- [ ] **Step 2: Register** — in `main.swift`, add `await archiveTests()` after `await dailyOpsTests()`.

- [ ] **Step 3: Run to verify failure** — `swift run FileExplorerTests 2>&1 | tail -5`; expect compile errors.

- [ ] **Step 4: Implement — `Sources/FileExplorerCore/ArchiveKind.swift`**

```swift
import Foundation

/// Pure detection of extractable archives from a file name. Bare .gz/.bz2
/// (single compressed files, not tarballs) are deliberately unsupported.
public enum ArchiveKind: Equatable, Sendable {
    case zip
    case tarball

    private static let tarSuffixes =
        [".tar.gz", ".tar.bz2", ".tar.xz", ".tar", ".tgz", ".tbz", ".txz"]

    public static func detect(_ name: String) -> ArchiveKind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if tarSuffixes.contains(where: lower.hasSuffix) { return .tarball }
        return nil
    }

    /// "Photos.zip" → "Photos"; "src.tar.gz" → "src". Names without a
    /// recognized suffix pass through unchanged.
    public static func stem(_ name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".zip"] + tarSuffixes where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
```

- [ ] **Step 5: Implement — `Sources/FileExplorerCore/Unarchiver.swift`**

```swift
import Foundation

/// Extracts zip/tar archives into a new collision-suffixed folder next to
/// the archive, via /usr/bin/ditto (zip) and /usr/bin/tar (tarballs, which
/// auto-detect their compression). Blocking — call off the main actor.
/// Failure cleans up the partial output folder.
public enum Unarchiver {
    public static func extract(_ archive: URL)
        -> Result<URL, FileOperationService.FileOpError> {
        guard let kind = ArchiveKind.detect(archive.lastPathComponent) else {
            return .failure(.init(
                "“\(archive.lastPathComponent)” isn't a supported archive."))
        }
        let fm = FileManager.default
        let parent = archive.deletingLastPathComponent()
        let existing = Set((try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
        let folderName = CollisionNamer.sequentialName(
            base: ArchiveKind.stem(archive.lastPathComponent), existing: existing)
        let destination = parent.appendingPathComponent(folderName)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            return .failure(.init(error))
        }

        let process = Process()
        switch kind {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
        case .tarball:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archive.path, "-C", destination.path]
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? fm.removeItem(at: destination)
            return .failure(.init(error))
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            try? fm.removeItem(at: destination)
            return .failure(.init("Extraction failed: \(stderr.prefix(200))"))
        }
        return .success(destination)
    }
}
```

- [ ] **Step 6: Pane wrapper — `Sources/FileExplorerCore/PaneState.swift`**

Add after `compressSelected`:

```swift
    public func extractSelected(_ urls: [URL]) async {
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { (source: $0, result: Unarchiver.extract($0)) }
        }.value
        await reload()
        let created = results.compactMap { item -> URL? in
            if case .success(let url) = item.result { return url }
            return nil
        }
        let failures = results.compactMap { item -> String? in
            if case .failure(let error) = item.result { return error.message }
            return nil
        }
        if let undoManager, !created.isEmpty {
            UndoRecorder.recordCreation(created, actionName: "Extract",
                                        on: undoManager, pane: self)
        }
        opErrorMessage = failures.isEmpty
            ? nil
            : failures.prefix(3).joined(separator: " ")
                + (failures.count > 3 ? " (+\(failures.count - 3) more)" : "")
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }
```

- [ ] **Step 7: Menu item — `Sources/FileExplorer/FileActionsMenu.swift`**

After the "Compress" button:

```swift
        Button("Extract") {
            let archives = targets.filter {
                ArchiveKind.detect($0.lastPathComponent) != nil
            }
            Task { await pane.extractSelected(archives) }
        }
        .disabled(!targets.contains {
            ArchiveKind.detect($0.lastPathComponent) != nil
        })
```

- [ ] **Step 8: Run tests** — `swift run FileExplorerTests 2>&1 | tail -3`; expect `PASS`.

- [ ] **Step 9: Commit**

```bash
git add Sources/FileExplorerCore/ArchiveKind.swift \
        Sources/FileExplorerCore/Unarchiver.swift \
        Sources/FileExplorerCore/PaneState.swift \
        Sources/FileExplorer/FileActionsMenu.swift \
        Sources/FileExplorerTests/ArchiveTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: zip/tar archive extraction with undo"
```

---

### Task 6: Get Info (⌘I panel, TDD on the gatherer)

**Files:**
- Create: `Sources/FileExplorerCore/InfoGatherer.swift`, `Sources/FileExplorerCore/GetInfoModel.swift`
- Create: `Sources/FileExplorer/GetInfoView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`
- Create: `Sources/FileExplorerTests/InfoGathererTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/InfoGathererTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func infoGathererTests() async {
    await test("permissionString renders POSIX modes") {
        expectEqual(InfoGatherer.permissionString(mode: 0o755), "rwxr-xr-x", "755")
        expectEqual(InfoGatherer.permissionString(mode: 0o644), "rw-r--r--", "644")
        expectEqual(InfoGatherer.permissionString(mode: 0o000), "---------", "000")
        expectEqual(InfoGatherer.permissionString(mode: 0o700), "rwx------", "700")
    }

    await test("info(for:) reads a regular file") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("readme.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        guard let info = InfoGatherer.info(for: file) else {
            return expect(false, "info gathered")
        }
        expectEqual(info.name, "readme.txt", "name")
        expect(!info.isDirectory, "not a directory")
        expectEqual(info.size, 2, "size in bytes")
        expectEqual(info.permissions, "rw-r--r--", "permissions string")
        expect(info.modified != nil, "has modified date")
        expect(info.symlinkTarget == nil, "not a symlink")
    }

    await test("info(for:) reports symlink targets and directories") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-info2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        guard let dirInfo = InfoGatherer.info(for: sub) else {
            return expect(false, "directory info gathered")
        }
        expect(dirInfo.isDirectory, "directory flagged")
        expect(dirInfo.size == nil, "directory size deferred (nil)")

        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sub)
        guard let linkInfo = InfoGatherer.info(for: link) else {
            return expect(false, "symlink info gathered")
        }
        expectEqual(linkInfo.symlinkTarget, sub.path, "symlink target path")
    }
}
```

- [ ] **Step 2: Register** — in `main.swift`, add `await infoGathererTests()` after `await archiveTests()`.

- [ ] **Step 3: Run to verify failure** — `swift run FileExplorerTests 2>&1 | tail -5`; expect compile errors.

- [ ] **Step 4: Implement — `Sources/FileExplorerCore/InfoGatherer.swift`**

```swift
import Foundation
import CoreServices
import UniformTypeIdentifiers

/// Everything the Get Info panel shows for one item. Value type so it can
/// cross from a detached gathering task to the MainActor model.
public struct ItemInfo: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let kind: String
    /// nil for directories — recursive size is on-demand (FolderSizer),
    /// never computed implicitly.
    public let size: Int64?
    public let isDirectory: Bool
    public let created: Date?
    public let modified: Date?
    public let permissions: String
    public let owner: String
    public let group: String
    public let whereFroms: [String]
    public let symlinkTarget: String?
}

/// Blocking metadata read — call off the main actor. Uses lstat-style
/// attributes so a symlink reports itself, plus its target for display.
public enum InfoGatherer {
    public static func info(for url: URL) -> ItemInfo? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let type = attrs[.type] as? FileAttributeType
        let isSymlink = type == .typeSymbolicLink
        let isDirectory = type == .typeDirectory
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0

        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        let kind: String
        if isDirectory {
            kind = "Folder"
        } else if isSymlink {
            kind = "Alias (symbolic link)"
        } else {
            kind = values?.contentType?.localizedDescription
                ?? (url.pathExtension.isEmpty ? "Document"
                                              : url.pathExtension.uppercased())
        }

        var whereFroms: [String] = []
        if let mdItem = MDItemCreate(nil, url.path as CFString),
           let value = MDItemCopyAttribute(mdItem, kMDItemWhereFroms) as? [String] {
            whereFroms = value
        }

        return ItemInfo(
            url: url,
            name: url.lastPathComponent,
            kind: kind,
            size: isDirectory ? nil : (attrs[.size] as? NSNumber)?.int64Value,
            isDirectory: isDirectory,
            created: attrs[.creationDate] as? Date,
            modified: attrs[.modificationDate] as? Date,
            permissions: permissionString(mode: mode),
            owner: attrs[.ownerAccountName] as? String ?? "",
            group: attrs[.groupOwnerAccountName] as? String ?? "",
            whereFroms: whereFroms,
            symlinkTarget: isSymlink
                ? (try? fm.destinationOfSymbolicLink(atPath: url.path))
                : nil)
    }

    /// "rwxr-xr-x" from a POSIX mode. Pure.
    public static func permissionString(mode: Int) -> String {
        let bits = ["r", "w", "x"]
        return (0..<9).map { index in
            (mode >> (8 - index)) & 1 == 1 ? bits[index % 3] : "-"
        }.joined()
    }
}
```

- [ ] **Step 5: Run tests** — `swift run FileExplorerTests 2>&1 | tail -3`; expect `PASS`.

- [ ] **Step 6: Model — `Sources/FileExplorerCore/GetInfoModel.swift`**

```swift
import Foundation
import Observation

/// Backs the Get Info panel: re-gathers ItemInfos whenever the observed
/// selection changes. Gathering runs detached; a generation counter drops
/// stale results (same pattern as PaneState.reload).
@MainActor
@Observable
public final class GetInfoModel {
    public private(set) var infos: [ItemInfo] = []
    /// Sum of regular-file sizes across the selection (folders excluded).
    public var totalFileSize: Int64 {
        infos.compactMap(\.size).reduce(0, +)
    }

    private var generation = 0

    public init() {}

    public func update(for urls: [URL]) {
        generation += 1
        let myGeneration = generation
        let targets = urls.sorted { $0.path < $1.path }
        Task {
            let gathered = await Task.detached(priority: .userInitiated) {
                targets.compactMap { InfoGatherer.info(for: $0) }
            }.value
            guard myGeneration == self.generation else { return }
            self.infos = gathered
        }
    }
}
```

- [ ] **Step 7: View — `Sources/FileExplorer/GetInfoView.swift`**

```swift
import SwiftUI
import FileExplorerCore

/// Content of the Get Info window: follows the active pane's selection.
/// No @State on this toolchain — all state lives on GetInfoModel.
struct GetInfoView: View {
    let session: SessionState
    let model: GetInfoModel

    var body: some View {
        Group {
            if model.infos.isEmpty {
                Text("No Selection")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.infos.count == 1, let info = model.infos.first {
                singleItem(info)
            } else {
                multiItem
            }
        }
        .padding()
        .frame(minWidth: 300, idealWidth: 320, minHeight: 340)
        .onAppear { model.update(for: Array(session.activePane.selection)) }
        .onChange(of: session.activePane.selection) { _, newValue in
            model.update(for: Array(newValue))
        }
    }

    @ViewBuilder
    private func singleItem(_ info: ItemInfo) -> some View {
        Form {
            LabeledContent("Name", value: info.name)
            LabeledContent("Kind", value: info.kind)
            if let size = info.size {
                LabeledContent("Size", value: size.formatted(.byteCount(style: .file)))
            } else {
                LabeledContent("Size", value: "— (use Calculate Size)")
            }
            if let created = info.created {
                LabeledContent("Created",
                               value: created.formatted(date: .abbreviated,
                                                        time: .shortened))
            }
            if let modified = info.modified {
                LabeledContent("Modified",
                               value: modified.formatted(date: .abbreviated,
                                                         time: .shortened))
            }
            LabeledContent("Permissions",
                           value: "\(info.permissions)  \(info.owner):\(info.group)")
            if let target = info.symlinkTarget {
                LabeledContent("Links To", value: target)
            }
            if !info.whereFroms.isEmpty {
                LabeledContent("Where From",
                               value: info.whereFroms.joined(separator: "\n"))
            }
            LabeledContent("Location", value: info.url.deletingLastPathComponent()
                .path(percentEncoded: false))
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    private var multiItem: some View {
        VStack(spacing: 12) {
            Text("\(model.infos.count) Items")
                .font(.title2)
            Text("Files: \(model.totalFileSize.formatted(.byteCount(style: .file)))"
                 + " (folders not counted)")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 8: Wire the window + ⌘I — `Sources/FileExplorer/FileExplorerApp.swift`**

Add a stored property to the App struct:

```swift
    private let infoModel = GetInfoModel()
```

Add a second scene after the main `Window`'s closing modifiers (after `.commands { … }` ends, still inside `body`):

```swift
        Window("Info", id: "info") {
            GetInfoView(session: session, model: infoModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.trailing)
```

`openWindow` isn't reachable from the `App` struct directly, so the ⌘I command lives in a small `Commands` type. Add at the bottom of `FileExplorerApp.swift`:

```swift
/// ⌘I lives in its own Commands type because @Environment(\.openWindow)
/// is available to Commands conformances but not to the App struct itself.
struct GetInfoCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Get Info") { openWindow(id: "info") }
                .keyboardShortcut("i", modifiers: .command)
        }
    }
}
```

And register it inside `.commands { … }` (first line of the block):

```swift
            GetInfoCommands()
```

- [ ] **Step 9: Build and run tests** — `swift build 2>&1 | tail -3 && swift run FileExplorerTests 2>&1 | tail -3`; expect clean build, `PASS`.

- [ ] **Step 10: Commit**

```bash
git add Sources/FileExplorerCore/InfoGatherer.swift \
        Sources/FileExplorerCore/GetInfoModel.swift \
        Sources/FileExplorer/GetInfoView.swift \
        Sources/FileExplorer/FileExplorerApp.swift \
        Sources/FileExplorerTests/InfoGathererTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: Get Info panel (⌘I) with gathered metadata"
```

---

### Task 7: App icon (IconGen target + icns pipeline)

**Files:**
- Create: `Sources/IconGen/main.swift`, `Scripts/make-icon.sh`
- Modify: `Package.swift`, `Resources/Info.plist`, `Scripts/bundle.sh`
- Create (generated, committed): `Resources/FileExplorer.icns`

- [ ] **Step 1: Add the target — `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FileExplorerCore"),
        .executableTarget(name: "FileExplorer", dependencies: ["FileExplorerCore"]),
        .executableTarget(name: "FileExplorerTests", dependencies: ["FileExplorerCore"]),
        .executableTarget(name: "IconGen"),
    ]
)
```

- [ ] **Step 2: Create `Sources/IconGen/main.swift`**

Big Sur-style icon: a rounded-rect "squircle" inset 100 px on a 1024 canvas (Apple's ~824 px convention), blue vertical gradient, two light panes with the right one accented — the dual-pane motif.

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard let outputPath = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write(Data("usage: IconGen <out.png>\n".utf8))
    exit(1)
}

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("could not create context\n".utf8))
    exit(1)
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

// Background squircle: 824×824 centered, Apple-ish corner radius.
let inset: CGFloat = 100
let card = CGRect(x: inset, y: inset,
                  width: CGFloat(size) - 2 * inset,
                  height: CGFloat(size) - 2 * inset)
let cardPath = CGPath(roundedRect: card, cornerWidth: 185, cornerHeight: 185,
                      transform: nil)
context.addPath(cardPath)
context.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(0.16, 0.47, 0.96), rgba(0.05, 0.22, 0.60)] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: card.midX, y: card.maxY),
    end: CGPoint(x: card.midX, y: card.minY),
    options: [])

// Two panes: left one plain, right one carrying three "file row" bars.
let paneWidth: CGFloat = 264
let paneHeight: CGFloat = 420
let gap: CGFloat = 56
let paneY = card.midY - paneHeight / 2
let leftPane = CGRect(x: card.midX - gap / 2 - paneWidth, y: paneY,
                      width: paneWidth, height: paneHeight)
let rightPane = CGRect(x: card.midX + gap / 2, y: paneY,
                       width: paneWidth, height: paneHeight)
for (pane, alpha) in [(leftPane, 0.92), (rightPane, 1.0)] {
    context.setFillColor(rgba(1, 1, 1, alpha))
    context.addPath(CGPath(roundedRect: pane, cornerWidth: 36, cornerHeight: 36,
                           transform: nil))
    context.fillPath()
}
// File rows on the right pane.
context.setFillColor(rgba(0.16, 0.47, 0.96, 0.85))
for row in 0..<3 {
    let rowRect = CGRect(x: rightPane.minX + 36,
                         y: rightPane.maxY - 96 - CGFloat(row) * 108,
                         width: paneWidth - 72, height: 52)
    context.addPath(CGPath(roundedRect: rowRect, cornerWidth: 18,
                           cornerHeight: 18, transform: nil))
    context.fillPath()
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: outputPath) as CFURL,
          UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not write image\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("finalize failed\n".utf8))
    exit(1)
}
```

- [ ] **Step 3: Create `Scripts/make-icon.sh`** (and `chmod +x` it)

```bash
#!/bin/bash
# Regenerate Resources/FileExplorer.icns from the IconGen target.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product IconGen
BIN_PATH="$(swift build -c release --show-bin-path)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$BIN_PATH/IconGen" "$TMP/icon_1024.png"

ICONSET="$TMP/FileExplorer.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$TMP/icon_1024.png" \
        --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$TMP/icon_1024.png" \
        --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/FileExplorer.icns
echo "Wrote Resources/FileExplorer.icns"
```

```bash
chmod +x Scripts/make-icon.sh
```

- [ ] **Step 4: Generate and eyeball**

```bash
./Scripts/make-icon.sh
```

Expected: `Wrote Resources/FileExplorer.icns`. Sanity-check with `sips -g pixelWidth -g pixelHeight Resources/FileExplorer.icns` (reports 512 or larger, no error). Open the 1024 PNG or the .icns in Preview via `qlmanage -p` if a human is watching; otherwise proceed — visual quality is a walkthrough item.

- [ ] **Step 5: Wire into the bundle — `Resources/Info.plist`**

Add inside the `<dict>`:

```xml
    <key>CFBundleIconFile</key>
    <string>FileExplorer</string>
```

- [ ] **Step 6: Copy in `Scripts/bundle.sh`** — after the `cp Resources/Info.plist` line:

```bash
cp Resources/FileExplorer.icns "$APP/Contents/Resources/"
```

- [ ] **Step 7: Build the bundle and verify**

```bash
./Scripts/bundle.sh
ls build/FileExplorer.app/Contents/Resources/FileExplorer.icns
```

Expected: the `.icns` is present; `open build/FileExplorer.app` shows the icon in the Dock (walkthrough confirms visually).

- [ ] **Step 8: Commit** (the generated `.icns` is committed deliberately — decision 5)

```bash
git add Package.swift Sources/IconGen/main.swift Scripts/make-icon.sh \
        Scripts/bundle.sh Resources/Info.plist Resources/FileExplorer.icns
git commit -m "feat: generated app icon (IconGen target + icns pipeline)"
```

---

### Task 8: README, full test pass, manual walkthrough, completion notes

**Files:**
- Modify: `README.md`
- Modify: this plan (check boxes, add completion notes)

- [ ] **Step 1: README shortcut table** — add rows to the existing table:

```markdown
| ⌘C / ⌘V | Copy / paste files (⌥⌘V moves) |
| ⌘D | Duplicate |
| ⌥⌘N | New file |
| ⌘I | Get Info |
```

Also mention extraction in the feature blurb (first paragraph): change "batch tools (rename / convert / compress)" to "batch tools (rename / convert / compress / extract)".

- [ ] **Step 2: Regenerate icon reproducibility check** — `./Scripts/make-icon.sh && git status --short Resources/` — expect no diff (deterministic drawing). If it diffs, investigate before committing anything.

- [ ] **Step 3: Full test pass** — `swift run FileExplorerTests 2>&1 | tail -3`; expect `PASS`, note the honest assertion count.

- [ ] **Step 4: Build + launch** — `./Scripts/bundle.sh && open build/FileExplorer.app`.

- [ ] **Step 5: MANUAL walkthrough** (human; TCC blocks agent UI automation):
  - [ ] ⌘C in FileExplorer → ⌘V in Finder copies the file (and the reverse).
  - [ ] ⌘V into the source's own folder produces "name copy.ext".
  - [ ] ⌥⌘V moves; moving onto an existing name reports the error in the status bar.
  - [ ] ⌘C/⌘V/⌘X/⌘A still work **inside text fields** (rename sheet, filter extension field, palette).
  - [ ] ⌘D duplicates; ⌘Z removes the duplicate.
  - [ ] ⌥⌘N creates "untitled" selected; Return renames it.
  - [ ] Copy Path (both variants) puts the right strings on the clipboard.
  - [ ] Open With lists sensible apps, default first; opening works.
  - [ ] Extract on a .zip and a .tar.gz produces the stem-named folder; ⌘Z trashes it; corrupt archive reports in the status bar.
  - [ ] ⌘I opens the Info window; it follows selection changes, shows symlink targets, multi-selection shows counts.
  - [ ] Dock and Finder show the new icon (may need `killall Dock` / re-copy of the app for icon cache).

- [ ] **Step 6: Commit + completion notes**

```bash
git add README.md docs/superpowers/plans/2026-07-08-milestone-9-daily-driver.md
git commit -m "docs: milestone 9 README updates and completion notes"
```

Record in a "Completion Notes" section at the bottom of this plan: honest assertion count, anything deferred, walkthrough outcomes.

---

## Completion Notes

**Completed 2026-07-08.** All 7 implementation tasks done via subagent-driven development with Codex (GPT) as implementer and Claude reviewers (spec + quality per task). Final suite: **521 assertions, PASS** (462 at start).

**Process notes:**
- Codex's sandbox cannot run this repo's builds/tests (module-cache permission errors + a pre-existing `DirectoryLoaderTests` force-unwrap that crashes under redirected TMPDIR). Division of labor that worked: Codex edits exactly per plan, controller builds/tests/commits outside the sandbox.
- Review loop caught and fixed pre-merge: copy-suffix stacking in `CollisionNamer` ("photo copy copy.jpg" → suffix-aware counting), empty-selection ⌘C wiping the clipboard, DailyOpsTests sleep-timing convention drift, Open With multi-selection spec mismatch (caught in plan self-review).

**Deferred / optional (from reviews):**
- Factor the thrice-duplicated folder-into-itself guard in `FileOperationService` into a shared helper (pre-existing duplication).
- stderr pipe in `Unarchiver`/`Zipper` reads after `waitUntilExit` — latent deadlock only if a tool writes >64KB of stderr; fine in practice.
- `ditto -x -k` zip-slip behavior unverified (bsdtar refuses `..` by default; ditto undocumented). Optional post-extraction path check if ever hardened.
- Get Info's directory Size row says "use Calculate Size", which lives in the context menu, not the panel.
- `newFile` uses `createFile(atPath:)`, which would silently overwrite in a same-instant TOCTOU race (vs `newFolder`'s fail-loud `createDirectory`); one-in-a-million for a personal tool, noted for completeness.

**Final-review fix (applied):** `pasteCopy` now selects pasted items after reload — it was the lone item-creating op that didn't (gap was in the plan itself; every other creating op and Finder select their output).

**MANUAL walkthrough (human, ~10 min — TCC blocks agent UI automation):**
- [ ] ⌘C in FileExplorer → ⌘V in Finder copies the file (and the reverse).
- [ ] ⌘V into the source's own folder produces "name copy.ext".
- [ ] ⌥⌘V moves; moving onto an existing name reports the error in the status bar.
- [ ] ⌘C/⌘V/⌘X/⌘A still work **inside text fields** (rename sheet, filter extension field, palette).
- [ ] Edit menu shows no duplicated Cut/Copy/Paste/Select All rows.
- [ ] ⌘D duplicates; duplicating a duplicate yields "… copy 2"; ⌘Z removes it.
- [ ] ⌥⌘N creates "untitled" selected; Return renames it.
- [ ] Copy Path (both variants) puts the right strings on the clipboard.
- [ ] Open With lists sensible apps, default first; opening works; single-capable-app case has no dangling divider.
- [ ] Extract on a .zip and a .tar.gz produces the stem-named folder; ⌘Z trashes it; corrupt archive reports in the status bar.
- [ ] ⌘I opens the Info window; follows selection; symlink target shown; multi-selection shows counts.
- [ ] Dock and Finder show the new icon (may need `killall Dock` / re-copy for icon cache).
