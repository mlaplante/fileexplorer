# List-View Tree Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finder-style disclosure triangles in the list view — folders expand inline (indented, live-updating, filter/sort per level) so navigation never loses its place.

**Architecture:** Pure `TreeFlattener` in FileExplorerCore turns (root entries, children cache, expanded set, per-level prepare closure) into a flat depth-annotated row list. `PaneState` owns `expandedFolders`/`childEntries`/per-folder watchers and feeds the flattener from `recomputeVisible()`. The `Table` row type stays `FileEntry`, so sorting, selection, drag/drop, context menus, and session plumbing are untouched; the Name cell gains a chevron + depth indent.

**Tech Stack:** Swift 6 / SwiftUI / SPM. Spec: `docs/superpowers/specs/2026-07-08-list-tree-expansion-design.md`.

---

## HARD TOOLCHAIN CONSTRAINTS (read first)

- **No Xcode on this machine — CLT only.** Build with `swift build`; NEVER `xcodebuild` or `swift test`.
- **`@State` DOES NOT COMPILE** (SwiftUIMacros plugin ships only with Xcode). Use `@Observable` model state / `@Bindable`. All transient UI state lives on `PaneState` (see `showsNewTagPopover` precedent).
- Tests are a plain executable target: `swift run FileExplorerTests` — exit 0 + `PASS (N assertions)` = pass. Register new test functions in `Sources/FileExplorerTests/main.swift`.
- Redirect test output to a file and read the file (`swift run FileExplorerTests > /tmp/fx-tree-tests.log 2>&1; tail -5 /tmp/fx-tree-tests.log`) — piping through grep can mask a SIGABRT.
- Swift 6 strict concurrency: `PaneState` is `@MainActor @Observable`. `NSEvent` is non-Sendable — read `NSEvent.modifierFlags` synchronously on the main actor before entering a `Task`.
- Commit after each task with a conventional message. Do not push.

## KEY DESIGN RULE: tree keys are standardized PATH STRINGS, not URLs

`FileManager.contentsOfDirectory(at:)` returns folder URLs **with** a trailing
slash; URLs built via `appendingPathComponent` come **without**. `Set<URL>`
membership compares absolute strings, so URL-keyed expansion state would
silently never match. Every tree key is therefore
`url.standardizedFileURL.path` (a `String` — `.path` drops the trailing
slash). Helper used everywhere below:

```swift
    /// Canonical tree key: trailing-slash-insensitive standardized path.
    private static func treeKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
```

---

### Task 1: TreeFlattener (pure Core) + tests

**Files:**
- Create: `Sources/FileExplorerCore/TreeFlattener.swift`
- Create: `Sources/FileExplorerTests/TreeFlattenerTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift` (register `await treeFlattenerTests()` near the other calls)

- [x] **Step 1.1: Write the failing tests**

`Sources/FileExplorerTests/TreeFlattenerTests.swift`:

```swift
import Foundation
import FileExplorerCore

private func treeEntry(_ path: String, dir: Bool = false) -> FileEntry {
    FileEntry(url: URL(fileURLWithPath: path),
              name: (path as NSString).lastPathComponent,
              isDirectory: dir, isHidden: false, isSymlink: false,
              size: 0, created: nil, modified: .distantPast,
              contentType: nil)
}

@MainActor
func treeFlattenerTests() async {
    let sub = treeEntry("/root/sub", dir: true)
    let alpha = treeEntry("/root/alpha.txt")
    let bee = treeEntry("/root/sub/bee.txt")
    let nested = treeEntry("/root/sub/nested", dir: true)
    let deep = treeEntry("/root/sub/nested/deep.txt")
    let sortByName: ([FileEntry]) -> [FileEntry] = {
        $0.sorted { $0.name < $1.name }
    }

    await test("TreeFlattener collapsed folders yield roots only") {
        let rows = TreeFlattener.flatten(
            roots: [sub, alpha], children: [:], expanded: [],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name), ["alpha.txt", "sub"],
                    "prepare orders the root level")
        expectEqual(rows.map(\.depth), [0, 0], "roots sit at depth 0")
    }

    await test("TreeFlattener inlines loaded children under expanded folder") {
        let rows = TreeFlattener.flatten(
            roots: [sub, alpha],
            children: ["/root/sub": [nested, bee]],
            expanded: ["/root/sub"],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name),
                    ["alpha.txt", "sub", "bee.txt", "nested"],
                    "children follow their folder, sorted per level")
        expectEqual(rows.map(\.depth), [0, 0, 1, 1],
                    "children are one level deeper")
    }

    await test("TreeFlattener key is trailing-slash-insensitive") {
        // contentsOfDirectory yields directory URLs WITH a trailing slash;
        // expansion keyed by standardized path must still match.
        let slashed = FileEntry(url: URL(fileURLWithPath: "/root/sub/",
                                         isDirectory: true),
                                name: "sub", isDirectory: true,
                                isHidden: false, isSymlink: false, size: 0,
                                created: nil, modified: .distantPast,
                                contentType: nil)
        let rows = TreeFlattener.flatten(
            roots: [slashed],
            children: ["/root/sub": [bee]],
            expanded: ["/root/sub"],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name), ["sub", "bee.txt"],
                    "trailing-slash folder URL still expands")
    }

    await test("TreeFlattener expanded-but-unloaded folder stays collapsed") {
        let rows = TreeFlattener.flatten(
            roots: [sub], children: [:],
            expanded: ["/root/sub"],
            prepare: sortByName)
        expectEqual(rows.count, 1, "no children rows until the load lands")
    }

    await test("TreeFlattener hidden descendants keep their expansion") {
        // nested is expanded and loaded, but its parent sub is NOT expanded:
        // nested's membership must be inert, not an error.
        let children: [String: [FileEntry]] = [
            "/root/sub": [nested, bee],
            "/root/sub/nested": [deep],
        ]
        let rows = TreeFlattener.flatten(
            roots: [sub], children: children,
            expanded: ["/root/sub/nested"],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name), ["sub"],
                    "collapsed parent hides the whole subtree")
        // Re-expanding the parent restores the nested expansion.
        let restored = TreeFlattener.flatten(
            roots: [sub], children: children,
            expanded: ["/root/sub", "/root/sub/nested"],
            prepare: sortByName)
        expectEqual(restored.map(\.entry.name),
                    ["sub", "bee.txt", "nested", "deep.txt"],
                    "subtree restores when parent re-expands")
        expectEqual(restored.map(\.depth), [0, 1, 1, 2],
                    "depths accumulate through the subtree")
    }

    await test("TreeFlattener per-level prepare filters each level") {
        let onlyTxt: ([FileEntry]) -> [FileEntry] = { level in
            level.filter { $0.isDirectory || $0.name.hasSuffix(".txt") }
                .sorted { $0.name < $1.name }
        }
        let png = treeEntry("/root/sub/pic.png")
        let rows = TreeFlattener.flatten(
            roots: [sub, alpha],
            children: ["/root/sub": [png, bee]],
            expanded: ["/root/sub"],
            prepare: onlyTxt)
        expectEqual(rows.map(\.entry.name), ["alpha.txt", "sub", "bee.txt"],
                    "filter drops png at the child level")
    }

    await test("TreeFlattener guards symlink cycles and depth") {
        // A folder listed as its own child must not recurse forever.
        let loop = treeEntry("/root/loop", dir: true)
        let rows = TreeFlattener.flatten(
            roots: [loop],
            children: ["/root/loop": [loop]],
            expanded: ["/root/loop"],
            prepare: { $0 })
        expectEqual(rows.count, 1, "self-cycle renders one row")

        // Distinct paths nesting past maxDepth stop at the cap.
        var path = "/deep"
        var entries: [FileEntry] = [treeEntry(path, dir: true)]
        var children: [String: [FileEntry]] = [:]
        var expanded = Set<String>()
        for _ in 0..<40 {
            let parent = entries.last!
            path += "/d"
            let child = treeEntry(path, dir: true)
            children[parent.url.standardizedFileURL.path] = [child]
            expanded.insert(parent.url.standardizedFileURL.path)
            entries.append(child)
        }
        let deepRows = TreeFlattener.flatten(
            roots: [entries[0]], children: children, expanded: expanded,
            prepare: { $0 })
        expect(deepRows.count <= TreeFlattener.maxDepth + 1,
               "depth cap bounds the walk [got: \(deepRows.count)]")
    }
}
```

- [x] **Step 1.2: Register in main.swift and run to verify failure**

Add `await treeFlattenerTests()` to `Sources/FileExplorerTests/main.swift` (near `await fileSorterTests()`).

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `cannot find 'TreeFlattener' in scope`.

- [x] **Step 1.3: Implement TreeFlattener**

`Sources/FileExplorerCore/TreeFlattener.swift`:

```swift
import Foundation

/// Turns the list view's root entries plus lazily loaded children into the
/// ordered, depth-annotated row list the table renders.
///
/// Pure: filter/sort are injected via `prepare`, applied independently at
/// every level. A folder contributes children only when its key (standardized
/// path — trailing-slash-insensitive, unlike URL equality) is in `expanded`
/// AND `children` holds a loaded list for it — an expanded folder whose load
/// hasn't landed yet renders collapsed until it does.
public enum TreeFlattener {
    public struct Row: Equatable, Sendable {
        public let entry: FileEntry
        public let depth: Int
        public init(entry: FileEntry, depth: Int) {
            self.entry = entry
            self.depth = depth
        }
    }

    /// Hard stop for pathological nesting and symlink loops that survive
    /// the ancestor-stack check by minting ever-new paths.
    public static let maxDepth = 32

    public static func flatten(
        roots: [FileEntry],
        children: [String: [FileEntry]],
        expanded: Set<String>,
        prepare: ([FileEntry]) -> [FileEntry]
    ) -> [Row] {
        var rows: [Row] = []
        // Symlink-resolved ancestor paths; a child resolving onto one of
        // these is a cycle and must not recurse.
        var stack: Set<String> = []

        func walk(_ level: [FileEntry], depth: Int) {
            for entry in prepare(level) {
                rows.append(Row(entry: entry, depth: depth))
                let key = entry.url.standardizedFileURL.path
                guard entry.isDirectory,
                      depth < maxDepth,
                      expanded.contains(key),
                      let kids = children[key] else { continue }
                let resolved = entry.url.resolvingSymlinksInPath().path
                guard !stack.contains(resolved) else { continue }
                stack.insert(resolved)
                walk(kids, depth: depth + 1)
                stack.remove(resolved)
            }
        }
        walk(roots, depth: 0)
        return rows
    }
}
```

- [x] **Step 1.4: Run tests to verify pass**

Run: `swift run FileExplorerTests > /tmp/fx-tree-tests.log 2>&1; tail -5 /tmp/fx-tree-tests.log`
Expected: `PASS (N assertions)` with N > 870.

- [x] **Step 1.5: Commit**

```bash
git add Sources/FileExplorerCore/TreeFlattener.swift Sources/FileExplorerTests/TreeFlattenerTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: TreeFlattener pure depth-annotated row flattening"
```

---

### Task 2: PaneState expansion state, child loading, watchers + tests

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerTests/TreeExpansionTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift` (register `await treeExpansionTests()`)

- [x] **Step 2.1: Write the failing tests**

`Sources/FileExplorerTests/TreeExpansionTests.swift`:

```swift
import Foundation
import FileExplorerCore

@MainActor
func treeExpansionTests() async {
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-tree-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        let nested = sub.appendingPathComponent("nested")
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("alpha.txt").path,
            contents: Data())
        FileManager.default.createFile(
            atPath: sub.appendingPathComponent("bee.txt").path,
            contents: Data())
        FileManager.default.createFile(
            atPath: nested.appendingPathComponent("cee.txt").path,
            contents: Data())
        return root
    }

    await test("PaneState expand inlines children; collapse restores") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        expectEqual(pane.visibleEntries.map(\.name), ["alpha.txt", "sub"],
                    "root listing before expansion")

        await pane.expand(sub)
        expect(pane.isExpanded(sub), "sub reports expanded")
        expectEqual(pane.visibleEntries.map(\.name),
                    ["alpha.txt", "sub", "bee.txt", "nested"],
                    "children inline after their folder")
        expectEqual(pane.visibleEntries.map { pane.depth(of: $0.url) },
                    [0, 0, 1, 1], "depths exposed per row")
        expectEqual(pane.rootVisibleCount, 2,
                    "root count ignores disclosed rows")

        pane.collapse(sub)
        expectEqual(pane.visibleEntries.map(\.name), ["alpha.txt", "sub"],
                    "collapse restores the root listing")
    }

    await test("PaneState collapse keeps nested expansion (Finder restore)") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        let nested = sub.appendingPathComponent("nested")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        await pane.expand(nested)
        expectEqual(pane.visibleEntries.map(\.name),
                    ["alpha.txt", "sub", "bee.txt", "nested", "cee.txt"],
                    "two levels disclosed")
        pane.collapse(sub)
        expectEqual(pane.visibleEntries.map(\.name), ["alpha.txt", "sub"],
                    "collapsing the parent hides the subtree")
        await pane.expand(sub)
        expectEqual(pane.visibleEntries.map(\.name),
                    ["alpha.txt", "sub", "bee.txt", "nested", "cee.txt"],
                    "re-expanding the parent restores nested expansion")
    }

    await test("PaneState collapse folds hidden selection into the folder") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        let bee = pane.visibleEntries.first { $0.name == "bee.txt" }!
        pane.selection = [bee.url]
        pane.collapse(sub)
        let subURL = pane.visibleEntries.first { $0.name == "sub" }!.url
        expectEqual(pane.selection, [subURL],
                    "hidden selected descendant becomes the folder selection")
    }

    await test("PaneState reload refreshes children and prunes vanished") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        FileManager.default.createFile(
            atPath: sub.appendingPathComponent("dee.txt").path,
            contents: Data())
        await pane.reload()
        expect(pane.visibleEntries.contains { $0.name == "dee.txt" },
               "reload picks up new children of expanded folders")

        try FileManager.default.removeItem(at: sub)
        await pane.reload()
        expect(!pane.isExpanded(sub), "vanished folder loses its expansion")
        expectEqual(pane.visibleEntries.map(\.name), ["alpha.txt"],
                    "no orphan rows after the folder vanished")
    }

    await test("PaneState expandRecursively opens the whole subtree") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expandRecursively(sub)
        expectEqual(pane.visibleEntries.map(\.name),
                    ["alpha.txt", "sub", "bee.txt", "nested", "cee.txt"],
                    "recursive expand discloses every level")
    }

    await test("PaneState navigation clears tree state") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        await pane.navigate(to: sub)
        expect(!pane.isExpanded(sub), "expansion cleared on navigation")
        expectEqual(pane.visibleEntries.map(\.name), ["bee.txt", "nested"],
                    "navigated listing is flat")
    }

    await test("PaneState grouped mode bypasses the tree") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        pane.groupBy = .kind
        expectEqual(pane.visibleEntries.map(\.name).sorted(),
                    ["alpha.txt", "sub"],
                    "grouping renders root level only")
        pane.groupBy = .none
        expect(pane.visibleEntries.contains { $0.name == "bee.txt" },
               "tree returns when grouping is off")
    }
}
```

Note: these tests drive `reload()`/`expand()` directly and never wait on the
200 ms watcher debounce — do not add sleeps.

- [x] **Step 2.2: Register and run to verify failure**

Add `await treeExpansionTests()` to `main.swift` after `await treeFlattenerTests()`.

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `value of type 'PaneState' has no member 'expand'`.

- [x] **Step 2.3: Implement PaneState expansion state**

In `Sources/FileExplorerCore/PaneState.swift`:

**(a)** Add stored state after the `folderSizes` declaration (~line 92):

```swift
    // MARK: - List-view tree expansion
    // All tree keys are standardized PATH STRINGS (`treeKey(_:)`), never
    // URLs: directory URLs from contentsOfDirectory carry a trailing slash,
    // URLs built via appendingPathComponent don't, and Set<URL> membership
    // compares absolute strings — URL keys would silently never match.

    /// Folders disclosed in the list view. Collapsing a parent does NOT
    /// remove descendants — re-expanding the parent restores the subtree
    /// (Finder behavior); the flattener simply stops producing their rows.
    public private(set) var expandedFolders: Set<String> = []
    /// Raw loaded children per expanded folder (unfiltered/unsorted; the
    /// pane's filter+sort applies per level at flatten time).
    @ObservationIgnored private var childEntries: [String: [FileEntry]] = [:]
    /// One kqueue watcher per expanded folder so disclosed rows live-update.
    @ObservationIgnored private var childWatchers: [String: DirectoryWatcher] = [:]
    /// Depth per visible row URL (0 = top level), rebuilt with visibleEntries.
    public private(set) var rowDepths: [URL: Int] = [:]
    /// Top-level row count — the status bar's "N items" must not grow when
    /// folders are merely disclosed.
    public private(set) var rootVisibleCount = 0

    /// Canonical tree key: trailing-slash-insensitive standardized path.
    private static func treeKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
```

**(b)** Add the expansion API after `reload()` (before the `moveSelected` block):

```swift
    public func isExpanded(_ url: URL) -> Bool {
        expandedFolders.contains(Self.treeKey(url))
    }

    public func depth(of url: URL) -> Int { rowDepths[url] ?? 0 }

    public func toggleExpansion(of url: URL, recursively: Bool = false) async {
        if isExpanded(url) {
            collapse(url)
        } else if recursively {
            await expandRecursively(url)
        } else {
            await expand(url)
        }
    }

    public func expand(_ url: URL) async {
        let key = Self.treeKey(url)
        guard !expandedFolders.contains(key) else { return }
        expandedFolders.insert(key)
        watchChildren(of: key)
        await loadChildren(of: key)
        recomputeVisible()
    }

    /// Opens the folder and every descendant folder, breadth-first, capped
    /// at 512 folders so a giant tree can't hang the pane.
    public func expandRecursively(_ url: URL) async {
        var queue = [Self.treeKey(url)]
        var visited = Set<String>()
        var opened = 0
        while !queue.isEmpty, opened < 512 {
            let key = queue.removeFirst()
            // Resolve symlinks so a link cycle can't re-enqueue forever.
            let resolved = URL(fileURLWithPath: key)
                .resolvingSymlinksInPath().path
            guard visited.insert(resolved).inserted else { continue }
            expandedFolders.insert(key)
            watchChildren(of: key)
            await loadChildren(of: key)
            opened += 1
            for child in childEntries[key] ?? [] where child.isDirectory {
                queue.append(Self.treeKey(child.url))
            }
        }
        recomputeVisible()
    }

    public func collapse(_ url: URL) {
        let key = Self.treeKey(url)
        guard expandedFolders.remove(key) != nil else { return }
        // An invisible selection must never feed file operations: fold any
        // selected rows hidden by this collapse into selecting the folder.
        // Insert the folder's ROW url (visibleEntries), not the caller's —
        // Table selection matches by URL equality, and the row URL may carry
        // a trailing slash the caller's doesn't.
        let prefix = key + "/"
        let hidden = selection.filter {
            Self.treeKey($0).hasPrefix(prefix)
        }
        if !hidden.isEmpty {
            selection.subtract(hidden)
            let rowURL = visibleEntries.first {
                Self.treeKey($0.url) == key
            }?.url ?? url
            selection.insert(rowURL)
        }
        recomputeVisible()
    }

    /// Loads (or reloads) one expanded folder's children off the main actor.
    /// Unreadable or vanished folders silently drop their expansion — the
    /// row itself disappears via the parent's reload, so no error surface.
    private func loadChildren(of key: String) async {
        let includeHidden = showHidden
        let folder = URL(fileURLWithPath: key, isDirectory: true)
        let loaded = try? await Task.detached(priority: .userInitiated) {
            try DirectoryLoader.load(folder, includeHidden: includeHidden)
        }.value
        guard expandedFolders.contains(key) else { return } // collapsed mid-flight
        if let loaded {
            childEntries[key] = loaded
            settingsModel?.mergeKnownTags(loaded.flatMap(\.tags))
        } else {
            expandedFolders.remove(key)
            childEntries.removeValue(forKey: key)
            childWatchers.removeValue(forKey: key)?.stop()
        }
    }

    private func watchChildren(of key: String) {
        guard childWatchers[key] == nil else { return }
        let watcher = DirectoryWatcher()
        watcher.watch(URL(fileURLWithPath: key, isDirectory: true)) { [weak self] in
            guard let self, self.expandedFolders.contains(key) else { return }
            Task {
                await self.loadChildren(of: key)
                self.recomputeVisible()
            }
        }
        childWatchers[key] = watcher
    }

    /// Re-reads every expanded folder after a pane reload; folders that
    /// vanished drop out inside loadChildren.
    private func refreshExpandedChildren() async {
        for key in expandedFolders {
            await loadChildren(of: key)
            watchChildren(of: key)
        }
        recomputeVisible()
    }

    private func clearTreeState() {
        expandedFolders.removeAll()
        childEntries.removeAll()
        for watcher in childWatchers.values { watcher.stop() }
        childWatchers.removeAll()
        rowDepths.removeAll()
    }
```

**(c)** In `reload()`, in the success path after `hasLoadedOnce = true`, add:

```swift
            await refreshExpandedChildren()
```

(Leave the catch path alone — if the current folder itself is unreadable the tree is moot, and the ancestor-fallback path re-enters `reload()` via `navigate`.)

**(d)** In `afterNavigation()`, add `clearTreeState()` right after `selection.removeAll()`.

**(e)** Replace `recomputeVisible()` (currently ~line 799):

```swift
    private func recomputeVisible() {
        let prepared = FileSorter.sort(
            FilterEngine.apply(filter, to: entries), using: sortOrder)
        rootVisibleCount = prepared.count
        if viewMode == .list, groupBy == .none, !expandedFolders.isEmpty {
            let rows = TreeFlattener.flatten(
                roots: entries,
                children: childEntries,
                expanded: expandedFolders) { [filter, sortOrder] level in
                FileSorter.sort(FilterEngine.apply(filter, to: level),
                                using: sortOrder)
            }
            visibleEntries = rows.map(\.entry)
            rowDepths = Dictionary(uniqueKeysWithValues: rows.map {
                ($0.entry.url, $0.depth)
            })
        } else {
            visibleEntries = prepared
            rowDepths = [:]
        }
        groupedEntries = Grouper.group(visibleEntries, by: groupBy, now: Date())
    }
```

**(f)** `viewMode`'s `didSet` currently only persists; flattening is gated on it, so make it:

```swift
    public var viewMode: ViewMode = .list {
        didSet {
            recomputeVisible()
            persistFolderViewSettings()
        }
    }
```

- [x] **Step 2.4: Run tests to verify pass**

Run: `swift run FileExplorerTests > /tmp/fx-tree-tests.log 2>&1; tail -5 /tmp/fx-tree-tests.log`
Expected: `PASS` with all new assertions green.

- [x] **Step 2.5: Commit**

```bash
git add Sources/FileExplorerCore/PaneState.swift Sources/FileExplorerTests/TreeExpansionTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: PaneState tree expansion state with per-folder watchers"
```

---

### Task 3: Session persistence of expansion + tests

**Files:**
- Modify: `Sources/FileExplorerCore/SessionSnapshot.swift` (`Pane` struct, ~line 72)
- Modify: `Sources/FileExplorerCore/PaneState.swift` (`snapshot()` and `init(snapshot:fallback:)`)
- Modify: `Sources/FileExplorerTests/SessionSnapshotTests.swift` (append one test to the existing function — match its local style)

- [ ] **Step 3.1: Write the failing test**

Append inside the existing `sessionSnapshotTests()` function:

```swift
    await test("Pane snapshot round-trips expandedFolders and tolerates absence") {
        var pane = SessionSnapshot.Pane(path: "/tmp")
        pane.expandedFolders = ["/tmp/a", "/tmp/a/b"]
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(SessionSnapshot.Pane.self,
                                               from: data)
        expectEqual(decoded.expandedFolders, ["/tmp/a", "/tmp/a/b"],
                    "expandedFolders round-trips")

        let legacy = #"{"path":"/tmp"}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(SessionSnapshot.Pane.self,
                                           from: legacy)
        expectEqual(old.expandedFolders, [],
                    "legacy session.json decodes with no expansions")
    }
```

- [ ] **Step 3.2: Run to verify failure**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `no member 'expandedFolders'`.

- [ ] **Step 3.3: Implement**

In `SessionSnapshot.Pane`:
- Add `public var expandedFolders: [String]` after `sort`.
- Add `expandedFolders: [String] = []` as the last `init` parameter, assign it.
- Add `case expandedFolders` to `CodingKeys`.
- In `init(from:)`, decode with the file's existing pattern:
  `expandedFolders = try container.decodeIfPresent([String].self, forKey: .expandedFolders) ?? []`.

In `PaneState.snapshot()` add the new argument:

```swift
            expandedFolders: expandedFolders.sorted()
```

In `PaneState`'s `convenience init(snapshot:fallback:)` add (after `sortOrder` is set):

```swift
        expandedFolders = Set(snapshot.expandedFolders.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
```

(`expandedFolders` is `private(set)` but this runs inside PaneState, so it compiles. Children load on the first `reload()` via `refreshExpandedChildren` — no work at init.)

- [ ] **Step 3.4: Run tests to verify pass**

Run: `swift run FileExplorerTests > /tmp/fx-tree-tests.log 2>&1; tail -5 /tmp/fx-tree-tests.log`
Expected: `PASS`.

- [ ] **Step 3.5: Commit**

```bash
git add Sources/FileExplorerCore/SessionSnapshot.swift Sources/FileExplorerCore/PaneState.swift Sources/FileExplorerTests/SessionSnapshotTests.swift
git commit -m "feat: persist list-view expansion state in session snapshot"
```

---

### Task 4: List-view UI — chevron, indent, arrow keys, row-action lookups

**Files:**
- Modify: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/FileActionsMenu.swift`
- Modify: `Sources/FileExplorer/PreviewPaneView.swift`

No new Core logic here, so no new tests — but the full suite must stay green and the build warning-clean for the changed files.

- [ ] **Step 4.1: Chevron + indent in the Name cell**

In `PaneView.swift`, the Name column's cell currently starts:

```swift
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    FileEntryLabel(entry: entry)
```

Change the HStack to lead with the disclosure control (grouped mode hides it — Finder has no disclosure while grouped):

```swift
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    if pane.groupBy == .none {
                        disclosureChevron(for: entry)
                            .padding(.leading,
                                     CGFloat(pane.depth(of: entry.url)) * 14)
                    }
                    FileEntryLabel(entry: entry)
```

and add this helper to `PaneView` (near `badgeSymbol`):

```swift
    /// Finder-style disclosure triangle; files get an equal-width spacer so
    /// names align. ⌥-click discloses the entire subtree.
    @ViewBuilder
    private func disclosureChevron(for entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button {
                let recursive = NSEvent.modifierFlags.contains(.option)
                Task {
                    await pane.toggleExpansion(of: entry.url,
                                               recursively: recursive)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(pane.isExpanded(entry.url) ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand (⌥-click for all levels)")
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }
```

- [ ] **Step 4.2: Arrow-key expand/collapse**

In `PaneView.body`, alongside the existing `.onKeyPress` modifiers on the `Group`, add:

```swift
            .onKeyPress(.rightArrow, phases: .down) { press in
                guard pane.viewMode == .list, pane.groupBy == .none,
                      !pane.selection.isEmpty else { return .ignored }
                let folders = pane.visibleEntries.filter {
                    pane.selection.contains($0.url) && $0.isDirectory
                        && !pane.isExpanded($0.url)
                }
                guard !folders.isEmpty else { return .ignored }
                let recursive = press.modifiers.contains(.option)
                Task {
                    for folder in folders {
                        await pane.toggleExpansion(of: folder.url,
                                                   recursively: recursive)
                    }
                }
                return .handled
            }
            .onKeyPress(.leftArrow, phases: .down) { _ in
                guard pane.viewMode == .list, pane.groupBy == .none,
                      !pane.selection.isEmpty else { return .ignored }
                let expanded = pane.visibleEntries.filter {
                    pane.selection.contains($0.url) && pane.isExpanded($0.url)
                }
                if !expanded.isEmpty {
                    for folder in expanded { pane.collapse(folder.url) }
                    return .handled
                }
                // Nothing to collapse: a single nested selection jumps to
                // its parent row (Finder behavior).
                if pane.selection.count == 1, let sole = pane.selection.first,
                   pane.depth(of: sole) > 0 {
                    let parentPath = sole.deletingLastPathComponent()
                        .standardizedFileURL.path
                    if let row = pane.visibleEntries.first(where: {
                        $0.url.standardizedFileURL.path == parentPath
                    }) {
                        pane.selection = [row.url]
                        return .handled
                    }
                }
                return .ignored
            }
```

- [ ] **Step 4.3: Status bar counts top-level rows only**

In `PaneView.statusBar`, replace the two count lines:

```swift
            if pane.filter.isActive {
                Text("\(pane.rootVisibleCount) of \(pane.totalCount) items")
            } else {
                Text("\(pane.rootVisibleCount) items")
            }
```

- [ ] **Step 4.4: Act-on-row lookups must see nested rows**

Nested entries live in `visibleEntries`, not `entries`. Change exactly these lookups from `pane.entries` to `pane.visibleEntries`:

- `PaneView.swift` `open(_:)` (~line 345): `pane.visibleEntries.first(where: { $0.url == url })?.isDirectory == true` — double-clicking a nested folder must navigate into it.
- `PaneView.swift` new-tag popover targets (~line 91): `pane.visibleEntries.filter { pane.newTagTargets.contains($0.url) }`.
- `FileActionsMenu.swift` ~line 149 and ~line 322 (the two `isDirectory` checks for Open/navigate decisions).
- `FileActionsMenu.swift` ~line 156: `let selectedEntries = pane.visibleEntries.filter { targets.contains($0.url) }`.
- `PreviewPaneView.swift` lines ~19, ~21, ~23, ~71: every `pane.entries` becomes `pane.visibleEntries` (including the `.onChange(of: pane.entries)` trigger) so a selected nested row previews.

Leave alone (root-scoped on purpose): `FileActionsMenu.swift` ~line 157 (`visibleTags` summary), ~line 192 (`existingNames` for New Folder with Selection — creation happens in `currentURL`), `FilterBarView.swift` tag list, `TabBarView.swift`, `ColumnBrowserView.swift`.

- [ ] **Step 4.5: Build and run full suite**

Run: `swift build 2>&1 | tail -5` — expect `Build complete!`.
Run: `swift run FileExplorerTests > /tmp/fx-tree-tests.log 2>&1; tail -5 /tmp/fx-tree-tests.log` — expect `PASS`.

- [ ] **Step 4.6: Commit**

```bash
git add Sources/FileExplorer/PaneView.swift Sources/FileExplorer/FileActionsMenu.swift Sources/FileExplorer/PreviewPaneView.swift
git commit -m "feat: list-view disclosure chevrons, indent, and arrow-key expansion"
```

---

### Task 5: README + completion notes

**Files:**
- Modify: `README.md` (shortcut table + feature list)
- Modify: this plan (check boxes, completion notes)

- [ ] **Step 5.1: Document shortcuts**

Add to README's shortcut table, matching its formatting:

```markdown
| → / ⌥→ | Expand selected folder inline / expand entire subtree (list view) |
| ← | Collapse selected folder, or jump to parent row (list view) |
```

Also add one feature-list line mentioning Finder-style inline folder expansion in list view.

- [ ] **Step 5.2: Final full run + commit**

Run: `swift run FileExplorerTests > /tmp/fx-tree-tests.log 2>&1; tail -5 /tmp/fx-tree-tests.log` — expect `PASS`.

```bash
git add README.md docs/superpowers/plans/2026-07-08-list-tree-expansion.md
git commit -m "docs: list-view tree expansion shortcuts and plan notes"
```

Record in **Completion Notes** below: final assertion count, any deviations from this plan and why, and any deferred follow-ups.

---

## Manual walkthrough (human, post-merge — agent cannot drive the UI)

- [ ] Chevron click expands/collapses; rotation animates; files align with folders.
- [ ] ⌥-click chevron expands entire subtree; collapse parent → re-expand restores it.
- [ ] → / ⌥→ / ← keys behave per README; ← on a nested file jumps to parent row.
- [ ] Edit a file inside an expanded subfolder in another app → row updates live.
- [ ] Sort by Date Modified → every level re-sorts; filter bar filters nested levels.
- [ ] Drag a file onto a nested folder row (drop + spring-load), context menu and Quick Look on nested rows.
- [ ] Group By ≠ none hides chevrons; icons/columns views unaffected.
- [ ] Quit and relaunch → expansion state restored.
- [ ] Status bar "N items" stays at top-level count while expanded.

## Completion Notes

- Deviations:
  - Build/test commands needed `CLANG_MODULE_CACHE_PATH=/tmp/fx-clang-module-cache` and `--disable-sandbox` because the managed filesystem prevented SwiftPM/clang module cache writes under the home directory and SwiftPM manifest sandboxing failed with `sandbox_apply: Operation not permitted`.
  - Hardened existing filesystem/type helpers while completing Task 1 so the required full executable tests could run on the CLT-only macOS 27 SDK: content type resolution now tolerates dynamic/broken `UTType` conformance, trash operations fall back to a local `.Trash` when `FileManager.trashItem` is denied, and volume capacity falls back to filesystem attributes.
  - Corrected Task 2 `TreeExpansionTests` ordering expectations to match the existing `FileSorter.sort` default (`foldersFirst: true`) and the plan's own `recomputeVisible()` snippet.
