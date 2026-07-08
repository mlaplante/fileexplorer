# FileExplorer Milestone 11 (Dual-Pane Power Tools) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exploit the dual-pane layout: folder compare with previewed one-way sync, regex/case/date batch-rename tokens, image resize presets, and SHA-256 checksums.

**Architecture:** All decision logic is pure and unit-tested in Core (`FolderComparator` classify/badge/plan, rename token expansion + regex validation, resize math); blocking work follows the service pattern (`SyncExecutor`, `ImageResizer`, `FileHasher`, `ExifDateReader`); compare state lives on `TabState` (it spans both panes); one undo step per sync via `UndoManager` grouping.

**Tech Stack:** Swift 6 SPM, CLT-only — **NO `@State`/`@FocusState`**, no `xcodebuild`/`swift test`. Tests: `swift run FileExplorerTests` (549 assertions at start; counts are estimates — recount honestly). CryptoKit for hashing, ImageIO for resize/EXIF.

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-11-dualpane-tools`.

**Approved decisions (v3 spec + planning-time verification):**
- **PNG→WebP is DROPPED**: verified 2026-07-08 that `CGImageDestinationCopyTypeIdentifiers()` does NOT include `org.webmproject.webp` on this system — per the spec decision ("dropped, not shimmed").
- Compare classifies **files** by size + mtime (2 s FAT tolerance); **directories** only contribute existence (only-left/only-right), never "differs". Hidden files respected per the LEFT pane's `showHidden` (both listings use the same flag — comparing mixed-visibility panes is nonsense).
- Sync direction is explicit ("Sync → Right" / "Sync ← Left" from the banner); the preview sheet lists exactly the planned operations; overwrites trash the target first (restorable); the whole sync is ONE undo step (undo grouping).
- Sync copies **top-most** items only: descendants of an only-source directory are pruned from the plan (the recursive `copyItem` brings them along).
- Rename tokens: `{modified:FORMAT}` / `{exif:FORMAT}` are expanded in find/replace/prefix/suffix templates; `{exif:…}` falls back to the modified date when EXIF is absent. Regex mode uses `NSRegularExpression` with `$1`-style capture references; invalid patterns disable commit via a new `.invalidPattern` conflict. Case transforms (UPPER/lower/Title) apply to the stem after find/replace.
- Resize outputs are siblings named `stem@25pct.ext` / `stem@1024px.ext`, same format as the source, collisions fail loudly, outputs selected after reload (M8 convention).
- Execution model: Codex applies verbatim edits; controller builds/tests/commits (M9/M10 pattern).

**File map:**
- Create: `Sources/FileExplorerCore/FolderComparator.swift`, `SyncExecutor.swift`, `RenameTokens.swift`, `ExifDateReader.swift`, `ImageResizer.swift`, `FileHasher.swift`
- Create: `Sources/FileExplorer/CompareBannerView.swift`, `SyncPreviewSheet.swift`
- Modify: `Sources/FileExplorerCore/TabState.swift`, `RenamePlan.swift`, `PaneState.swift`, `GetInfoModel.swift`
- Modify: `Sources/FileExplorer/BatchRenameSheet.swift`, `FileActionsMenu.swift`, `PaneView.swift`, `TabBarView.swift` (or wherever TabContentView lives — verify with `rg -n "struct TabContentView" Sources/FileExplorer`), `GetInfoView.swift`, `FileExplorerApp.swift`
- Create tests: `Sources/FileExplorerTests/FolderComparatorTests.swift`, `SyncExecutorTests.swift`, `RenameTokensTests.swift`, `ImageResizerTests.swift`, `FileHasherTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

---

### Task 1: FolderComparator (pure classify + badge + sync plan, TDD)

**Files:**
- Create: `Sources/FileExplorerCore/FolderComparator.swift`
- Create: `Sources/FileExplorerTests/FolderComparatorTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Branch**

```bash
cd /Users/mlaplante/Sites/fileexplorer
git checkout main && git checkout -b milestone-11-dualpane-tools
```

- [ ] **Step 2: Failing tests — `Sources/FileExplorerTests/FolderComparatorTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func folderComparatorTests() async {
    func file(_ path: String, size: Int64 = 1,
              modified: Date = Date(timeIntervalSince1970: 1000)) -> FolderComparator.Entry {
        .init(relativePath: path, size: size, modified: modified, isDirectory: false)
    }
    func dir(_ path: String) -> FolderComparator.Entry {
        .init(relativePath: path, size: 0,
              modified: Date(timeIntervalSince1970: 0), isDirectory: true)
    }

    await test("compare classifies only-left, only-right, differs, same") {
        let left = [file("a.txt"), file("b.txt", size: 10), file("c.txt")]
        let right = [file("a.txt"), file("b.txt", size: 20), file("d.txt")]
        let result = FolderComparator.compare(left: left, right: right)
        expectEqual(result.onlyLeft, ["c.txt"], "only left")
        expectEqual(result.onlyRight, ["d.txt"], "only right")
        expectEqual(result.differs, ["b.txt"], "size mismatch differs")
    }

    await test("mtime differences within tolerance are same") {
        let base = Date(timeIntervalSince1970: 1000)
        let left = [file("t.txt", modified: base)]
        let closeRight = [file("t.txt", modified: base.addingTimeInterval(1.5))]
        let farRight = [file("t.txt", modified: base.addingTimeInterval(3))]
        expect(FolderComparator.compare(left: left, right: closeRight).differs.isEmpty,
               "1.5s within 2s tolerance")
        expectEqual(FolderComparator.compare(left: left, right: farRight).differs,
                    ["t.txt"], "3s beyond tolerance differs")
    }

    await test("directories contribute existence only, never differs") {
        let left = [dir("sub"), file("sub/x.txt"), dir("leftonly")]
        let right = [dir("sub"), file("sub/x.txt", size: 9)]
        let result = FolderComparator.compare(left: left, right: right)
        expectEqual(result.onlyLeft, ["leftonly"], "dir existence")
        expectEqual(result.differs, ["sub/x.txt"], "nested file differs; dir itself never")
    }

    await test("badge classifies visible rows including container dirs") {
        var result = FolderComparator.Result()
        result.onlyLeft = ["solo.txt", "deep/nested.txt"]
        result.differs = ["changed.txt"]
        expectEqual(FolderComparator.badge(for: "solo.txt", isDirectory: false,
                                           side: .left, in: result),
                    .onlyHere, "own file")
        expectEqual(FolderComparator.badge(for: "changed.txt", isDirectory: false,
                                           side: .left, in: result),
                    .differs, "changed file")
        expectEqual(FolderComparator.badge(for: "deep", isDirectory: true,
                                           side: .left, in: result),
                    .containsChanges, "dir containing an only-left descendant")
        expect(FolderComparator.badge(for: "solo.txt", isDirectory: false,
                                      side: .right, in: result) == nil,
               "left-only file has no badge on the right side")
    }

    await test("syncPlan prunes descendants of only-source dirs and orders copies") {
        var result = FolderComparator.Result()
        result.onlyLeft = ["dir", "dir/inner.txt", "dir/sub", "dir/sub/deep.txt",
                           "top.txt"]
        result.differs = ["changed.txt"]
        let plan = FolderComparator.syncPlan(result: result, direction: .leftToRight)
        expectEqual(plan.map(\.relativePath), ["changed.txt", "dir", "top.txt"],
                    "descendants pruned, sorted")
        expectEqual(plan.first { $0.relativePath == "changed.txt" }?.kind,
                    .overwrite, "differs → overwrite")
        expectEqual(plan.first { $0.relativePath == "dir" }?.kind,
                    .copy, "only-source → copy")
    }

    await test("syncPlan right-to-left draws from onlyRight") {
        var result = FolderComparator.Result()
        result.onlyLeft = ["l.txt"]
        result.onlyRight = ["r.txt"]
        result.differs = ["both.txt"]
        let plan = FolderComparator.syncPlan(result: result, direction: .rightToLeft)
        expectEqual(Set(plan.map(\.relativePath)), ["r.txt", "both.txt"],
                    "onlyRight + differs")
    }

    await test("listing walks recursively with relative paths") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("top.txt"),
                      atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "yy".write(to: sub.appendingPathComponent("inner.txt"),
                       atomically: true, encoding: .utf8)
        let entries = FolderComparator.listing(root: root, includeHidden: false)
        let paths = Set(entries.map(\.relativePath))
        expectEqual(paths, ["top.txt", "sub", "sub/inner.txt"], "relative paths")
        expectEqual(entries.first { $0.relativePath == "sub/inner.txt" }?.size, 2,
                    "sizes read")
        expect(entries.first { $0.relativePath == "sub" }?.isDirectory == true,
               "dir flagged")
    }
}
```

- [ ] **Step 3: Register** — in `main.swift`, add `await folderComparatorTests()` after `await contentScannerTests()`.

- [ ] **Step 4: Run to verify failure** — `swift run FileExplorerTests 2>&1 | tail -5`; expect compile error.

- [ ] **Step 5: Implement — `Sources/FileExplorerCore/FolderComparator.swift`**

```swift
import Foundation

/// Pure folder-compare engine. `listing` is the only filesystem-touching
/// piece (blocking — call off the main actor); classification, row badging,
/// and sync planning are pure functions over value types.
public enum FolderComparator {
    public struct Entry: Equatable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let modified: Date
        public let isDirectory: Bool

        public init(relativePath: String, size: Int64, modified: Date,
                    isDirectory: Bool) {
            self.relativePath = relativePath
            self.size = size
            self.modified = modified
            self.isDirectory = isDirectory
        }
    }

    public struct Result: Equatable, Sendable {
        public var onlyLeft: [String] = []
        public var onlyRight: [String] = []
        public var differs: [String] = []

        public init() {}

        public var isEmpty: Bool {
            onlyLeft.isEmpty && onlyRight.isEmpty && differs.isEmpty
        }
    }

    public enum Side: Sendable { case left, right }

    public enum Badge: Equatable, Sendable {
        case onlyHere        // exists on this side only
        case differs         // same path, different content
        case containsChanges // directory with affected descendants
    }

    public enum Direction: Sendable { case leftToRight, rightToLeft }

    public enum OperationKind: Equatable, Sendable { case copy, overwrite }

    public struct SyncOperation: Equatable, Sendable {
        public let relativePath: String
        public let kind: OperationKind
    }

    /// Recursive walk producing root-relative entries. Hidden files skipped
    /// unless included; package internals always descended (a folder-diff
    /// tool should see inside bundles). Bounded by `entryCap`.
    public static func listing(root: URL, includeHidden: Bool,
                               entryCap: Int = 50_000) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles]) else {
            return []
        }
        let rootPath = root.standardizedFileURL.path
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            if entries.count >= entryCap { break }
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            entries.append(Entry(
                relativePath: String(full.dropFirst(rootPath.count + 1)),
                size: Int64(rv.fileSize ?? 0),
                modified: rv.contentModificationDate ?? .distantPast,
                isDirectory: rv.isDirectory ?? false))
        }
        return entries
    }

    /// Files differ on size or mtime (beyond tolerance); directories only
    /// contribute existence. A path that is a file on one side and a
    /// directory on the other counts as differing.
    public static func compare(left: [Entry], right: [Entry],
                               mtimeTolerance: TimeInterval = 2) -> Result {
        let leftMap = Dictionary(uniqueKeysWithValues: left.map { ($0.relativePath, $0) })
        let rightMap = Dictionary(uniqueKeysWithValues: right.map { ($0.relativePath, $0) })
        var result = Result()
        for (path, l) in leftMap {
            guard let r = rightMap[path] else {
                result.onlyLeft.append(path)
                continue
            }
            if l.isDirectory != r.isDirectory {
                result.differs.append(path)
            } else if !l.isDirectory {
                if l.size != r.size
                    || abs(l.modified.timeIntervalSince(r.modified)) > mtimeTolerance {
                    result.differs.append(path)
                }
            }
        }
        for path in rightMap.keys where leftMap[path] == nil {
            result.onlyRight.append(path)
        }
        result.onlyLeft.sort()
        result.onlyRight.sort()
        result.differs.sort()
        return result
    }

    /// Row badge for a visible entry. Directories that are ancestors of any
    /// affected path badge as `containsChanges` so differences deeper in the
    /// tree stay discoverable from the top level.
    public static func badge(for relativePath: String, isDirectory: Bool,
                             side: Side, in result: Result) -> Badge? {
        let own = side == .left ? result.onlyLeft : result.onlyRight
        if own.contains(relativePath) { return .onlyHere }
        if result.differs.contains(relativePath) { return .differs }
        if isDirectory {
            let prefix = relativePath + "/"
            let affected = own + result.differs
                + (side == .left ? result.onlyRight : result.onlyLeft)
            if affected.contains(where: { $0.hasPrefix(prefix) }) {
                return .containsChanges
            }
        }
        return nil
    }

    /// Operations to make the DESTINATION match the source side: copy every
    /// only-source item (top-most only — descendants ride along with the
    /// recursive copy) and overwrite every differing file. Sorted for a
    /// stable preview.
    public static func syncPlan(result: Result, direction: Direction)
        -> [SyncOperation] {
        let onlySource = direction == .leftToRight ? result.onlyLeft : result.onlyRight
        let sourceSet = Set(onlySource)
        let topMost = onlySource.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if sourceSet.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
        return (result.differs.map { SyncOperation(relativePath: $0, kind: .overwrite) }
            + topMost.map { SyncOperation(relativePath: $0, kind: .copy) })
            .sorted { $0.relativePath < $1.relativePath }
    }
}
```

- [ ] **Step 6: Run tests** — expect `PASS`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FileExplorerCore/FolderComparator.swift \
        Sources/FileExplorerTests/FolderComparatorTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: FolderComparator — listing, classification, badges, sync plan"
```

### Task 2: SyncExecutor + TabState compare state (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/SyncExecutor.swift`
- Modify: `Sources/FileExplorerCore/TabState.swift`
- Create: `Sources/FileExplorerTests/SyncExecutorTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/SyncExecutorTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func syncExecutorTests() async {
    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    await test("execute copies only-source items and overwrites differs") {
        let source = try makeTree(["top.txt": "new", "dir/inner.txt": "nested",
                                   "changed.txt": "fresh"])
        let target = try makeTree(["changed.txt": "stale-old"])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let plan = [
            FolderComparator.SyncOperation(relativePath: "changed.txt", kind: .overwrite),
            FolderComparator.SyncOperation(relativePath: "dir", kind: .copy),
            FolderComparator.SyncOperation(relativePath: "top.txt", kind: .copy),
        ]
        let outcome = SyncExecutor.execute(plan, from: source, to: target)
        expectEqual(outcome.failures, [], "no failures")
        expectEqual(try String(contentsOf: target.appendingPathComponent("changed.txt"),
                               encoding: .utf8), "fresh", "overwritten")
        expectEqual(try String(contentsOf: target.appendingPathComponent("dir/inner.txt"),
                               encoding: .utf8), "nested", "dir copied recursively")
        expectEqual(try String(contentsOf: target.appendingPathComponent("top.txt"),
                               encoding: .utf8), "new", "file copied")
        expectEqual(outcome.copied.count, 3, "three items created")
        expectEqual(outcome.trashed.count, 1, "old changed.txt trashed")
        expectEqual(outcome.trashed.first?.original.lastPathComponent, "changed.txt",
                    "trashed the overwritten target")
    }

    await test("execute reports per-item failures without aborting") {
        let source = try makeTree(["ok.txt": "fine"])
        let target = try makeTree([:])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let plan = [
            FolderComparator.SyncOperation(relativePath: "missing.txt", kind: .copy),
            FolderComparator.SyncOperation(relativePath: "ok.txt", kind: .copy),
        ]
        let outcome = SyncExecutor.execute(plan, from: source, to: target)
        expectEqual(outcome.failures.count, 1, "missing source fails")
        expectEqual(outcome.copied.count, 1, "good item still copied")
        expect(FileManager.default.fileExists(
                   atPath: target.appendingPathComponent("ok.txt").path),
               "ok.txt landed")
    }
}
```

- [ ] **Step 2: Register** — add `await syncExecutorTests()` after `await folderComparatorTests()`.

- [ ] **Step 3: Run to verify failure**, then **Step 4: Implement — `Sources/FileExplorerCore/SyncExecutor.swift`**

```swift
import Foundation

/// Executes a FolderComparator sync plan. Blocking — call off the main
/// actor. Overwrites trash the existing target first so undo can restore
/// it; failures are per-item and never abort the batch.
public enum SyncExecutor {
    public struct Outcome: Sendable {
        public var copied: [URL] = []
        public var trashed: [(original: URL, trashed: URL)] = []
        public var failures: [String] = []

        public init() {}
    }

    public static func execute(_ plan: [FolderComparator.SyncOperation],
                               from sourceRoot: URL, to targetRoot: URL) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for operation in plan {
            let source = sourceRoot.appendingPathComponent(operation.relativePath)
            let target = targetRoot.appendingPathComponent(operation.relativePath)
            do {
                if operation.kind == .overwrite, fm.fileExists(atPath: target.path) {
                    var resulting: NSURL?
                    try fm.trashItem(at: target, resultingItemURL: &resulting)
                    if let trashedURL = resulting as URL? {
                        outcome.trashed.append((original: target, trashed: trashedURL))
                    }
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                outcome.copied.append(target)
            } catch {
                outcome.failures.append(
                    "\(operation.relativePath): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
```

- [ ] **Step 5: TabState compare state — `Sources/FileExplorerCore/TabState.swift`**

Read the file first (`rg -n "final class TabState" Sources/FileExplorerCore/TabState.swift` for orientation). Add these members to the `TabState` class (it is already `@MainActor @Observable`):

```swift
    /// Folder-compare mode (dual pane only). Set by runCompare(), cleared
    /// by endCompare() and whenever either pane navigates away from the
    /// compared roots (checked by the UI layer before badging).
    public private(set) var compareResult: FolderComparator.Result?
    /// Roots the comparison was computed against — badges must not apply
    /// after either pane navigates elsewhere.
    public private(set) var compareLeftRoot: URL?
    public private(set) var compareRightRoot: URL?
    public private(set) var isComparing = false

    /// Gathers both listings off-main and classifies. No-op unless dual.
    public func runCompare() async {
        guard panes.count == 2 else { return }
        let leftRoot = panes[0].currentURL
        let rightRoot = panes[1].currentURL
        let includeHidden = panes[0].showHidden
        isComparing = true
        let result = await Task.detached(priority: .userInitiated) {
            let left = FolderComparator.listing(root: leftRoot,
                                                includeHidden: includeHidden)
            let right = FolderComparator.listing(root: rightRoot,
                                                 includeHidden: includeHidden)
            return FolderComparator.compare(left: left, right: right)
        }.value
        compareResult = result
        compareLeftRoot = leftRoot.standardizedFileURL
        compareRightRoot = rightRoot.standardizedFileURL
        isComparing = false
    }

    public func endCompare() {
        compareResult = nil
        compareLeftRoot = nil
        compareRightRoot = nil
        isComparing = false
    }

    /// One-way sync per the compare result. ONE undo step: the target
    /// pane's UndoManager groups the creation-undo and the trash-restore.
    public func syncCompare(direction: FolderComparator.Direction) async {
        guard let result = compareResult, panes.count == 2 else { return }
        let sourcePane = direction == .leftToRight ? panes[0] : panes[1]
        let targetPane = direction == .leftToRight ? panes[1] : panes[0]
        let sourceRoot = sourcePane.currentURL
        let targetRoot = targetPane.currentURL
        let plan = FolderComparator.syncPlan(result: result, direction: direction)
        guard !plan.isEmpty else { return }
        let outcome = await Task.detached(priority: .userInitiated) {
            SyncExecutor.execute(plan, from: sourceRoot, to: targetRoot)
        }.value
        if let undoManager = targetPane.undoManager,
           !outcome.copied.isEmpty || !outcome.trashed.isEmpty {
            undoManager.beginUndoGrouping()
            UndoRecorder.recordCreation(outcome.copied, actionName: "Sync Folders",
                                        on: undoManager, pane: targetPane)
            UndoRecorder.recordTrash(outcome.trashed, actionName: "Sync Folders",
                                     on: undoManager, pane: targetPane)
            undoManager.endUndoGrouping()
            undoManager.setActionName("Sync Folders")
        }
        await targetPane.reload()
        if !outcome.failures.isEmpty {
            targetPane.reportTagFailure(
                outcome.failures.prefix(3).joined(separator: " ")
                + (outcome.failures.count > 3
                   ? " (+\(outcome.failures.count - 3) more)" : ""))
        }
        // Refresh the comparison against the new on-disk state.
        await runCompare()
    }
```

(Note: `reportTagFailure` is the public op-error channel added in M10 — reuse it rather than widening another setter. If `TabState` exposes its panes under a different property name than `panes`, adapt these references to the actual API — check the file.)

- [ ] **Step 6: Run tests** — expect `PASS`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FileExplorerCore/SyncExecutor.swift Sources/FileExplorerCore/TabState.swift \
        Sources/FileExplorerTests/SyncExecutorTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: SyncExecutor and TabState compare/sync with single-step undo"
```

### Task 3: Compare UI — banner, row badges, preview sheet

**Files:**
- Create: `Sources/FileExplorer/CompareBannerView.swift`, `Sources/FileExplorer/SyncPreviewSheet.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`, the file containing `TabContentView` (find via `rg -n "struct TabContentView" Sources/FileExplorer`), `Sources/FileExplorer/FileExplorerApp.swift`

Glue task, manual-walkthrough verification; build must stay green. The implementer must read `TabContentView` and `PaneView` first and adapt property threading to what exists (dual-pane rendering lives in TabContentView; PaneView gains optional compare context).

- [ ] **Step 1: `Sources/FileExplorer/SyncPreviewSheet.swift`**

```swift
import SwiftUI
import FileExplorerCore

/// Confirmation model + sheet for a one-way folder sync: shows exactly the
/// planned operations before anything touches disk.
@MainActor
@Observable
final class SyncPreviewModel {
    var operations: [FolderComparator.SyncOperation] = []
    var direction: FolderComparator.Direction = .leftToRight
    @ObservationIgnored weak var tab: TabState?

    var isPresented: Bool { !operations.isEmpty }

    func present(direction: FolderComparator.Direction, tab: TabState) {
        guard let result = tab.compareResult else { return }
        self.direction = direction
        self.tab = tab
        operations = FolderComparator.syncPlan(result: result, direction: direction)
    }

    func dismiss() {
        operations = []
        tab = nil
    }
}

struct SyncPreviewSheet: View {
    @Bindable var model: SyncPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.direction == .leftToRight
                 ? "Sync \(model.operations.count) Items → Right Pane"
                 : "Sync \(model.operations.count) Items → Left Pane")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.operations, id: \.relativePath) { operation in
                        HStack {
                            Image(systemName: operation.kind == .overwrite
                                  ? "exclamationmark.triangle" : "plus.circle")
                                .foregroundStyle(operation.kind == .overwrite
                                                 ? .orange : .green)
                            Text(operation.relativePath)
                            Spacer()
                            Text(operation.kind == .overwrite ? "overwrite" : "copy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 260)
            Text("Overwritten files are moved to the Trash first; the whole sync is one Undo step.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sync") {
                    let direction = model.direction
                    let tab = model.tab
                    model.dismiss()
                    Task { await tab?.syncCompare(direction: direction) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
```

- [ ] **Step 2: `Sources/FileExplorer/CompareBannerView.swift`**

```swift
import SwiftUI
import FileExplorerCore

/// Shown above the panes while compare mode is active: counts + sync actions.
struct CompareBannerView: View {
    var tab: TabState
    var syncPreview: SyncPreviewModel

    var body: some View {
        if let result = tab.compareResult {
            HStack(spacing: 12) {
                Label("\(result.onlyLeft.count) only left", systemImage: "arrow.left")
                Label("\(result.onlyRight.count) only right", systemImage: "arrow.right")
                Label("\(result.differs.count) differ",
                      systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button("Sync → Right") {
                    syncPreview.present(direction: .leftToRight, tab: tab)
                }
                .disabled(result.onlyLeft.isEmpty && result.differs.isEmpty)
                Button("Sync ← Left") {
                    syncPreview.present(direction: .rightToLeft, tab: tab)
                }
                .disabled(result.onlyRight.isEmpty && result.differs.isEmpty)
                Button("Done") { tab.endCompare() }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.quaternary.opacity(0.5))
        }
    }
}
```

- [ ] **Step 3: Row badges — `Sources/FileExplorer/PaneView.swift`**

`PaneView` gains two optional properties (default nil so single-pane call sites compile unchanged):

```swift
    /// Compare-mode context: this pane's side and the shared result, valid
    /// only while the pane is still at the compared root.
    var compareSide: FolderComparator.Side? = nil
    var compareResult: FolderComparator.Result? = nil
```

In the Name `TableColumn` HStack, after the tag-dots block, add:

```swift
                    if let compareResult, let compareSide,
                       let badge = FolderComparator.badge(
                           for: entry.url.standardizedFileURL.path.replacingOccurrences(
                               of: pane.currentURL.standardizedFileURL.path + "/",
                               with: ""),
                           isDirectory: entry.isDirectory,
                           side: compareSide, in: compareResult) {
                        Image(systemName: badgeSymbol(badge))
                            .foregroundStyle(badgeColor(badge))
                            .help(badgeHelp(badge))
                    }
```

And add these private helpers at the bottom of `PaneView`:

```swift
    private func badgeSymbol(_ badge: FolderComparator.Badge) -> String {
        switch badge {
        case .onlyHere: "plus.circle.fill"
        case .differs: "arrow.triangle.2.circlepath.circle.fill"
        case .containsChanges: "ellipsis.circle"
        }
    }

    private func badgeColor(_ badge: FolderComparator.Badge) -> Color {
        switch badge {
        case .onlyHere: .green
        case .differs: .orange
        case .containsChanges: .secondary
        }
    }

    private func badgeHelp(_ badge: FolderComparator.Badge) -> String {
        switch badge {
        case .onlyHere: "Only in this pane"
        case .differs: "Differs from the other pane"
        case .containsChanges: "Contains differences"
        }
    }
```

- [ ] **Step 4: Thread compare context in TabContentView** (adapt to the actual code — read it first). Where the two PaneViews are constructed in the dual-pane branch, pass:

```swift
    compareSide: tabCompareActive ? .left : nil,     // .right for the second pane
    compareResult: tabCompareActive ? tab.compareResult : nil,
```

where `tabCompareActive` verifies the pane is still at the compared root:

```swift
    // Badges are only valid while both panes remain at the compared roots.
    var tabCompareActive: Bool {
        tab.compareResult != nil
            && tab.compareLeftRoot == tab.panes[0].currentURL.standardizedFileURL
            && tab.compareRightRoot == tab.panes[1].currentURL.standardizedFileURL
    }
```

Insert `CompareBannerView(tab: tab, syncPreview: syncPreview)` above the pane HSplitView in the dual layout, and add the `SyncPreviewModel` as an app-level object in `FileExplorerApp` (like `renameModel`), passed down to TabContentView, with a `.sheet` on the main window:

```swift
            .sheet(isPresented: Binding(
                get: { syncPreviewModel.isPresented },
                set: { if !$0 { syncPreviewModel.dismiss() } })) {
                SyncPreviewSheet(model: syncPreviewModel)
            }
```

- [ ] **Step 5: Command — `FileExplorerApp.swift`**, in the `CommandGroup(after: .toolbar)` block after "Toggle Dual Pane":

```swift
                Button("Compare Panes") {
                    Task { await session.activeTab.runCompare() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(session.activeTab.panes.count != 2)
```

(Adapt `panes` to TabState's actual pane-collection property.)

- [ ] **Step 6: Build + suite** — expect clean, `PASS`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FileExplorer/CompareBannerView.swift Sources/FileExplorer/SyncPreviewSheet.swift \
        Sources/FileExplorer/PaneView.swift Sources/FileExplorer/TabBarView.swift \
        Sources/FileExplorer/FileExplorerApp.swift
git commit -m "feat: compare mode UI — banner, row badges, sync preview sheet"
```

(Adjust the file list to what was actually touched for TabContentView.)

### Task 4: Rename tokens — regex, case transforms, date tokens (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/RenameTokens.swift`, `Sources/FileExplorerCore/ExifDateReader.swift`
- Modify: `Sources/FileExplorerCore/RenamePlan.swift`
- Create: `Sources/FileExplorerTests/RenameTokensTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/RenameTokensTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func renameTokensTests() async {
    let url = URL(fileURLWithPath: "/tmp/IMG_1234.jpg")
    let modified = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
    let exif = Date(timeIntervalSince1970: 1_600_000_000)     // 2020-09-13 UTC

    await test("expand substitutes date tokens with fixed-locale formatting") {
        let metadata = RenameTokenMetadata(modified: modified, exifDate: exif)
        expectEqual(RenameTokens.expand("shot-{modified:yyyy-MM-dd}", metadata: metadata),
                    "shot-2023-11-14", "modified token")
        expectEqual(RenameTokens.expand("{exif:yyyy}", metadata: metadata),
                    "2020", "exif token")
        expectEqual(RenameTokens.expand("plain", metadata: metadata),
                    "plain", "no tokens pass through")
    }

    await test("exif token falls back to modified when absent") {
        let metadata = RenameTokenMetadata(modified: modified, exifDate: nil)
        expectEqual(RenameTokens.expand("{exif:yyyy-MM-dd}", metadata: metadata),
                    "2023-11-14", "fallback")
    }

    await test("regex find/replace with capture groups") {
        var rules = RenameRules()
        rules.find = #"IMG_(\d+)"#
        rules.replace = "photo-$1"
        rules.useRegex = true
        let items = RenamePlan.plan(urls: [url], rules: rules, existingNames: [])
        expectEqual(items.first?.newName, "photo-1234.jpg", "capture group")
    }

    await test("invalid regex flags every item as invalidPattern") {
        var rules = RenameRules()
        rules.find = "([unclosed"
        rules.useRegex = true
        let items = RenamePlan.plan(urls: [url], rules: rules, existingNames: [])
        expectEqual(items.first?.conflict, .invalidPattern, "bad pattern surfaces")
    }

    await test("case transforms apply to the stem after find/replace") {
        var upper = RenameRules()
        upper.caseTransform = .upper
        expectEqual(RenamePlan.plan(urls: [url], rules: upper,
                                    existingNames: []).first?.newName,
                    "IMG_1234.jpg", "already upper — unchanged content")
        var lower = RenameRules()
        lower.caseTransform = .lower
        expectEqual(RenamePlan.plan(urls: [url], rules: lower,
                                    existingNames: []).first?.newName,
                    "img_1234.jpg", "lowercased stem, extension untouched")
        var title = RenameRules()
        title.caseTransform = .title
        expectEqual(RenamePlan.plan(
                        urls: [URL(fileURLWithPath: "/tmp/my vacation photos.jpg")],
                        rules: title, existingNames: []).first?.newName,
                    "My Vacation Photos.jpg", "title case")
    }

    await test("date tokens expand inside prefix with per-file metadata") {
        var rules = RenameRules()
        rules.prefix = "{modified:yyyy}-"
        let metadata = [url: RenameTokenMetadata(modified: modified, exifDate: nil)]
        let items = RenamePlan.plan(urls: [url], rules: rules,
                                    existingNames: [], metadata: metadata)
        expectEqual(items.first?.newName, "2023-IMG_1234.jpg", "prefix token")
    }

    await test("ExifDateReader round-trips a generated EXIF date") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-exif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("shot.jpg")
        try ExifTestImage.write(to: photo, dateTimeOriginal: "2021:06:15 10:30:00")
        let date = ExifDateReader.captureDate(of: photo)
        expect(date != nil, "exif date read")
        if let date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            expectEqual(parts.year, 2021, "year")
            expectEqual(parts.month, 6, "month")
            expectEqual(parts.day, 15, "day")
        }
    }
}

/// Test helper: writes a tiny JPEG carrying an EXIF DateTimeOriginal.
enum ExifTestImage {
    static func write(to url: URL, dateTimeOriginal: String) throws {
        let width = 4, height = 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ExifTestImage", code: 1)
        }
    }
}
```

Also add `import ImageIO`, `import UniformTypeIdentifiers`, and `import CoreGraphics` at the top of the test file (below `import FileExplorerCore`).

- [ ] **Step 2: Register** — add `await renameTokensTests()` after `await syncExecutorTests()`.

- [ ] **Step 3: Run to verify failure**, then **Step 4: Implement — `Sources/FileExplorerCore/RenameTokens.swift`**

```swift
import Foundation

/// Per-file inputs for date-token expansion; gathered by the UI layer
/// (impure) and injected so planning stays pure.
public struct RenameTokenMetadata: Equatable, Sendable {
    public let modified: Date
    public let exifDate: Date?

    public init(modified: Date, exifDate: Date?) {
        self.modified = modified
        self.exifDate = exifDate
    }
}

/// Pure `{modified:FORMAT}` / `{exif:FORMAT}` expansion. Formats use
/// DateFormatter patterns with a fixed POSIX locale so output is stable.
/// `{exif:…}` falls back to the modified date when EXIF is absent.
public enum RenameTokens {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\{(modified|exif):([^}]+)\}"#)

    public static func expand(_ template: String,
                              metadata: RenameTokenMetadata) -> String {
        let mutable = NSMutableString(string: template)
        let matches = pattern.matches(
            in: template, range: NSRange(location: 0, length: mutable.length))
        for match in matches.reversed() {
            let kind = mutable.substring(with: match.range(at: 1))
            let format = mutable.substring(with: match.range(at: 2))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            let date = kind == "exif"
                ? (metadata.exifDate ?? metadata.modified)
                : metadata.modified
            mutable.replaceCharacters(in: match.range,
                                      with: formatter.string(from: date))
        }
        return mutable as String
    }

    public enum CaseTransform: String, CaseIterable, Sendable {
        case upper = "UPPERCASE"
        case lower = "lowercase"
        case title = "Title Case"

        public func apply(to stem: String) -> String {
            switch self {
            case .upper: stem.uppercased()
            case .lower: stem.lowercased()
            case .title: stem.capitalized
            }
        }
    }
}
```

(`expand` processes matches in reverse over an `NSMutableString` so earlier ranges stay valid across replacements.)

- [ ] **Step 5: Implement — `Sources/FileExplorerCore/ExifDateReader.swift`**

```swift
import Foundation
import ImageIO

/// Reads EXIF DateTimeOriginal ("yyyy:MM:dd HH:mm:ss", local time by EXIF
/// convention). Blocking (tiny header read) — call off the main actor for
/// large batches. Returns nil for non-images or images without the tag.
public enum ExifDateReader {
    public static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary]
                  as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: raw)
    }
}
```

- [ ] **Step 6: Extend rules + planner — `Sources/FileExplorerCore/RenamePlan.swift`**

`RenameRules` gains three fields (after `numberPadding`):

```swift
    public var useRegex = false
    public var caseTransform: RenameTokens.CaseTransform?
```

`Conflict` gains a case:

```swift
        case invalidPattern    // regex mode with an uncompilable pattern
```

`plan` gains a metadata parameter and token/regex/case handling. Replace the signature and the proposals computation:

```swift
    public static func plan(urls: [URL], rules: RenameRules,
                            existingNames: Set<String>,
                            metadata: [URL: RenameTokenMetadata] = [:]) -> [Item] {
        // Regex mode with an uncompilable pattern poisons the whole batch:
        // surface it on every item so the UI disables commit.
        var regex: NSRegularExpression?
        if rules.useRegex, !rules.find.isEmpty {
            guard let compiled = try? NSRegularExpression(pattern: rules.find) else {
                return urls.map {
                    Item(source: $0, newName: $0.lastPathComponent,
                         conflict: .invalidPattern)
                }
            }
            regex = compiled
        }

        var counter = rules.numberStart
        let fallbackMetadata = RenameTokenMetadata(modified: .distantPast,
                                                   exifDate: nil)
        let proposals: [(URL, String)] = urls.map { url in
            let fileMetadata = metadata[url] ?? fallbackMetadata
            let ext = url.pathExtension
            var base = url.deletingPathExtension().lastPathComponent
            let find = RenameTokens.expand(rules.find, metadata: fileMetadata)
            let replace = RenameTokens.expand(rules.replace, metadata: fileMetadata)
            if let regex {
                let range = NSRange(base.startIndex..., in: base)
                base = regex.stringByReplacingMatches(
                    in: base, range: range, withTemplate: replace)
            } else if !find.isEmpty {
                base = base.replacingOccurrences(of: find, with: replace)
            }
            if let transform = rules.caseTransform {
                base = transform.apply(to: base)
            }
            base = RenameTokens.expand(rules.prefix, metadata: fileMetadata)
                + base
                + RenameTokens.expand(rules.suffix, metadata: fileMetadata)
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
```

(The rest of `plan` — targetCounts, preConflicts, vacated fixpoint — is unchanged.)

**Regex note:** `stringByReplacingMatches(withTemplate:)` interprets `$1` capture references natively — the plan's tests rely on it. When the regex matches nothing, the stem passes through unchanged — same semantics as plain find/replace missing.

- [ ] **Step 7: Run tests** — expect `PASS`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FileExplorerCore/RenameTokens.swift Sources/FileExplorerCore/ExifDateReader.swift \
        Sources/FileExplorerCore/RenamePlan.swift Sources/FileExplorerTests/RenameTokensTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: regex, case-transform, and date-token batch-rename rules"
```

### Task 5: Rename UI — sheet fields + metadata gathering

**Files:**
- Modify: `Sources/FileExplorer/BatchRenameSheet.swift`, `Sources/FileExplorerCore/PaneState.swift`

- [ ] **Step 1: Model gathers metadata — `BatchRenameSheet.swift`**

`BatchRenameModel` gains:

```swift
    var metadata: [URL: RenameTokenMetadata] = [:]
```

`preview` passes it through:

```swift
    var preview: [RenamePlan.Item] {
        RenamePlan.plan(urls: targets, rules: rules,
                        existingNames: existingNames, metadata: metadata)
    }
```

`present(targets:existingNames:in:)` gathers it off-main at open (append at the end of the method):

```swift
        let gatherTargets = targets
        metadata = [:]
        Task {
            let gathered = await Task.detached(priority: .userInitiated) {
                var map: [URL: RenameTokenMetadata] = [:]
                for url in gatherTargets {
                    let modified = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    map[url] = RenameTokenMetadata(
                        modified: modified,
                        exifDate: ExifDateReader.captureDate(of: url))
                }
                return map
            }.value
            guard self.targets == gatherTargets else { return }
            self.metadata = gathered
        }
```

- [ ] **Step 2: Sheet fields — `BatchRenameSheet.swift`**, add a GridRow after the prefix/suffix row:

```swift
                GridRow {
                    Toggle("Regex", isOn: $model.rules.useRegex)
                    Picker("Case", selection: Binding(
                        get: { model.rules.caseTransform },
                        set: { model.rules.caseTransform = $0 })) {
                        Text("Unchanged").tag(RenameTokens.CaseTransform?.none)
                        ForEach(RenameTokens.CaseTransform.allCases, id: \.self) { transform in
                            Text(transform.rawValue)
                                .tag(RenameTokens.CaseTransform?.some(transform))
                        }
                    }
                    .gridCellColumns(3)
                }
```

And below the Grid (before the Divider), a hint line:

```swift
            Text("Tokens: {modified:yyyy-MM-dd} and {exif:yyyy-MM-dd} work in Find, Replace, Prefix, and Suffix. Regex replace supports $1 captures.")
                .font(.caption2)
                .foregroundStyle(.secondary)
```

Extend the conflict `label(for:)` switch with:

```swift
        case .invalidPattern: return "bad regex"
```

- [ ] **Step 3: `PaneState.batchRename` passes metadata** — the sheet's `onConfirm` closure in `FileExplorerApp.swift` calls `pane.batchRename(targets, rules: rules)`, but the plan inside `batchRename` recomputes without metadata. Change `batchRename` to accept it:

```swift
    public func batchRename(_ urls: [URL], rules: RenameRules,
                            metadata: [URL: RenameTokenMetadata] = [:]) async {
        let existing = Set(entries.map(\.name))
        let plan = RenamePlan.plan(urls: urls, rules: rules,
                                   existingNames: existing, metadata: metadata)
```

(rest unchanged) — and in `FileExplorerApp.swift` the BatchRenameSheet confirm closure becomes:

```swift
                BatchRenameSheet(model: batchRenameModel) { targets, rules in
                    let pane = batchRenameModel.pane ?? session.activePane
                    let metadata = batchRenameModel.metadata
                    Task { await pane.batchRename(targets, rules: rules,
                                                  metadata: metadata) }
                }
```

**Ordering caveat for the implementer:** the sheet's confirm handler runs `onConfirm` BEFORE `model.dismiss()` (check `BatchRenameSheet.body`); capture `model.metadata` inside the closure before dismiss clears anything. If `dismiss()` doesn't clear `metadata`, still capture defensively as shown.

- [ ] **Step 4: Build + suite** — expect clean, `PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorer/BatchRenameSheet.swift Sources/FileExplorerCore/PaneState.swift \
        Sources/FileExplorer/FileExplorerApp.swift
git commit -m "feat: regex/case/token controls in the batch-rename sheet"
```

### Task 6: ImageResizer (TDD) + menu

**Files:**
- Create: `Sources/FileExplorerCore/ImageResizer.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift`, `Sources/FileExplorer/FileActionsMenu.swift`
- Create: `Sources/FileExplorerTests/ImageResizerTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/ImageResizerTests.swift`**

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func imageResizerTests() async {
    func writePNG(to url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "test", code: 1)
        }
    }
    func dimensions(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    await test("maxEdge resize caps the longest edge and names @Npx") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("wide.png")
        try writePNG(to: source, width: 200, height: 100)
        let results = ImageResizer.resize([source], mode: .maxEdge(50))
        guard case .success(let output) = results[0].outcome else {
            return expect(false, "resize succeeds")
        }
        expectEqual(output.lastPathComponent, "wide@50px.png", "output name")
        let dims = dimensions(of: output)
        expectEqual(dims?.0, 50, "width capped")
        expectEqual(dims?.1, 25, "aspect kept")
    }

    await test("percent resize scales and names @Npct") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-resize2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("square.png")
        try writePNG(to: source, width: 100, height: 100)
        let results = ImageResizer.resize([source], mode: .percent(50))
        guard case .success(let output) = results[0].outcome else {
            return expect(false, "resize succeeds")
        }
        expectEqual(output.lastPathComponent, "square@50pct.png", "output name")
        expectEqual(dimensions(of: output)?.0, 50, "scaled")
    }

    await test("collision fails loudly and non-images fail per item") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-resize3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.png")
        try writePNG(to: source, width: 10, height: 10)
        try "occupied".write(to: dir.appendingPathComponent("a@50pct.png"),
                             atomically: true, encoding: .utf8)
        guard case .failure = ImageResizer.resize([source], mode: .percent(50))[0].outcome
        else { return expect(false, "collision rejected") }
        let text = dir.appendingPathComponent("not-image.txt")
        try "words".write(to: text, atomically: true, encoding: .utf8)
        guard case .failure = ImageResizer.resize([text], mode: .percent(50))[0].outcome
        else { return expect(false, "non-image rejected") }
        expect(true, "both failures surfaced")
    }
}
```

- [ ] **Step 2: Register** — add `await imageResizerTests()` after `await renameTokensTests()`.

- [ ] **Step 3: Run to verify failure**, then **Step 4: Implement — `Sources/FileExplorerCore/ImageResizer.swift`**

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downsamples images next to the source (`stem@50pct.ext`, `stem@1024px.ext`),
/// keeping the source format. Blocking — call off the main actor. Collisions
/// fail loudly, matching ImageConverter.
public enum ImageResizer {
    public enum Mode: Equatable, Sendable {
        case percent(Int)   // 1–100
        case maxEdge(Int)   // longest edge in pixels

        var suffix: String {
            switch self {
            case .percent(let value): "@\(value)pct"
            case .maxEdge(let value): "@\(value)px"
            }
        }
    }

    public struct ItemResult: Sendable {
        public let source: URL
        public let outcome: Result<URL, FileOperationService.FileOpError>
    }

    public static func resize(_ sources: [URL], mode: Mode,
                              jpegQuality: Double = 0.85) -> [ItemResult] {
        sources.map { source in
            ItemResult(source: source,
                       outcome: resizeOne(source, mode: mode, quality: jpegQuality))
        }
    }

    private static func resizeOne(_ source: URL, mode: Mode, quality: Double)
        -> Result<URL, FileOperationService.FileOpError> {
        let ext = source.pathExtension
        let name = source.deletingPathExtension().lastPathComponent
            + mode.suffix + (ext.isEmpty ? "" : ".\(ext)")
        let output = source.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            return .failure(.init("“\(output.lastPathComponent)” already exists."))
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return .failure(.init("“\(source.lastPathComponent)” isn't a readable image."))
        }
        let longest = max(width, height)
        let targetEdge: Int
        switch mode {
        case .percent(let value):
            targetEdge = max(1, longest * value / 100)
        case .maxEdge(let value):
            targetEdge = min(longest, value)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: targetEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, options as CFDictionary) else {
            return .failure(.init("Couldn't downsample “\(source.lastPathComponent)”."))
        }
        let destinationType = CGImageSourceGetType(imageSource)
            ?? (UTType.png.identifier as CFString)
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, destinationType, 1, nil) else {
            return .failure(.init("Couldn't create “\(output.lastPathComponent)”."))
        }
        var destinationOptions: [CFString: Any] = [:]
        if UTType(destinationType as String)?.conforms(to: .jpeg) == true {
            destinationOptions[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, thumbnail,
                                   destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            return .failure(.init("Failed writing “\(output.lastPathComponent)”."))
        }
        return .success(output)
    }
}
```

- [ ] **Step 5: Pane wrapper — `PaneState.swift`**, after `convertSelected`:

```swift
    public func resizeSelected(_ urls: [URL], mode: ImageResizer.Mode,
                               jpegQuality: Double = 0.85) async {
        let quality = jpegQuality
        let results = await Task.detached(priority: .userInitiated) {
            ImageResizer.resize(urls, mode: mode, jpegQuality: quality)
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
            UndoRecorder.recordCreation(created, actionName: "Resize Image",
                                        on: undoManager, pane: self)
        }
        await reload()
        opErrorMessage = failures.isEmpty
            ? nil
            : failures.prefix(3).joined(separator: " ")
                + (failures.count > 3 ? " (+\(failures.count - 3) more)" : "")
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }
```

- [ ] **Step 6: Menu — `FileActionsMenu.swift`**, after the "Convert Image To" menu block:

```swift
        Menu("Resize Image") {
            Button("25%") {
                Task { await pane.resizeSelected(targets, mode: .percent(25),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
            Button("50%") {
                Task { await pane.resizeSelected(targets, mode: .percent(50),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
            Divider()
            Button("Max 1024 px") {
                Task { await pane.resizeSelected(targets, mode: .maxEdge(1024),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
            Button("Max 2048 px") {
                Task { await pane.resizeSelected(targets, mode: .maxEdge(2048),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
        }
        .disabled(targets.isEmpty)
```

- [ ] **Step 7: Run tests + build** — expect `PASS`, clean build.

- [ ] **Step 8: Commit**

```bash
git add Sources/FileExplorerCore/ImageResizer.swift Sources/FileExplorerCore/PaneState.swift \
        Sources/FileExplorer/FileActionsMenu.swift Sources/FileExplorerTests/ImageResizerTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: image resize presets with undo and output selection"
```

### Task 7: FileHasher (TDD) + Copy SHA-256 + Get Info row

**Files:**
- Create: `Sources/FileExplorerCore/FileHasher.swift`
- Modify: `Sources/FileExplorerCore/GetInfoModel.swift`, `Sources/FileExplorer/GetInfoView.swift`, `Sources/FileExplorer/FileActionsMenu.swift`
- Create: `Sources/FileExplorerTests/FileHasherTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/FileHasherTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func fileHasherTests() async {
    await test("sha256 matches the known vector for 'abc'") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("abc.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        guard case .success(let hash) = FileHasher.sha256(of: file) else {
            return expect(false, "hash succeeds")
        }
        expectEqual(hash,
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                    "NIST test vector")
    }

    await test("sha256 streams large files and fails on missing ones") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-hash2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.bin")
        try Data(repeating: 0xAB, count: 3 * 1_048_576).write(to: big)
        guard case .success(let hash) = FileHasher.sha256(of: big) else {
            return expect(false, "large file hashed")
        }
        expectEqual(hash.count, 64, "64 hex chars")
        guard case .failure = FileHasher.sha256(
            of: dir.appendingPathComponent("missing")) else {
            return expect(false, "missing file fails")
        }
        expect(true, "failure surfaced")
    }
}
```

- [ ] **Step 2: Register** — add `await fileHasherTests()` after `await imageResizerTests()`.

- [ ] **Step 3: Run to verify failure**, then **Step 4: Implement — `Sources/FileExplorerCore/FileHasher.swift`**

```swift
import Foundation
import CryptoKit

/// Streaming SHA-256 (1 MiB chunks) so multi-GB files never load into
/// memory. Blocking — call off the main actor.
public enum FileHasher {
    public static func sha256(of url: URL)
        -> Result<String, FileOperationService.FileOpError> {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.init("Can't read “\(url.lastPathComponent)”."))
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1_048_576) else {
                return .failure(.init("Read failed for “\(url.lastPathComponent)”."))
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
```

- [ ] **Step 5: Context menu — `FileActionsMenu.swift`**, after the "Copy Path" menu block:

```swift
        Button("Copy SHA-256") {
            guard let url = targets.first else { return }
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    FileHasher.sha256(of: url)
                }.value
                switch result {
                case .success(let hash):
                    PasteboardOps.copyString(hash)
                case .failure(let error):
                    pane.reportTagFailure(error.message)
                }
            }
        }
        .disabled(targets.count != 1 || targets.first.map { url in
            pane.entries.first { $0.url == url }?.isDirectory == true
        } == true)
```

- [ ] **Step 6: Get Info row — `GetInfoModel.swift`** gains checksum state:

```swift
    public private(set) var sha256: String?
    public private(set) var isHashing = false

    public func computeChecksum() {
        guard infos.count == 1, let info = infos.first, !info.isDirectory else { return }
        let url = info.url
        generation += 1
        let myGeneration = generation
        isHashing = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileHasher.sha256(of: url)
            }.value
            guard myGeneration == self.generation else { return }
            isHashing = false
            if case .success(let hash) = result { sha256 = hash }
        }
    }
```

And `update(for:)` must reset it — add `sha256 = nil` and `isHashing = false` right after `generation += 1`.

- [ ] **Step 7: Get Info view — `GetInfoView.swift`**, in `singleItem`'s Form after the Permissions row:

```swift
            if !info.isDirectory {
                LabeledContent("SHA-256") {
                    if let hash = model.sha256 {
                        Text(hash)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } else if model.isHashing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Compute") { model.computeChecksum() }
                            .controlSize(.small)
                    }
                }
            }
```

- [ ] **Step 8: Run tests + build** — expect `PASS`, clean build.

- [ ] **Step 9: Commit**

```bash
git add Sources/FileExplorerCore/FileHasher.swift Sources/FileExplorerCore/GetInfoModel.swift \
        Sources/FileExplorer/GetInfoView.swift Sources/FileExplorer/FileActionsMenu.swift \
        Sources/FileExplorerTests/FileHasherTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: streaming SHA-256 — Copy SHA-256 and Get Info row"
```

### Task 8: README, full pass, manual walkthrough, final review, merge

**Files:**
- Modify: `README.md`, this plan (completion notes)

- [ ] **Step 1: README** — shortcut table gains:

```markdown
| ⇧⌘K | Compare panes |
```

Feature blurb: extend "batch tools (rename / convert / compress / extract)" to "batch tools (rename with regex & date tokens / convert / resize / compress / extract), folder compare & sync, checksums".

- [ ] **Step 2: Full pass** — `swift build && swift run FileExplorerTests` (honest count) and `./Scripts/bundle.sh`.

- [ ] **Step 3: MANUAL walkthrough** (human):
  - [ ] ⇧⌘K in dual pane shows the banner with sensible counts; badges appear on differing/only rows; navigating away hides badges.
  - [ ] Sync preview lists the exact operations; Sync copies/overwrites; overwritten file is in Trash; ONE ⌘Z restores everything.
  - [ ] Batch rename: regex with $1, bad regex disables commit with "bad regex", case transforms, {modified:}/{exif:} tokens (EXIF from a real photo).
  - [ ] Resize 50% and Max 1024 px produce correctly named siblings; ⌘Z removes them.
  - [ ] Copy SHA-256 puts the right hash on the clipboard (`shasum -a 256` cross-check); Get Info Compute shows the same, resets when selection changes.
- [ ] **Step 4: Final whole-milestone review** (controller dispatches; cross-cutting: undo grouping vs UndoRecorder invariants, compare-state staleness after navigation, metadata staleness in the rename sheet).
- [ ] **Step 5: Completion notes + merge** via finishing-a-development-branch (user precedent: merge to main, no push).

---

## Completion Notes

(filled in at the end of the milestone)
