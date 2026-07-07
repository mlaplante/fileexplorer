# FileExplorer Milestone 1 (Browse) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working single-pane macOS file browser: sidebar with bookmarks + volumes, sortable file table, breadcrumb/history/keyboard navigation, hidden-file toggle, live directory watching, and a `FileExplorer.app` bundle.

**Architecture:** SwiftPM package with three targets — `FileExplorerCore` (library: pure, testable logic — entries, loading, sorting, history), `FileExplorer` (executable: SwiftUI app), `FileExplorerTests` (executable test runner with a minimal assert harness, because this machine's Command Line Tools ship no XCTest/Swift Testing runtime). State is `@Observable`/`@MainActor`; directory loads run off-main; a `DispatchSource` watcher reloads on folder changes.

**Tech Stack:** Swift 6 (CLT toolchain, `swift build` only — **no xcodebuild, no `swift test`**), SwiftUI `Table`/`NavigationSplitView`, AppKit interop (`NSWorkspace` icons/open), macOS 15+ (dev machine is macOS 27).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer` (git repo already initialized, spec committed).

**Conventions for every task:**
- Run all commands from the repo root.
- Tests run with `swift run FileExplorerTests` — exit code 0 = pass, 1 = failures (printed as `FAIL - …`).
- Commit after each task with the message given in the task.

---

### Task 1: SPM scaffold + test harness

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/FileExplorerCore/Placeholder.swift`
- Create: `Sources/FileExplorer/FileExplorerApp.swift`
- Create: `Sources/FileExplorerTests/Harness.swift`
- Create: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Create `Package.swift`**

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
    ]
)
```

- [ ] **Step 2: Create `.gitignore`**

```
.build/
build/
.DS_Store
```

- [ ] **Step 3: Create `Sources/FileExplorerCore/Placeholder.swift`**

(Removed in Task 2 — SPM requires the target to contain at least one file.)

```swift
// Placeholder so the target compiles; replaced by real sources in Task 2.
```

- [ ] **Step 4: Create `Sources/FileExplorer/FileExplorerApp.swift`**

```swift
import SwiftUI

@main
struct FileExplorerApp: App {
    init() {
        // When launched from `swift run` (no bundle), become a regular
        // foreground app so the window appears and takes focus.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            Text("FileExplorer")
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
```

- [ ] **Step 5: Create `Sources/FileExplorerTests/Harness.swift`**

The harness: `test` groups assertions, `expect` records pass/fail, `finish()` exits non-zero on any failure. Top-level code in `main.swift` is MainActor-isolated, so MainActor globals are safe.

```swift
import Foundation

@MainActor var testFailures = 0
@MainActor var testCount = 0

@MainActor
func test(_ name: String, _ body: () async throws -> Void) async {
    print("• \(name)")
    do { try await body() } catch {
        testFailures += 1
        print("  FAIL - threw \(error)")
    }
}

@MainActor
func expect(_ condition: Bool, _ message: String,
            file: StaticString = #filePath, line: UInt = #line) {
    testCount += 1
    if condition {
        print("  ok - \(message)")
    } else {
        testFailures += 1
        print("  FAIL - \(message)  (\(file):\(line))")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    expect(actual == expected, "\(message) [got: \(actual), want: \(expected)]",
           file: file, line: line)
}

@MainActor
func finish() -> Never {
    print(testFailures == 0
        ? "PASS (\(testCount) assertions)"
        : "FAILED (\(testFailures) failures / \(testCount) assertions)")
    exit(testFailures == 0 ? 0 : 1)
}
```

- [ ] **Step 6: Create `Sources/FileExplorerTests/main.swift`**

```swift
import Foundation

await test("harness sanity") {
    expect(true, "expect(true) passes")
    expectEqual(2 + 2, 4, "arithmetic works")
}

finish()
```

- [ ] **Step 7: Build and run tests**

Run: `swift build && swift run FileExplorerTests`
Expected: `Build complete!`, then `• harness sanity`, two `ok -` lines, `PASS (2 assertions)`, exit code 0.
(A linker warning about `/Library/Developer/CommandLineTools/Developer/Library/Frameworks` not found is normal on this machine — ignore it.)

- [ ] **Step 8: Smoke-run the app**

Run: `swift run FileExplorer &` then after a few seconds `kill %1`
Expected: a window titled FileExplorer appears with the placeholder text. (If verifying non-interactively: the process staying alive >3s without crashing is sufficient.)

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: SPM scaffold with app target and test harness"
```

---

### Task 2: FileEntry + DirectoryLoader

**Files:**
- Delete: `Sources/FileExplorerCore/Placeholder.swift`
- Create: `Sources/FileExplorerCore/FileEntry.swift`
- Create: `Sources/FileExplorerCore/DirectoryLoader.swift`
- Create: `Sources/FileExplorerTests/DirectoryLoaderTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/DirectoryLoaderTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func directoryLoaderTests() async {
    await test("DirectoryLoader loads entries with attributes") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent(".secret"))

        let visible = try DirectoryLoader.load(dir, includeHidden: false)
        expectEqual(visible.count, 2, "hidden file excluded by default")

        let names = Set(visible.map(\.name))
        expect(names == ["a.txt", "sub"], "names match [got: \(names)]")

        let file = visible.first { $0.name == "a.txt" }!
        expect(!file.isDirectory, "a.txt is not a directory")
        expectEqual(file.size, 5, "a.txt size is 5 bytes")
        expect(file.modified > Date(timeIntervalSince1970: 0), "modified date is set")
        expect(file.contentType?.conforms(to: .plainText) == true, "a.txt is plain text")

        let sub = visible.first { $0.name == "sub" }!
        expect(sub.isDirectory, "sub is a directory")

        let all = try DirectoryLoader.load(dir, includeHidden: true)
        expectEqual(all.count, 3, "hidden file included when asked")
        expect(all.first { $0.name == ".secret" }?.isHidden == true, ".secret flagged hidden")
    }

    await test("DirectoryLoader throws for missing directory") {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        do {
            _ = try DirectoryLoader.load(missing, includeHidden: false)
            expect(false, "should have thrown")
        } catch {
            expect(true, "threw as expected")
        }
    }
}

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fx-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
```

Replace `Sources/FileExplorerTests/main.swift` with:

```swift
import Foundation

await directoryLoaderTests()

finish()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run FileExplorerTests`
Expected: build FAILS with "cannot find 'DirectoryLoader' in scope" (compile-time failure is this step's red).

- [ ] **Step 3: Implement — delete `Placeholder.swift`, create `Sources/FileExplorerCore/FileEntry.swift`**

```swift
import Foundation
import UniformTypeIdentifiers

public struct FileEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let created: Date?
    public let modified: Date
    public let contentType: UTType?

    public var id: URL { url }

    /// Human-readable kind, e.g. "PNG image", "Folder".
    public var kind: String {
        if isDirectory { return "Folder" }
        return contentType?.localizedDescription
            ?? url.pathExtension.uppercased()
    }

    public init(url: URL, name: String, isDirectory: Bool, isHidden: Bool,
                isSymlink: Bool, size: Int64, created: Date?, modified: Date,
                contentType: UTType?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.size = size
        self.created = created
        self.modified = modified
        self.contentType = contentType
    }
}
```

- [ ] **Step 4: Create `Sources/FileExplorerCore/DirectoryLoader.swift`**

```swift
import Foundation

public enum DirectoryLoader {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .contentTypeKey,
    ]

    /// Synchronous, blocking load. Callers run it off the main actor.
    public static func load(_ directory: URL, includeHidden: Bool) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: includeHidden ? [] : [.skipsHiddenFiles])

        return urls.compactMap { url in
            guard let rv = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
                return nil
            }
            return FileEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: rv.isDirectory ?? false,
                isHidden: rv.isHidden ?? false,
                isSymlink: rv.isSymbolicLink ?? false,
                size: Int64(rv.fileSize ?? 0),
                created: rv.creationDate,
                modified: rv.contentModificationDate ?? .distantPast,
                contentType: rv.contentType)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: FileEntry model and DirectoryLoader"
```

---

### Task 3: FileSorter (folders-first sorting)

**Files:**
- Create: `Sources/FileExplorerCore/FileSorter.swift`
- Create: `Sources/FileExplorerTests/FileSorterTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/FileSorterTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func fileSorterTests() async {
    func entry(_ name: String, dir: Bool = false, size: Int64 = 0) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/t/\(name)"), name: name,
                  isDirectory: dir, isHidden: false, isSymlink: false,
                  size: size, created: nil, modified: .distantPast, contentType: nil)
    }

    await test("FileSorter sorts by name, folders first") {
        let items = [entry("zebra.txt"), entry("Apple", dir: true), entry("banana.txt")]
        let sorted = FileSorter.sort(items,
            using: [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)])
        expectEqual(sorted.map(\.name), ["Apple", "banana.txt", "zebra.txt"],
                    "folder first, then files by name")
    }

    await test("FileSorter respects descending size") {
        let items = [entry("small", size: 1), entry("big", size: 100), entry("mid", size: 50)]
        let sorted = FileSorter.sort(items,
            using: [KeyPathComparator(\FileEntry.size, order: .reverse)],
            foldersFirst: false)
        expectEqual(sorted.map(\.name), ["big", "mid", "small"], "descending by size")
    }

    await test("FileSorter can disable folders-first") {
        let items = [entry("b", dir: true), entry("a")]
        let sorted = FileSorter.sort(items,
            using: [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)],
            foldersFirst: false)
        expectEqual(sorted.map(\.name), ["a", "b"], "pure name order")
    }
}
```

Add to `main.swift` before `finish()`:

```swift
await fileSorterTests()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run FileExplorerTests`
Expected: build FAILS with "cannot find 'FileSorter' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/FileSorter.swift`**

```swift
import Foundation

public enum FileSorter {
    public static func sort(_ entries: [FileEntry],
                            using comparators: [KeyPathComparator<FileEntry>],
                            foldersFirst: Bool = true) -> [FileEntry] {
        let sorted = entries.sorted(using: comparators)
        guard foldersFirst else { return sorted }
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: FileSorter with folders-first ordering"
```

---

### Task 4: NavigationHistory

**Files:**
- Create: `Sources/FileExplorerCore/NavigationHistory.swift`
- Create: `Sources/FileExplorerTests/NavigationHistoryTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/NavigationHistoryTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func navigationHistoryTests() async {
    let a = URL(fileURLWithPath: "/a")
    let b = URL(fileURLWithPath: "/b")
    let c = URL(fileURLWithPath: "/c")

    await test("navigate pushes history and clears forward") {
        var h = NavigationHistory(current: a)
        expect(!h.canGoBack && !h.canGoForward, "fresh history has no back/forward")
        h.navigate(to: b)
        expectEqual(h.current, b, "current is b")
        expect(h.canGoBack, "can go back after navigate")
        h.goBack()
        expectEqual(h.current, a, "back returns to a")
        expect(h.canGoForward, "can go forward after back")
        h.navigate(to: c)
        expect(!h.canGoForward, "navigate clears forward stack")
    }

    await test("back/forward round-trip") {
        var h = NavigationHistory(current: a)
        h.navigate(to: b)
        h.navigate(to: c)
        h.goBack()
        h.goBack()
        expectEqual(h.current, a, "two backs reach a")
        h.goForward()
        h.goForward()
        expectEqual(h.current, c, "two forwards reach c")
    }

    await test("no-ops are safe") {
        var h = NavigationHistory(current: a)
        h.goBack()
        h.goForward()
        expectEqual(h.current, a, "back/forward on empty stacks do nothing")
        h.navigate(to: a)
        expect(!h.canGoBack, "navigating to current URL is a no-op")
    }
}
```

Add to `main.swift` before `finish()`:

```swift
await navigationHistoryTests()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run FileExplorerTests`
Expected: build FAILS with "cannot find 'NavigationHistory' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/NavigationHistory.swift`**

```swift
import Foundation

public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    public init(current: URL) {
        self.current = current
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public mutating func navigate(to url: URL) {
        guard url != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = url
    }

    public mutating func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    public mutating func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: NavigationHistory back/forward stack"
```

---

### Task 5: DirectoryWatcher

**Files:**
- Create: `Sources/FileExplorerCore/DirectoryWatcher.swift`
- Create: `Sources/FileExplorerTests/DirectoryWatcherTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/DirectoryWatcherTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func directoryWatcherTests() async {
    await test("DirectoryWatcher fires on file creation (debounced)") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatcher()
        var fired = 0
        watcher.watch(dir) { fired += 1 }

        try Data().write(to: dir.appendingPathComponent("new1.txt"))
        try Data().write(to: dir.appendingPathComponent("new2.txt"))

        // Debounce is 200 ms; wait comfortably past it.
        try await Task.sleep(for: .milliseconds(600))
        expectEqual(fired, 1, "two rapid writes coalesce into one callback")

        try Data().write(to: dir.appendingPathComponent("new3.txt"))
        try await Task.sleep(for: .milliseconds(600))
        expectEqual(fired, 2, "later write fires again")

        watcher.stop()
        try Data().write(to: dir.appendingPathComponent("new4.txt"))
        try await Task.sleep(for: .milliseconds(600))
        expectEqual(fired, 2, "no callback after stop")
    }

    await test("DirectoryWatcher ignores unopenable paths") {
        let watcher = DirectoryWatcher()
        watcher.watch(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) {
            expect(false, "must not fire for missing dir")
        }
        try await Task.sleep(for: .milliseconds(300))
        expect(true, "no crash watching a missing path")
        watcher.stop()
    }
}
```

Add to `main.swift` before `finish()`:

```swift
await directoryWatcherTests()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run FileExplorerTests`
Expected: build FAILS with "cannot find 'DirectoryWatcher' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/DirectoryWatcher.swift`**

```swift
import Foundation

/// Watches one directory via a kqueue DispatchSource and invokes the callback
/// on the main actor after a 200 ms debounce. Re-calling `watch` replaces the
/// previous watch.
@MainActor
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init() {}

    public func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main)

        // The source is bound to the main queue, so the handler really does run
        // on the main actor even though DispatchSource can't express that.
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending?.cancel()
                let work = DispatchWorkItem { Task { @MainActor in onChange() } }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0. (Timing-based — if the debounce assertion flakes, re-run once; persistent failure = real bug.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: DirectoryWatcher with debounced change events"
```

---

### Task 6: PaneState (observable pane model)

**Files:**
- Create: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerTests/PaneStateTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/PaneStateTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func paneStateTests() async {
    await test("PaneState loads, navigates, and filters hidden files") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("f.txt"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try Data().write(to: sub.appendingPathComponent("inner.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        expectEqual(pane.entries.count, 2, "loads visible entries")
        expectEqual(pane.currentURL, dir, "currentURL is start dir")

        pane.showHidden = true
        await pane.reload()
        expectEqual(pane.entries.count, 3, "showHidden reveals dotfile")

        await pane.navigate(to: sub)
        expectEqual(pane.currentURL, sub, "navigated into sub")
        expectEqual(pane.entries.map(\.name), ["inner.txt"], "sub contents loaded")
        expect(pane.canGoBack, "history recorded")

        pane.selection.insert(sub.appendingPathComponent("inner.txt"))
        await pane.goBack()
        expectEqual(pane.currentURL, dir, "back to start dir")
        expect(pane.selection.isEmpty, "selection cleared on navigation")

        await pane.goUp()
        expectEqual(pane.currentURL, dir.deletingLastPathComponent(), "goUp reaches parent")
    }

    await test("PaneState surfaces load errors") {
        let pane = PaneState(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        await pane.reload()
        expect(pane.errorMessage != nil, "errorMessage set for unreadable dir")
        expect(pane.entries.isEmpty, "entries empty on error")
    }

    await test("PaneState sorts via sortOrder") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("xx".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        expectEqual(pane.visibleEntries.map(\.name), ["a.txt", "b.txt"], "default name sort")

        pane.sortOrder = [KeyPathComparator(\FileEntry.size, order: .reverse)]
        expectEqual(pane.visibleEntries.map(\.name), ["b.txt", "a.txt"], "size sort applies")
    }
}
```

Add to `main.swift` before `finish()`:

```swift
await paneStateTests()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run FileExplorerTests`
Expected: build FAILS with "cannot find 'PaneState' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/PaneState.swift`**

```swift
import Foundation
import Observation

@MainActor
@Observable
public final class PaneState {
    public private(set) var history: NavigationHistory
    public var entries: [FileEntry] = [] {
        didSet { applySort() }
    }
    public var selection = Set<URL>()
    public var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)
    ] {
        didSet { applySort() }
    }
    public var showHidden = false
    public var errorMessage: String?

    /// Sorted snapshot of `entries`. Stored rather than computed so SwiftUI
    /// body evaluations don't re-sort large directories; refreshed only when
    /// `entries` or `sortOrder` changes.
    public private(set) var visibleEntries: [FileEntry] = []

    private let watcher = DirectoryWatcher()

    public var currentURL: URL { history.current }
    public var canGoBack: Bool { history.canGoBack }
    public var canGoForward: Bool { history.canGoForward }
    public var canGoUp: Bool { currentURL.path != "/" }

    public init(url: URL) {
        // Standardize so NavigationHistory's exact-URL-equality no-op check
        // works for equivalent paths (trailing slash, "." components).
        history = NavigationHistory(current: url.standardizedFileURL)
    }

    /// Call once from the UI to begin watching; tests skip this.
    public func start() {
        watchCurrent()
    }

    public func navigate(to url: URL) async {
        history.navigate(to: url.standardizedFileURL)
        await afterNavigation()
    }

    private func applySort() {
        visibleEntries = FileSorter.sort(entries, using: sortOrder)
    }

    public func goBack() async {
        history.goBack()
        await afterNavigation()
    }

    public func goForward() async {
        history.goForward()
        await afterNavigation()
    }

    public func goUp() async {
        guard canGoUp else { return }
        await navigate(to: currentURL.deletingLastPathComponent())
    }

    public func reload() async {
        let url = currentURL
        let includeHidden = showHidden
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try DirectoryLoader.load(url, includeHidden: includeHidden)
            }.value
            entries = loaded
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func afterNavigation() async {
        selection.removeAll()
        watchCurrent()
        await reload()
    }

    private func watchCurrent() {
        watcher.watch(currentURL) { [weak self] in
            Task { await self?.reload() }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: PaneState observable pane model"
```

---

### Task 7: File table UI (browse + open)

**Files:**
- Create: `Sources/FileExplorer/AppState.swift`
- Create: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

No unit tests — UI glue; verified by running the app. Keep all logic in Core.

- [ ] **Step 1: Create `Sources/FileExplorer/AppState.swift`**

```swift
import Foundation
import FileExplorerCore
import Observation

@MainActor
@Observable
final class AppState {
    let pane: PaneState

    init() {
        pane = PaneState(url: FileManager.default.homeDirectoryForCurrentUser)
        pane.start()
        Task { await pane.reload() }
    }
}
```

- [ ] **Step 2: Create `Sources/FileExplorer/PaneView.swift`**

```swift
import SwiftUI
import FileExplorerCore

struct PaneView: View {
    @Bindable var pane: PaneState

    var body: some View {
        Table(pane.visibleEntries, selection: $pane.selection,
              sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(entry.name)
                        .lineLimit(1)
                }
            }
            TableColumn("Size", value: \.size) { entry in
                if entry.isDirectory {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    Text(entry.size, format: .byteCount(style: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { entry in
                Text(entry.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Date Modified", value: \.modified) { entry in
                Text(entry.modified,
                     format: .dateTime.year().month(.abbreviated).day()
                        .hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: URL.self) { _ in
            // Context menu items arrive in Milestone 6 (file operations).
        } primaryAction: { urls in
            open(urls)
        }
        .overlay {
            if let message = pane.errorMessage {
                ContentUnavailableView(
                    "Can't Read Folder",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message))
            } else if pane.visibleEntries.isEmpty {
                ContentUnavailableView(
                    "Empty Folder", systemImage: "folder")
            }
        }
    }

    private func open(_ urls: Set<URL>) {
        // Double-clicking exactly one folder navigates into it;
        // anything else opens with the default app.
        if urls.count == 1, let url = urls.first,
           pane.entries.first(where: { $0.url == url })?.isDirectory == true {
            Task { await pane.navigate(to: url) }
        } else {
            for url in urls { NSWorkspace.shared.open(url) }
        }
    }
}
```

- [ ] **Step 3: Replace `Sources/FileExplorer/FileExplorerApp.swift`**

```swift
import SwiftUI
import FileExplorerCore

@main
struct FileExplorerApp: App {
    @State private var appState = AppState()

    init() {
        // When launched from `swift run` (no bundle), become a regular
        // foreground app so the window appears and takes focus.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            PaneView(pane: appState.pane)
                .frame(minWidth: 600, minHeight: 400)
                .navigationTitle(appState.pane.currentURL.lastPathComponent)
        }
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build && swift run FileExplorer` (leave running)
Expected: a window listing the home directory with Name/Size/Kind/Date Modified columns, sortable by clicking headers. Double-click a folder → navigates in; double-click a file → opens in its default app. Then quit (⌘Q or kill).

- [ ] **Step 5: Run tests (regression)**

Run: `swift run FileExplorerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: file table UI with sorting and double-click navigation"
```

---

### Task 8: Breadcrumbs, toolbar, and Go menu

**Files:**
- Create: `Sources/FileExplorer/BreadcrumbView.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

- [ ] **Step 1: Create `Sources/FileExplorer/BreadcrumbView.swift`**

```swift
import SwiftUI
import FileExplorerCore

struct BreadcrumbView: View {
    @Bindable var pane: PaneState

    /// Ancestor URLs from root to the current folder, e.g.
    /// [/, /Users, /Users/mlaplante].
    private var crumbs: [URL] {
        var urls: [URL] = []
        var url = pane.currentURL.standardizedFileURL
        while true {
            urls.append(url)
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return urls.reversed()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(crumbs, id: \.self) { crumb in
                    Button {
                        Task { await pane.navigate(to: crumb) }
                    } label: {
                        Text(crumb.path == "/" ? "/" : crumb.lastPathComponent)
                            .fontWeight(crumb == crumbs.last ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    if crumb != crumbs.last {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 24)
    }
}
```

- [ ] **Step 2: Add breadcrumb + status bar around the table in `PaneView.swift`**

Wrap the existing `Table` in a `VStack`. Replace the `body` property's outermost structure so it reads:

```swift
    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbView(pane: pane)
            Divider()
            table
            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(pane.visibleEntries.count) items")
            if !pane.selection.isEmpty {
                Text("· \(pane.selection.count) selected")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var table: some View {
        // ... the existing Table(...) { } .contextMenu(...) .overlay { } code,
        // moved verbatim from the old body into this computed property.
    }
```

(The `table` property holds the exact Table code from Task 7 — cut and paste it unchanged.)

- [ ] **Step 3: Add toolbar and Go menu in `FileExplorerApp.swift`**

Replace the `body` scene with:

```swift
    var body: some Scene {
        WindowGroup {
            PaneView(pane: appState.pane)
                .frame(minWidth: 600, minHeight: 400)
                .navigationTitle(appState.pane.currentURL.lastPathComponent)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            Task { await appState.pane.goBack() }
                        } label: { Image(systemName: "chevron.left") }
                        .disabled(!appState.pane.canGoBack)
                        .help("Back")

                        Button {
                            Task { await appState.pane.goForward() }
                        } label: { Image(systemName: "chevron.right") }
                        .disabled(!appState.pane.canGoForward)
                        .help("Forward")

                        Button {
                            Task { await appState.pane.goUp() }
                        } label: { Image(systemName: "chevron.up") }
                        .disabled(!appState.pane.canGoUp)
                        .help("Enclosing Folder")
                    }
                }
        }
        .commands {
            CommandMenu("Go") {
                Button("Back") { Task { await appState.pane.goBack() } }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!appState.pane.canGoBack)
                Button("Forward") { Task { await appState.pane.goForward() } }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!appState.pane.canGoForward)
                Button("Enclosing Folder") { Task { await appState.pane.goUp() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!appState.pane.canGoUp)
                Divider()
                Button("Home") {
                    Task {
                        await appState.pane.navigate(
                            to: FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
```

- [ ] **Step 4: Build and verify**

Run: `swift run FileExplorer`
Expected: breadcrumb bar above the table (click a segment to jump), status bar below with item/selection counts, back/forward/up toolbar buttons that enable/disable correctly, Go menu with working ⌘[, ⌘], ⌘↑, ⇧⌘H.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: breadcrumbs, status bar, toolbar and Go menu navigation"
```

---

### Task 9: Sidebar (bookmarks + volumes)

**Files:**
- Create: `Sources/FileExplorer/SidebarView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

- [ ] **Step 1: Create `Sources/FileExplorer/SidebarView.swift`**

```swift
import SwiftUI
import FileExplorerCore

struct SidebarView: View {
    @Bindable var pane: PaneState

    private struct Place: Identifiable, Hashable {
        let name: String
        let url: URL
        let icon: String
        var id: URL { url }
    }

    private var favorites: [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var places = [Place(name: "Home", url: home, icon: "house")]
        let standard: [(String, FileManager.SearchPathDirectory, String)] = [
            ("Desktop", .desktopDirectory, "menubar.dock.rectangle"),
            ("Documents", .documentDirectory, "doc"),
            ("Downloads", .downloadsDirectory, "arrow.down.circle"),
            ("Pictures", .picturesDirectory, "photo"),
        ]
        for (name, dir, icon) in standard {
            if let url = fm.urls(for: dir, in: .userDomainMask).first,
               fm.fileExists(atPath: url.path) {
                places.append(Place(name: name, url: url, icon: icon))
            }
        }
        return places
    }

    private var volumes: [Place] {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?
                .volumeName ?? url.lastPathComponent
            return Place(name: name, url: url, icon: "externaldrive")
        }
    }

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(favorites) { place in row(place) }
            }
            Section("Volumes") {
                ForEach(volumes) { place in row(place) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ place: Place) -> some View {
        Button {
            Task { await pane.navigate(to: place.url) }
        } label: {
            Label(place.name, systemImage: place.icon)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Wrap the window content in `NavigationSplitView` in `FileExplorerApp.swift`**

Replace the `WindowGroup` content (keep the `.commands` block unchanged):

```swift
        WindowGroup {
            NavigationSplitView {
                SidebarView(pane: appState.pane)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            } detail: {
                PaneView(pane: appState.pane)
                    .navigationTitle(appState.pane.currentURL.lastPathComponent)
                    .toolbar {
                        // ... the existing ToolbarItemGroup from Task 8, unchanged
                    }
            }
            .frame(minWidth: 760, minHeight: 400)
        }
```

- [ ] **Step 3: Build and verify**

Run: `swift run FileExplorer`
Expected: sidebar with Favorites (Home/Desktop/Documents/Downloads/Pictures) and Volumes (at least Macintosh HD); clicking any entry navigates the pane; sidebar collapses with the toolbar button.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: sidebar with favorites and mounted volumes"
```

---

### Task 10: Hidden-file toggle (⇧⌘.)

**Files:**
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

- [ ] **Step 1: Add a View menu command**

Inside `.commands { }`, after the `CommandMenu("Go") { }` block, add:

```swift
            CommandGroup(after: .toolbar) {
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { appState.pane.showHidden },
                    set: { newValue in
                        appState.pane.showHidden = newValue
                        Task { await appState.pane.reload() }
                    }))
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
```

- [ ] **Step 2: Build and verify**

Run: `swift run FileExplorer`
Expected: View menu contains "Show Hidden Files" with a checkmark state; pressing ⇧⌘. in the home folder toggles dotfiles (e.g. `.zshrc`) in and out of the table.

- [ ] **Step 3: Run tests (regression)**

Run: `swift run FileExplorerTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: show hidden files toggle (shift-cmd-period)"
```

---

### Task 11: App bundle script

**Files:**
- Create: `Resources/Info.plist`
- Create: `Scripts/bundle.sh` (mode 755)

- [ ] **Step 1: Create `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>FileExplorer</string>
    <key>CFBundleDisplayName</key>
    <string>FileExplorer</string>
    <key>CFBundleIdentifier</key>
    <string>com.mlaplante.FileExplorer</string>
    <key>CFBundleExecutable</key>
    <string>FileExplorer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Create `Scripts/bundle.sh`**

```bash
#!/bin/bash
# Assemble FileExplorer.app from the SPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/FileExplorer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FileExplorer "$APP/Contents/MacOS/FileExplorer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
```

Run: `chmod +x Scripts/bundle.sh`

- [ ] **Step 3: Build the bundle and verify**

Run: `./Scripts/bundle.sh && open build/FileExplorer.app`
Expected: script prints `Built build/FileExplorer.app`; the app launches as a normal foreground app (appears in Dock as FileExplorer) with the full browse UI working.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: app bundle script and Info.plist"
```

---

### Task 12: Final milestone verification

**Files:** none (verification only)

- [ ] **Step 1: Full test run**

Run: `swift run FileExplorerTests`
Expected: PASS, 0 failures.

- [ ] **Step 2: End-to-end walkthrough**

Run: `open build/FileExplorer.app` and verify each Milestone 1 requirement:

1. Home folder listed with icons, sizes, kinds, dates.
2. Column-header click re-sorts; folders stay grouped first on name sort.
3. Double-click folder navigates; ⌘[ goes back; ⌘] forward; ⌘↑ up.
4. Breadcrumb segment click jumps to an ancestor.
5. Sidebar Favorites and Volumes navigate.
6. ⇧⌘. toggles hidden files.
7. In Terminal: `touch ~/from-terminal.txt` while viewing Home → file appears within ~1 s (watcher). `rm ~/from-terminal.txt` → disappears.
8. Status bar counts update with selection.

- [ ] **Step 3: Fix anything that fails, re-verify, then commit any fixes**

```bash
git add -A
git commit -m "fix: milestone 1 verification fixes"   # only if fixes were needed
```
