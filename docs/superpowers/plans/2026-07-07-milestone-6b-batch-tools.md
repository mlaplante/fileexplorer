# FileExplorer Milestone 6b (Batch Tools) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The remaining WhimFiles tools: batch rename (find/replace, numbering, prefix/suffix, live preview, conflict flags, single undo step), image conversion (anything ImageIO reads → JPG/PNG, undoable), ZIP compression (undoable), on-demand folder sizes shown in the Size column, drop-into-pane (copy), and a terminal helper.

**Architecture:** Core: `RenameRules`/`RenamePlan` (pure, TDD), `ImageConverter` (ImageIO source→destination), `Zipper` (`Process` + `/usr/bin/zip`), `FolderSizer` (recursive byte count), plus PaneState glue (`batchRename`, `convertSelected`, `compressSelected`, `calculateFolderSizes`, `folderSizes: [URL: Int64]` cache surfaced in the Size column). Creation-producing tools (convert/zip) register undo via the existing `UndoRecorder.recordCreation`; batch rename undoes as ONE step via `recordMove` with all pairs. App target: BatchRenameSheet (@Observable model, live preview), menu/context-menu items, `.dropDestination` on the pane, `Scripts/fx` shell helper + launch-path argument.

**Tech Stack:** Swift 6 SPM (CLT-only — NO `@State`/`@FocusState`). Tests: `swift run FileExplorerTests` (260 at start; recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-6b-batch-tools`.

**Design decisions (approved):**
- Deviation IMPROVING on spec: conversions and ZIPs ARE undoable (undo trashes the created files via `recordCreation`) — the spec assumed they couldn't be; the M6a infrastructure makes it free.
- Conversion outputs sit next to sources with the new extension; collisions fail loudly per the M6a policy. JPG quality fixed at 0.85 (v1, no UI knob).
- ZIP: selection compresses to `Archive.zip` (auto-uniquified: `Archive 2.zip`, …) in the pane's current folder; `zip -r` runs with cwd = the current folder so archive paths are relative.
- Folder sizes: computed on demand (context menu "Calculate Size"), cached per URL in PaneState, shown in the Size column instead of "—"; cache clears on navigation/reload (cheap correctness).
- Drop into a pane COPIES (safe default; move stays available via cut-free context-menu commands). Drop target = the pane's current folder.
- Terminal: `Scripts/fx` shell function opens the app with a path argument; the app reads a directory path from CommandLine arguments at launch (first-launch only limitation documented).
- Numbering rule appends `-NN` (padded) before the extension, after find/replace/prefix/suffix.

---

### Task 1: RenamePlan engine (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/RenamePlan.swift`
- Create: `Sources/FileExplorerTests/RenamePlanTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Write the failing test — `Sources/FileExplorerTests/RenamePlanTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func renamePlanTests() async {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/t/\(name)") }

    await test("find/replace, prefix, suffix operate on the basename only") {
        var rules = RenameRules()
        rules.find = "IMG"
        rules.replace = "Photo"
        rules.prefix = "2026-"
        rules.suffix = "-web"
        let items = RenamePlan.plan(urls: [url("IMG_001.jpg")], rules: rules,
                                    existingNames: [])
        expectEqual(items[0].newName, "2026-Photo_001-web.jpg",
                    "basename transformed, extension preserved")
        expect(items[0].conflict == nil, "no conflict")
    }

    await test("numbering appends padded sequence after other rules") {
        var rules = RenameRules()
        rules.numbering = true
        rules.numberStart = 9
        rules.numberPadding = 3
        let items = RenamePlan.plan(urls: [url("a.png"), url("b.png")],
                                    rules: rules, existingNames: [])
        expectEqual(items.map(\.newName), ["a-009.png", "b-010.png"],
                    "padded, sequential, before extension")
    }

    await test("conflicts: duplicate targets, existing files, invalid names") {
        var rules = RenameRules()
        rules.find = "x"
        rules.replace = "same"
        let dupes = RenamePlan.plan(urls: [url("x1.txt"), url("x1.txt")],
                                    rules: rules, existingNames: [])
        // identical sources → identical targets → both flagged duplicate
        expect(dupes.allSatisfy { $0.conflict == .duplicateTarget },
               "duplicate targets flagged")

        var clash = RenameRules()
        clash.prefix = "new-"
        let existing = RenamePlan.plan(urls: [url("file.txt")], rules: clash,
                                       existingNames: ["new-file.txt"])
        expectEqual(existing[0].conflict, .existingFile, "existing name flagged")

        var bad = RenameRules()
        bad.replace = "a/b"
        bad.find = "file"
        let invalid = RenamePlan.plan(urls: [url("file.txt")], rules: bad,
                                      existingNames: [])
        expectEqual(invalid[0].conflict, .invalidName, "slash flagged invalid")
    }

    await test("unchanged names are marked so apply can skip them") {
        let rules = RenameRules()   // no-op rules
        let items = RenamePlan.plan(urls: [url("keep.txt")], rules: rules,
                                    existingNames: ["keep.txt"])
        expectEqual(items[0].newName, "keep.txt", "name unchanged")
        expectEqual(items[0].conflict, .unchanged,
                    "unchanged flagged (not existingFile, even though it exists)")
    }
}
```

Add `await renamePlanTests()` to `main.swift` after `await undoTests()`.

- [x] **Step 2: Verify red.**

- [x] **Step 3: Implement — `Sources/FileExplorerCore/RenamePlan.swift`**

```swift
import Foundation

public struct RenameRules: Equatable, Sendable {
    public var find = ""
    public var replace = ""
    public var prefix = ""
    public var suffix = ""
    public var numbering = false
    public var numberStart = 1
    public var numberPadding = 2

    public init() {}

    public var isNoOp: Bool {
        find.isEmpty && prefix.isEmpty && suffix.isEmpty && !numbering
    }
}

/// Pure batch-rename planner: computes before→after names and flags conflicts
/// so the UI can preview safely before touching disk.
public enum RenamePlan {
    public enum Conflict: Equatable, Sendable {
        case duplicateTarget   // two items in the batch map to the same name
        case existingFile      // target name already taken in the folder
        case invalidName       // empty, "/", ".", ".."
        case unchanged         // rules produce the same name — skip on apply
    }

    public struct Item: Equatable, Sendable {
        public let source: URL
        public let newName: String
        public let conflict: Conflict?
    }

    public static func plan(urls: [URL], rules: RenameRules,
                            existingNames: Set<String>) -> [Item] {
        var counter = rules.numberStart
        let proposals: [(URL, String)] = urls.map { url in
            let ext = url.pathExtension
            var base = url.deletingPathExtension().lastPathComponent
            if !rules.find.isEmpty {
                base = base.replacingOccurrences(of: rules.find, with: rules.replace)
            }
            base = rules.prefix + base + rules.suffix
            if rules.numbering {
                let number = String(counter)
                let padded = String(repeating: "0",
                                    count: max(0, rules.numberPadding - number.count))
                    + number
                base += "-\(padded)"
                counter += 1
            }
            let newName = ext.isEmpty ? base : "\(base).\(ext)"
            return (url, newName)
        }

        var targetCounts: [String: Int] = [:]
        for (_, name) in proposals {
            targetCounts[name, default: 0] += 1
        }

        return proposals.map { source, newName in
            let conflict: Conflict?
            if newName.isEmpty || newName.contains("/")
                || newName == "." || newName == ".." {
                conflict = .invalidName
            } else if newName == source.lastPathComponent {
                conflict = .unchanged
            } else if targetCounts[newName, default: 0] > 1 {
                conflict = .duplicateTarget
            } else if existingNames.contains(newName) {
                conflict = .existingFile
            } else {
                conflict = nil
            }
            return Item(source: source, newName: newName, conflict: conflict)
        }
    }
}
```

- [x] **Step 4: Verify green ×2** (recount honestly).

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: RenamePlan batch-rename engine with conflict detection"`

---

### Task 2: ImageConverter + Zipper + FolderSizer (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/ImageConverter.swift`
- Create: `Sources/FileExplorerCore/Zipper.swift`
- Create: `Sources/FileExplorerCore/FolderSizer.swift`
- Create: `Sources/FileExplorerTests/BatchToolsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Write the failing test — `Sources/FileExplorerTests/BatchToolsTests.swift`** (reuses file-scope `writeTestPNG` from PreviewRendererTests.swift)

```swift
import Foundation
import ImageIO
import FileExplorerCore

@MainActor
func batchToolsTests() async {
    let fm = FileManager.default

    await test("ImageConverter converts png to jpg and reports failures") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let png = dir.appendingPathComponent("pic.png")
        try writeTestPNG(to: png, width: 32, height: 32)
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("fake.png"))

        let results = ImageConverter.convert(
            [png, dir.appendingPathComponent("fake.png")], to: .jpeg)
        expectEqual(results.count, 2, "one result per input")

        if case .success(let out) = results[0].outcome {
            expectEqual(out.pathExtension, "jpg", "jpg extension")
            expect(fm.fileExists(atPath: out.path), "output exists")
            let source = CGImageSourceCreateWithURL(out as CFURL, nil)
            expect(source != nil && CGImageSourceGetCount(source!) > 0,
                   "output is a decodable image")
            expect(fm.fileExists(atPath: png.path), "source untouched")
        } else { expect(false, "png→jpg should succeed") }

        if case .success = results[1].outcome {
            expect(false, "non-image must fail")
        } else { expect(true, "fake image failed cleanly") }

        // collision: converting again must fail loudly, not overwrite
        let again = ImageConverter.convert([png], to: .jpeg)
        if case .success = again[0].outcome {
            expect(false, "existing pic.jpg must not be overwritten")
        } else { expect(true, "collision rejected") }
    }

    await test("Zipper compresses a selection into a unique archive") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data("aa".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data("bb".utf8).write(to: sub.appendingPathComponent("b.txt"))

        let first = Zipper.compress(
            [dir.appendingPathComponent("a.txt"), sub], in: dir)
        if case .success(let archive) = first {
            expectEqual(archive.lastPathComponent, "Archive.zip", "default name")
            expect(fm.fileExists(atPath: archive.path), "archive exists")
            let listing = try listZip(archive)
            expect(listing.contains("a.txt") && listing.contains("sub/b.txt"),
                   "relative paths inside [got: \(listing)]")
        } else { expect(false, "zip should succeed") }

        let second = Zipper.compress([dir.appendingPathComponent("a.txt")], in: dir)
        if case .success(let archive2) = second {
            expectEqual(archive2.lastPathComponent, "Archive 2.zip", "uniquified")
        } else { expect(false, "second zip should succeed") }
    }

    await test("FolderSizer sums recursive file sizes") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data(count: 100).write(to: dir.appendingPathComponent("a.bin"))
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data(count: 250).write(to: sub.appendingPathComponent("b.bin"))

        expectEqual(FolderSizer.size(of: dir), 350, "recursive byte total")
        expectEqual(FolderSizer.size(of: dir.appendingPathComponent("missing")), 0,
                    "missing folder is 0")
    }
}

func listZip(_ archive: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    process.arguments = ["-1", archive.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8) ?? ""
}
```

Add `await batchToolsTests()` to `main.swift` after `await renamePlanTests()`.

- [x] **Step 2: Verify red.**

- [x] **Step 3: Implement.** `Sources/FileExplorerCore/ImageConverter.swift`:

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts images (anything ImageIO decodes: HEIC, WebP, AVIF, PNG, …) to
/// JPG or PNG next to the source. Blocking — call off the main actor.
/// Collisions fail loudly (no overwrite), matching FileOperationService.
public enum ImageConverter {
    public enum Format: String, CaseIterable, Sendable {
        case jpeg
        case png

        public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
        var utType: UTType { self == .jpeg ? .jpeg : .png }
    }

    public struct ItemResult: Sendable {
        public let source: URL
        public let outcome: Result<URL, FileOperationService.FileOpError>
    }

    public static func convert(_ sources: [URL], to format: Format,
                               jpegQuality: Double = 0.85) -> [ItemResult] {
        sources.map { source in
            ItemResult(source: source,
                       outcome: convertOne(source, to: format, quality: jpegQuality))
        }
    }

    private static func convertOne(_ source: URL, to format: Format,
                                   quality: Double)
        -> Result<URL, FileOperationService.FileOpError> {
        let target = source.deletingPathExtension()
            .appendingPathExtension(format.fileExtension)
        guard target.path != source.path else {
            return .failure(.init("“\(source.lastPathComponent)” is already \(format.fileExtension)."))
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(.init("“\(target.lastPathComponent)” already exists."))
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return .failure(.init("“\(source.lastPathComponent)” isn't a readable image."))
        }
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, format.utType.identifier as CFString, 1, nil) else {
            return .failure(.init("Couldn't create “\(target.lastPathComponent)”."))
        }
        let options = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: target)
            return .failure(.init("Failed writing “\(target.lastPathComponent)”."))
        }
        return .success(target)
    }
}
```

`Sources/FileExplorerCore/Zipper.swift`:

```swift
import Foundation

/// Compresses items into "Archive.zip" (uniquified) in `directory` using
/// /usr/bin/zip with relative paths. Blocking — call off the main actor.
public enum Zipper {
    public static func compress(_ sources: [URL], in directory: URL)
        -> Result<URL, FileOperationService.FileOpError> {
        guard !sources.isEmpty else { return .failure(.init("Nothing selected.")) }
        let fm = FileManager.default
        var name = "Archive.zip"
        var counter = 1
        var archive = directory.appendingPathComponent(name)
        while fm.fileExists(atPath: archive.path) {
            counter += 1
            name = "Archive \(counter).zip"
            archive = directory.appendingPathComponent(name)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-r", "-q", archive.path]
            + sources.map { source in
                source.path.hasPrefix(directory.path + "/")
                    ? String(source.path.dropFirst(directory.path.count + 1))
                    : source.path
            }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.init(error))
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            try? fm.removeItem(at: archive)
            return .failure(.init("zip failed: \(stderr.prefix(200))"))
        }
        return .success(archive)
    }
}
```

`Sources/FileExplorerCore/FolderSizer.swift`:

```swift
import Foundation

/// Recursive on-disk byte total for a folder. Blocking — call off the main
/// actor. Unreadable entries are skipped (drop-on-failure convention).
public enum FolderSizer {
    public static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory != true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
```

- [x] **Step 4: Verify green ×2** (recount honestly).

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: image conversion, zip compression, and folder sizing"`

---

### Task 3: PaneState glue (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerTests/PaneBatchToolsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Write the failing test — `Sources/FileExplorerTests/PaneBatchToolsTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func paneBatchToolsTests() async {
    let fm = FileManager.default

    await test("batchRename applies non-conflicted items as one undo step") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("IMG_1.jpg"))
        try Data().write(to: dir.appendingPathComponent("IMG_2.jpg"))
        try Data().write(to: dir.appendingPathComponent("skip.txt"))

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        var rules = RenameRules()
        rules.find = "IMG_"
        rules.replace = "Photo-"
        await pane.batchRename(
            [dir.appendingPathComponent("IMG_1.jpg"),
             dir.appendingPathComponent("IMG_2.jpg"),
             dir.appendingPathComponent("skip.txt")], rules: rules)

        expect(fm.fileExists(atPath: dir.appendingPathComponent("Photo-1.jpg").path),
               "first renamed")
        expect(fm.fileExists(atPath: dir.appendingPathComponent("Photo-2.jpg").path),
               "second renamed")
        expect(fm.fileExists(atPath: dir.appendingPathComponent("skip.txt").path),
               "unchanged item skipped, not errored")
        expect(pane.opErrorMessage == nil, "no error for skipped-unchanged")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(fm.fileExists(atPath: dir.appendingPathComponent("IMG_1.jpg").path)
               && fm.fileExists(atPath: dir.appendingPathComponent("IMG_2.jpg").path),
               "single undo restores both")
    }

    await test("convertSelected and compressSelected register creation undo") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let png = dir.appendingPathComponent("pic.png")
        try writeTestPNG(to: png, width: 16, height: 16)

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.convertSelected([png], to: .jpeg)
        let jpg = dir.appendingPathComponent("pic.jpg")
        expect(fm.fileExists(atPath: jpg.path), "converted")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: jpg.path), "undo removed the converted file")
        expect(fm.fileExists(atPath: png.path), "source untouched by undo")

        await pane.compressSelected([png])
        let archive = dir.appendingPathComponent("Archive.zip")
        expect(fm.fileExists(atPath: archive.path), "archive created")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: archive.path), "undo removed the archive")
    }

    await test("calculateFolderSizes caches and navigation clears") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data(count: 123).write(to: sub.appendingPathComponent("f.bin"))

        let pane = PaneState(url: dir)
        await pane.reload()
        await pane.calculateFolderSizes([sub])
        expectEqual(pane.folderSizes[sub.standardizedFileURL], 123, "size cached")

        await pane.navigate(to: sub)
        expect(pane.folderSizes.isEmpty, "cache cleared on navigation")
    }
}
```

Add `await paneBatchToolsTests()` to `main.swift` after `await batchToolsTests()`.

- [x] **Step 2: Verify red.**

- [x] **Step 3: Implement in `Sources/FileExplorerCore/PaneState.swift`.**

Add near `folderSizes`-related state (near `opErrorMessage`):

```swift
    /// On-demand recursive folder sizes (context menu → Calculate Size),
    /// keyed by standardized URL; cleared on navigation.
    public private(set) var folderSizes: [URL: Int64] = [:]
```

Clear it in `afterNavigation()` (`folderSizes.removeAll()` next to `opErrorMessage = nil`).

Add the tool wrappers (near the other op wrappers):

```swift
    /// Applies the plan's clean items; conflicted items are skipped and
    /// reported, `.unchanged` items are skipped silently. One undo step.
    public func batchRename(_ urls: [URL], rules: RenameRules) async {
        let existing = Set(entries.map(\.name))
        let plan = RenamePlan.plan(urls: urls, rules: rules, existingNames: existing)
        var pairs: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for item in plan {
            switch item.conflict {
            case .unchanged:
                continue
            case .some(let conflict):
                failures.append("“\(item.source.lastPathComponent)” skipped (\(conflict)).")
            case nil:
                switch FileOperationService.rename(item.source, to: item.newName) {
                case .success(let newURL):
                    pairs.append((from: item.source, to: newURL))
                case .failure(let error):
                    failures.append(error.message)
                }
            }
        }
        if let undoManager, !pairs.isEmpty {
            UndoRecorder.recordMove(pairs, actionName: "Batch Rename",
                                    on: undoManager, pane: self)
        }
        await reload()
        opErrorMessage = failures.isEmpty
            ? nil
            : failures.prefix(3).joined(separator: " ")
                + (failures.count > 3 ? " (+\(failures.count - 3) more)" : "")
    }

    public func convertSelected(_ urls: [URL], to format: ImageConverter.Format) async {
        let results = await Task.detached(priority: .userInitiated) {
            ImageConverter.convert(urls, to: format)
        }.value
        let created = results.compactMap { result -> URL? in
            if case .success(let url) = result.outcome { return url }
            return nil
        }
        let failures = results.compactMap { result -> String? in
            if case .failure(let error) = result.outcome { return error.message }
            return nil
        }
        if let undoManager, !created.isEmpty {
            UndoRecorder.recordCreation(created, actionName: "Convert Image",
                                        on: undoManager, pane: self)
        }
        await reload()
        opErrorMessage = failures.isEmpty
            ? nil
            : failures.prefix(3).joined(separator: " ")
                + (failures.count > 3 ? " (+\(failures.count - 3) more)" : "")
    }

    public func compressSelected(_ urls: [URL]) async {
        let destination = currentURL
        let result = await Task.detached(priority: .userInitiated) {
            Zipper.compress(urls, in: destination)
        }.value
        switch result {
        case .success(let archive):
            if let undoManager {
                UndoRecorder.recordCreation([archive], actionName: "Compress",
                                            on: undoManager, pane: self)
            }
            opErrorMessage = nil
            await reload()
            selection = [archive.standardizedFileURL]
        case .failure(let error):
            opErrorMessage = error.message
            await reload()
        }
    }

    public func calculateFolderSizes(_ urls: [URL]) async {
        let targets = urls.map(\.standardizedFileURL)
        let sizes = await Task.detached(priority: .userInitiated) {
            targets.map { ($0, FolderSizer.size(of: $0)) }
        }.value
        for (url, size) in sizes {
            folderSizes[url] = size
        }
    }
```

NOTE: `UndoRecorder.recordMove` currently has no `actionName` parameter in its public signature if the Task-2/M6a fix hardcoded "Move" at the call sites — CHECK the actual signature (the action-name threading fix added `actionName` parameters). Use whatever the real signature is; if `recordMove` lacks an actionName parameter, add one with default "Move" (all existing call sites keep working) — report what you found.

- [x] **Step 4: Verify green ×2** (recount honestly).

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: batch rename, convert, compress, folder sizes on PaneState"`

---

### Task 4: Batch tools UI

**Files:**
- Create: `Sources/FileExplorer/BatchRenameSheet.swift`
- Modify: `Sources/FileExplorer/FileActionsMenu.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`
- Modify: `Sources/FileExplorer/TabBarView.swift`

UI glue — no unit tests. NO @State/@FocusState.

- [x] **Step 1: Create `Sources/FileExplorer/BatchRenameSheet.swift`**

```swift
import SwiftUI
import FileExplorerCore

@MainActor
@Observable
final class BatchRenameModel {
    var targets: [URL] = []
    var rules = RenameRules()
    var existingNames: Set<String> = []

    var isPresented: Bool { !targets.isEmpty }

    var preview: [RenamePlan.Item] {
        RenamePlan.plan(urls: targets, rules: rules, existingNames: existingNames)
    }

    var applicableCount: Int {
        preview.filter { $0.conflict == nil }.count
    }

    func present(targets: [URL], existingNames: Set<String>) {
        rules = RenameRules()
        self.existingNames = existingNames
        self.targets = targets
    }

    func dismiss() {
        targets = []
    }
}

struct BatchRenameSheet: View {
    @Bindable var model: BatchRenameModel
    var onConfirm: ([URL], RenameRules) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Batch Rename \(model.targets.count) Items")
                .font(.headline)

            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("Find:")
                    TextField("", text: $model.rules.find)
                    Text("Replace:")
                    TextField("", text: $model.rules.replace)
                }
                GridRow {
                    Text("Prefix:")
                    TextField("", text: $model.rules.prefix)
                    Text("Suffix:")
                    TextField("", text: $model.rules.suffix)
                }
                GridRow {
                    Toggle("Number sequentially", isOn: $model.rules.numbering)
                        .gridCellColumns(2)
                    Stepper("Start: \(model.rules.numberStart)",
                            value: $model.rules.numberStart, in: 0...9999)
                    Stepper("Digits: \(model.rules.numberPadding)",
                            value: $model.rules.numberPadding, in: 1...6)
                }
            }
            .textFieldStyle(.roundedBorder)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.preview, id: \.source) { item in
                        HStack {
                            Text(item.source.lastPathComponent)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(item.newName)
                            Spacer()
                            if let conflict = item.conflict, conflict != .unchanged {
                                Text(label(for: conflict))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if item.conflict == .unchanged {
                                Text("unchanged")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename \(model.applicableCount)") {
                    let targets = model.targets
                    let rules = model.rules
                    model.dismiss()
                    onConfirm(targets, rules)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.applicableCount == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func label(for conflict: RenamePlan.Conflict) -> String {
        switch conflict {
        case .duplicateTarget: return "duplicate"
        case .existingFile: return "exists"
        case .invalidName: return "invalid"
        case .unchanged: return "unchanged"
        }
    }
}
```

- [x] **Step 2: Menu items — `Sources/FileExplorer/FileActionsMenu.swift`.** FileActions gains `let batchRenameModel: BatchRenameModel`. In `menu(for:)` after the "Rename…" button add:

```swift
        Button("Batch Rename…") {
            batchRenameModel.present(
                targets: targets.sorted { $0.lastPathComponent < $1.lastPathComponent },
                existingNames: Set(pane.entries.map(\.name)))
        }
        .disabled(targets.count < 2)
```

and before "Move to Trash" (after the cross-pane section) add:

```swift
        Divider()
        Menu("Convert Image To") {
            Button("JPG") { Task { await pane.convertSelected(targets, to: .jpeg) } }
            Button("PNG") { Task { await pane.convertSelected(targets, to: .png) } }
        }
        .disabled(targets.isEmpty)
        Button("Compress") {
            Task { await pane.compressSelected(targets) }
        }
        .disabled(targets.isEmpty)
        Button("Calculate Size") {
            Task { await pane.calculateFolderSizes(targets) }
        }
        .disabled(targets.isEmpty)
```

- [x] **Step 3: Threading the model.** `BatchRenameModel` is owned by `FileExplorerApp` (like `renameModel`): add `private let batchRenameModel = BatchRenameModel()`, present its sheet next to the rename sheet at ZStack level:

```swift
            .sheet(isPresented: Binding(
                get: { batchRenameModel.isPresented },
                set: { if !$0 { batchRenameModel.dismiss() } })) {
                BatchRenameSheet(model: batchRenameModel) { targets, rules in
                    Task { await session.activePane.batchRename(targets, rules: rules) }
                }
            }
```

Thread it down exactly like `renameModel`: `TabContentView` → `PaneAreaView` → `PaneView` → `FileActions` (both table context menu and grid `actions:` construction). Follow the existing renameModel threading pattern file-by-file.

- [x] **Step 4: Size column shows cached folder sizes — `Sources/FileExplorer/PaneView.swift`.** In the Size TableColumn, replace the `if entry.isDirectory` branch content:

```swift
                if entry.isDirectory {
                    if let size = pane.folderSizes[entry.url.standardizedFileURL] {
                        Text(size, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                } else {
```

- [x] **Step 5: Drop into pane — `Sources/FileExplorer/PaneView.swift`.** Append to the outer `Group` (with onKeyPress etc.):

```swift
        .dropDestination(for: URL.self) { urls, _ in
            let outside = urls.filter {
                $0.deletingLastPathComponent().standardizedFileURL != pane.currentURL
            }
            guard !outside.isEmpty else { return false }
            Task { await pane.copySelected(outside, into: pane.currentURL) }
            return true
        }
```

- [x] **Step 6: Verify** — build clean, greps clean, tests unchanged PASS, launch check.

- [x] **Step 7: Commit** — `git add -A && git commit -m "feat: batch rename sheet, convert/compress/size menus, drop-to-copy"`

---

### Task 5: Terminal helper + launch path

**Files:**
- Create: `Scripts/fx`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`
- Create: `README.md`

- [x] **Step 1: Launch-path support.** In `FileExplorerApp`, change the session property to read a directory from the command line:

```swift
    private let session: SessionState = {
        let arguments = CommandLine.arguments.dropFirst()
        if let path = arguments.first {
            var isDirectory: ObjCBool = false
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                return SessionState(url: URL(fileURLWithPath: expanded))
            }
        }
        return SessionState(
            url: FileManager.default.homeDirectoryForCurrentUser)
    }()
```

- [x] **Step 2: Create `Scripts/fx`** (mode 755):

```bash
#!/bin/bash
# fx [dir] — open FileExplorer at dir (default: cwd).
# Note: --args only applies when the app isn't already running.
exec open -a "FileExplorer" --args "${1:-$(pwd)}"
```

- [x] **Step 3: Create `README.md`** — short: what the app is, `./Scripts/bundle.sh` to build, `swift run FileExplorerTests` to test, keyboard-shortcut table (⌘T/⌘W/⌘1–9, ⌘[/⌘]/⌘↑/⇧⌘H, ⌘G/⌘P/⇧⌘A, ⇧⌘./⇧⌘D/⌥⌘1/⌥⌘2/⌘Y, ⇧⌘N/⌘⌫/Return-rename, ⌘Z undo), terminal helper install line (`ln -s "$(pwd)/Scripts/fx" /usr/local/bin/fx` or copy the function), and the fx first-launch caveat.

- [x] **Step 4: Verify** — build the bundle, `open build/FileExplorer.app --args /tmp` … `open --args` requires the flag AFTER the app: `open -a build/FileExplorer.app --args /private/tmp` — verify via AX that the window title is "tmp" (launch-path honored). Tests unchanged.

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: terminal helper and launch-path argument; README"`

---

### Task 6: Interactive verification + merge prep

- [x] **Step 1:** Tests ×2, bundle, idle check.
- [x] **Step 2:** Interactive (menus/keyboard/AX; raw mouse unreliable): batch-rename sheet via… context menu is mouse-bound — verify BatchRenameModel logic is already unit-tested; visually verify the SHEET by presenting it via a temporary keyboard path if feasible, else MANUAL. Convert/Compress/Calculate-Size are context-menu-bound → verify Core paths are test-covered (they are) and mark menus MANUAL. Verify launch-path (Task 5 Step 4 style). Verify drop-to-copy MANUAL.
- [x] **Step 3:** Fix real bugs (commit `fix: … (milestone 6b verification)`); structural → report.

---

## Completion Notes (2026-07-07) — PROJECT COMPLETE

All 6 tasks done. Final: `swift run FileExplorerTests` → PASS (301 assertions); idle ~0% CPU. With this merge, every feature in the original spec is delivered or explicitly deferred below.

Bugs found and fixed during this milestone (red/green regression-tested):
- Zipper broke on leading-dash filenames (zip flag parsing) → `--` terminator.
- ImageConverter dropped EXIF orientation (phone photos converted sideways) → orientation carried into destination options.
- `compressSelected` error-ordering nit → reload-first convention.
- batchRename left stale selection (broke Quick Look refresh) → selects renamed results.
- **⌘O/⌘↓ Open was missing from the entire project** (final spec sweep) → `PaneState.openSelection` + File-menu ⌘O + ⌘↓ keypress. Empirical finding: DirectoryLoader folder URLs carry trailing slashes — URL equality vs selection URLs must compare `.standardizedFileURL.path`.

**Deferred / accepted debt (whole project):**
- JPG quality fixed at 0.85 (no UI knob); multi-frame sources convert frame 0 only.
- RenamePlan blocks A↔B rename swaps (conservative existingFile flag); "Calculate Size" enabled for files (harmless no-op); `RenameRules.isNoOp` unused.
- Batch-rename/rename target `session.activePane` (right-click on inactive pane row doesn't activate it first) — convert/compress/size use the direct-pane pattern; unify later.
- convertSelected doesn't select outputs. Grid view: no multi-select. Drop-into-pane copies only. Session persistence across launches not implemented (bookmarks/settings JSON too).
- MANUAL walkthrough items never machine-verified: hover preview popover, dual-pane click-to-activate tint, drag-out to Finder, context-menu flows (rename/batch-rename sheets open correctly — Core logic fully tested).
