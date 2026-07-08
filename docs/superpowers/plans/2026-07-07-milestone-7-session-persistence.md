# FileExplorer Milestone 7 (Session & Settings Persistence) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full session restore across app launches — tabs, dual-pane layout, folder per pane, active indices, per-pane filters, view mode, showHidden, sort order, and recent folders — plus a `settings.json` store (first field: `jpegQuality`) that Milestone 8 will consume.

**Architecture:** A `Codable` value-type mirror (`SessionSnapshot`) of the persistable slice of the `SessionState → TabState → PaneState` object graph. Capture is a `snapshot()` method on each state class; restore is new inits that rebuild the graph with per-pane ancestor fallback (existing `URL.ancestorChain` pattern). `SessionPersister` does atomic JSON I/O in `~/Library/Application Support/FileExplorer/` (directory injectable for tests). `SessionAutosaver` debounces observation-driven saves and saves synchronously on `NSApplication.willTerminateNotification`. Corrupt/missing files → clean defaults, never a crash.

**Tech Stack:** Swift 6 SPM, CLT-only toolchain — **NO `@State`**, no `xcodebuild`, no `swift test`. Tests via the executable harness: `swift run FileExplorerTests` (301 assertions at milestone start; counts below are estimates — recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-7-session-persistence`.

**Design decisions (approved in the v2 spec, `docs/superpowers/specs/2026-07-07-fileexplorer-v2-design.md`):**
- Navigation history and selection are NOT persisted (fresh per launch, like Finder).
- View mode is stored in the snapshot as a raw `String` (avoids Swift 6 isolation questions around the `@MainActor`-nested `PaneState.ViewMode` in `Codable` contexts).
- Sort order serializes via `SortToken` (field name + ascending flag) because `KeyPathComparator` is not `Codable`; unknown fields are dropped; an empty token list restores the default name sort.
- `filterExtensionsText` is persisted alongside `FilterState` (it is the UI source of truth that re-derives `filter.extensions` in its `didSet`).
- All snapshot fields except `path` decode with `decodeIfPresent` + defaults, so M8's additions (custom filter ranges) stay forward-compatible.
- Launch-path CLI argument still wins: session restores, then the active pane navigates to the argument folder.

**File map:**
- Create: `Sources/FileExplorerCore/SessionSnapshot.swift` — snapshot types + `SortToken`/`SortTokenCoder`
- Create: `Sources/FileExplorerCore/SessionPersister.swift` — `AppSettings` + JSON I/O
- Create: `Sources/FileExplorerCore/SessionAutosaver.swift` — debounced observation saves
- Modify: `Sources/FileExplorerCore/FilterPresets.swift` — add `Codable` to the three preset enums
- Modify: `Sources/FileExplorerCore/FilterState.swift` — add `Codable`
- Modify: `Sources/FileExplorerCore/PaneState.swift` — `ViewMode: Codable`, `snapshot()`, restore init
- Modify: `Sources/FileExplorerCore/TabState.swift` — `snapshot()`, restore init
- Modify: `Sources/FileExplorerCore/SessionState.swift` — `snapshot()`, restore init
- Modify: `Sources/FileExplorer/FileExplorerApp.swift` — load/restore + autosaver wiring
- Create: `Sources/FileExplorerTests/SessionSnapshotTests.swift`, `SessionPersisterTests.swift`, `SessionAutosaverTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift` — register the three new suites

---

### Task 1: Codable conformances + SortToken serialization (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/FilterPresets.swift`
- Modify: `Sources/FileExplorerCore/FilterState.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift:24-27` (ViewMode declaration)
- Create: `Sources/FileExplorerCore/SessionSnapshot.swift` (SortToken part only in this task)
- Create: `Sources/FileExplorerTests/SessionSnapshotTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Create the branch**

```bash
cd /Users/mlaplante/Sites/fileexplorer
git checkout main && git pull --ff-only 2>/dev/null; git checkout -b milestone-7-session-persistence
```

- [x] **Step 2: Write the failing tests — `Sources/FileExplorerTests/SessionSnapshotTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func sessionSnapshotTests() async {
    await test("FilterState round-trips through JSON") {
        var filter = FilterState()
        filter.preset = .images
        filter.extensions = ["png", "jpg"]
        filter.datePreset = .last7Days
        filter.sizePreset = .over100MB
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        expectEqual(decoded, filter, "filter state survives encode/decode")
    }

    await test("SortTokenCoder maps comparators to tokens and back") {
        var sizeDescending = KeyPathComparator(\FileEntry.size)
        sizeDescending.order = .reverse
        let comparators = [
            KeyPathComparator(\FileEntry.name, comparator: .localizedStandard),
            sizeDescending,
        ]
        let tokens = SortTokenCoder.tokens(from: comparators)
        expectEqual(tokens, [SortToken(field: .name, ascending: true),
                             SortToken(field: .size, ascending: false)],
                    "known key paths map to tokens with direction")

        let restored = SortTokenCoder.comparators(from: tokens)
        expectEqual(restored.count, 2, "both comparators restored")
        expect(restored[0].keyPath == \FileEntry.name, "name key path restored")
        expectEqual(restored[0].order, .forward, "ascending restored")
        expect(restored[1].keyPath == \FileEntry.size, "size key path restored")
        expectEqual(restored[1].order, .reverse, "descending restored")
    }

    await test("SortTokenCoder drops unknown key paths and defaults when empty") {
        let tokens = SortTokenCoder.tokens(
            from: [KeyPathComparator(\FileEntry.isHidden)])
        expect(tokens.isEmpty, "unmapped key path dropped")

        let restored = SortTokenCoder.comparators(from: [])
        expectEqual(restored.count, 1, "empty tokens restore a default sort")
        expect(restored[0].keyPath == \FileEntry.name, "default sort is by name")
    }
}
```

- [x] **Step 3: Register the suite — `Sources/FileExplorerTests/main.swift`**

Add after `await paneBatchToolsTests()`:

```swift
await sessionSnapshotTests()
```

- [x] **Step 4: Run to verify failure**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: compile error — `SortToken`/`SortTokenCoder` undefined, `FilterState` not `Codable`.

- [x] **Step 5: Implement the conformances**

In `Sources/FileExplorerCore/FilterPresets.swift`, add `Codable` to all three enums (raw-value synthesis — no other change):

```swift
public enum TypePreset: String, CaseIterable, Sendable, Codable {
public enum DatePreset: String, CaseIterable, Sendable, Codable {
public enum SizePreset: String, CaseIterable, Sendable, Codable {
```

In `Sources/FileExplorerCore/FilterState.swift`:

```swift
public struct FilterState: Equatable, Sendable, Codable {
```

In `Sources/FileExplorerCore/PaneState.swift` (the nested enum only):

```swift
    public enum ViewMode: String, Sendable, Codable {
```

Create `Sources/FileExplorerCore/SessionSnapshot.swift`:

```swift
import Foundation

/// Serializable stand-in for one `[KeyPathComparator<FileEntry>]` element —
/// `KeyPathComparator` itself is not `Codable`.
public struct SortToken: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable {
        case name, size, kind, modified
    }
    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }
}

public enum SortTokenCoder {
    private static let fields: [(SortToken.Field, PartialKeyPath<FileEntry>)] = [
        (.name, \FileEntry.name),
        (.size, \FileEntry.size),
        (.kind, \FileEntry.kind),
        (.modified, \FileEntry.modified),
    ]

    /// Unknown key paths are dropped (a future column simply won't persist
    /// its sort until added here).
    public static func tokens(
        from comparators: [KeyPathComparator<FileEntry>]
    ) -> [SortToken] {
        comparators.compactMap { comparator in
            guard let match = fields.first(where: { $0.1 == comparator.keyPath })
            else { return nil }
            return SortToken(field: match.0,
                             ascending: comparator.order == .forward)
        }
    }

    /// Empty input restores the app-default name sort (matches
    /// `PaneState.sortOrder`'s initial value, localizedStandard comparator).
    public static func comparators(
        from tokens: [SortToken]
    ) -> [KeyPathComparator<FileEntry>] {
        let restored = tokens.map { token -> KeyPathComparator<FileEntry> in
            var comparator: KeyPathComparator<FileEntry>
            switch token.field {
            case .name:
                comparator = KeyPathComparator(\FileEntry.name,
                                               comparator: .localizedStandard)
            case .size:
                comparator = KeyPathComparator(\FileEntry.size)
            case .kind:
                comparator = KeyPathComparator(\FileEntry.kind)
            case .modified:
                comparator = KeyPathComparator(\FileEntry.modified)
            }
            comparator.order = token.ascending ? .forward : .reverse
            return comparator
        }
        return restored.isEmpty
            ? [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
            : restored
    }
}
```

- [x] **Step 6: Run to verify pass**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: `PASS` (assertion count grows by ~10).

- [x] **Step 7: Commit**

```bash
git add Sources/FileExplorerCore/SessionSnapshot.swift \
    Sources/FileExplorerCore/FilterPresets.swift \
    Sources/FileExplorerCore/FilterState.swift \
    Sources/FileExplorerCore/PaneState.swift \
    Sources/FileExplorerTests/SessionSnapshotTests.swift \
    Sources/FileExplorerTests/main.swift
git commit -m "feat: Codable filter state and sort-token serialization"
```

---

### Task 2: SessionSnapshot types + capture (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/SessionSnapshot.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Modify: `Sources/FileExplorerCore/TabState.swift`
- Modify: `Sources/FileExplorerCore/SessionState.swift`
- Modify: `Sources/FileExplorerTests/SessionSnapshotTests.swift`

- [x] **Step 1: Write the failing tests — append inside `sessionSnapshotTests()`**

```swift
    await test("snapshot() captures the session graph") {
        let home = URL(fileURLWithPath: "/tmp")
        let session = SessionState(url: home)
        session.activeTab.toggleDual()          // tab 0: dual, right pane active
        session.newTab()                        // tab 1 active
        session.activePane.showHidden = true
        session.activePane.viewMode = .icons
        session.activePane.filter.preset = .images
        session.activePane.filterExtensionsText = "png, jpg"

        let snapshot = session.snapshot()
        expectEqual(snapshot.tabs.count, 2, "two tabs captured")
        expectEqual(snapshot.activeTabIndex, 1, "active tab captured")
        expectEqual(snapshot.tabs[0].panes.count, 2, "dual pane captured")
        expectEqual(snapshot.tabs[0].activePaneIndex, 1, "active pane captured")

        let pane = snapshot.tabs[1].panes[0]
        expectEqual(pane.path, "/tmp", "pane folder captured as path")
        expect(pane.showHidden, "showHidden captured")
        expectEqual(pane.viewMode, "icons", "view mode captured as raw string")
        expectEqual(pane.filter.preset, .images, "filter preset captured")
        expectEqual(pane.filterExtensionsText, "png, jpg",
                    "extension draft text captured")
        expectEqual(pane.sort, [SortToken(field: .name, ascending: true)],
                    "default sort captured as token")
    }

    await test("SessionSnapshot round-trips through JSON") {
        let home = URL(fileURLWithPath: "/tmp")
        let session = SessionState(url: home)
        session.newTab()
        await session.activePane.navigate(to: URL(fileURLWithPath: "/private/tmp"))
        let snapshot = session.snapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        expectEqual(decoded, snapshot, "snapshot survives encode/decode")
        expect(!decoded.recentFolders.isEmpty, "recents captured via navigation")
    }

    await test("SessionSnapshot decodes minimal JSON with defaults") {
        let json = #"{"tabs":[{"panes":[{"path":"/tmp"}]}]}"#
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self, from: Data(json.utf8))
        expectEqual(decoded.activeTabIndex, 0, "missing activeTabIndex defaults")
        expectEqual(decoded.tabs[0].activePaneIndex, 0,
                    "missing activePaneIndex defaults")
        let pane = decoded.tabs[0].panes[0]
        expectEqual(pane.path, "/tmp", "path decoded")
        expect(!pane.showHidden, "missing showHidden defaults to false")
        expectEqual(pane.viewMode, "list", "missing viewMode defaults to list")
        expectEqual(pane.filter, FilterState(), "missing filter defaults to empty")
        expect(pane.sort.isEmpty, "missing sort defaults to empty tokens")
        expect(decoded.recentFolders.isEmpty, "missing recents default to empty")
    }
```

- [x] **Step 2: Run to verify failure**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: compile error — `SessionSnapshot` / `snapshot()` undefined.

- [x] **Step 3: Add the snapshot types — append to `Sources/FileExplorerCore/SessionSnapshot.swift`**

```swift
/// Codable mirror of the persistable slice of the session object graph.
/// Everything except `path` decodes with defaults so snapshots written by
/// older builds keep loading as fields are added (forward compatibility).
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public var path: String
        public var showHidden: Bool
        public var viewMode: String
        public var filter: FilterState
        public var filterExtensionsText: String
        public var sort: [SortToken]

        public init(path: String, showHidden: Bool = false,
                    viewMode: String = "list", filter: FilterState = FilterState(),
                    filterExtensionsText: String = "", sort: [SortToken] = []) {
            self.path = path
            self.showHidden = showHidden
            self.viewMode = viewMode
            self.filter = filter
            self.filterExtensionsText = filterExtensionsText
            self.sort = sort
        }

        enum CodingKeys: String, CodingKey {
            case path, showHidden, viewMode, filter, filterExtensionsText, sort
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            showHidden = try container.decodeIfPresent(
                Bool.self, forKey: .showHidden) ?? false
            viewMode = try container.decodeIfPresent(
                String.self, forKey: .viewMode) ?? "list"
            filter = try container.decodeIfPresent(
                FilterState.self, forKey: .filter) ?? FilterState()
            filterExtensionsText = try container.decodeIfPresent(
                String.self, forKey: .filterExtensionsText) ?? ""
            sort = try container.decodeIfPresent(
                [SortToken].self, forKey: .sort) ?? []
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var panes: [Pane]
        public var activePaneIndex: Int

        public init(panes: [Pane], activePaneIndex: Int = 0) {
            self.panes = panes
            self.activePaneIndex = activePaneIndex
        }

        enum CodingKeys: String, CodingKey { case panes, activePaneIndex }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            panes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? []
            activePaneIndex = try container.decodeIfPresent(
                Int.self, forKey: .activePaneIndex) ?? 0
        }
    }

    public var tabs: [Tab]
    public var activeTabIndex: Int
    public var recentFolders: [String]

    public init(tabs: [Tab], activeTabIndex: Int = 0,
                recentFolders: [String] = []) {
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.recentFolders = recentFolders
    }

    enum CodingKeys: String, CodingKey { case tabs, activeTabIndex, recentFolders }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        activeTabIndex = try container.decodeIfPresent(
            Int.self, forKey: .activeTabIndex) ?? 0
        recentFolders = try container.decodeIfPresent(
            [String].self, forKey: .recentFolders) ?? []
    }
}
```

- [x] **Step 4: Add capture methods**

`Sources/FileExplorerCore/PaneState.swift` — add near `clearFilters()`:

```swift
    public func snapshot() -> SessionSnapshot.Pane {
        SessionSnapshot.Pane(
            path: currentURL.path,
            showHidden: showHidden,
            viewMode: viewMode.rawValue,
            filter: filter,
            filterExtensionsText: filterExtensionsText,
            sort: SortTokenCoder.tokens(from: sortOrder))
    }
```

`Sources/FileExplorerCore/TabState.swift` — add after `title`:

```swift
    public func snapshot() -> SessionSnapshot.Tab {
        SessionSnapshot.Tab(panes: panes.map { $0.snapshot() },
                            activePaneIndex: activePaneIndex)
    }
```

`Sources/FileExplorerCore/SessionState.swift` — add after `activePane`:

```swift
    public func snapshot() -> SessionSnapshot {
        SessionSnapshot(tabs: tabs.map { $0.snapshot() },
                        activeTabIndex: activeTabIndex,
                        recentFolders: recentFolders.map(\.path))
    }
```

- [x] **Step 5: Run to verify pass**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: `PASS`.

- [x] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore Sources/FileExplorerTests
git commit -m "feat: SessionSnapshot capture of tabs, panes, filters, and sort"
```

---

### Task 3: Session restore with ancestor fallback (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/SessionSnapshot.swift` (URL resolution helper)
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Modify: `Sources/FileExplorerCore/TabState.swift`
- Modify: `Sources/FileExplorerCore/SessionState.swift`
- Modify: `Sources/FileExplorerTests/SessionSnapshotTests.swift`

- [x] **Step 1: Write the failing tests — append inside `sessionSnapshotTests()`**

```swift
    await test("restore rebuilds the session graph") {
        let home = URL(fileURLWithPath: "/tmp")
        let original = SessionState(url: home)
        original.activeTab.toggleDual()
        original.newTab()
        original.activePane.showHidden = true
        original.activePane.viewMode = .icons
        original.activePane.filter.sizePreset = .under1MB
        original.activePane.filterExtensionsText = "png"
        original.activePane.sortOrder = {
            var c = KeyPathComparator(\FileEntry.modified)
            c.order = .reverse
            return [c]
        }()

        let restored = SessionState(snapshot: original.snapshot(), fallback: home)
        expectEqual(restored.tabs.count, 2, "tabs restored")
        expectEqual(restored.activeTabIndex, 1, "active tab restored")
        expect(restored.tabs[0].isDual, "dual pane restored")
        expectEqual(restored.tabs[0].activePaneIndex, 1, "active pane restored")

        let pane = restored.activePane
        expectEqual(pane.currentURL.path, "/tmp", "pane folder restored")
        expect(pane.showHidden, "showHidden restored")
        expectEqual(pane.viewMode, .icons, "view mode restored")
        expectEqual(pane.filter.sizePreset, .under1MB, "filter restored")
        expectEqual(pane.filter.extensions, ["png"],
                    "extensions re-derived from restored draft text")
        expect(pane.sortOrder[0].keyPath == \FileEntry.modified,
               "sort field restored")
        expectEqual(pane.sortOrder[0].order, .reverse, "sort direction restored")
    }

    await test("restore falls back to nearest existing ancestor") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("m7-restore-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("kept")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let home = URL(fileURLWithPath: "/tmp")
        let vanished = sub.appendingPathComponent("gone/deeper").path
        let snapshot = SessionSnapshot(tabs: [SessionSnapshot.Tab(
            panes: [SessionSnapshot.Pane(path: vanished)])])
        let restored = SessionState(snapshot: snapshot, fallback: home)
        expectEqual(restored.activePane.currentURL.path,
                    sub.standardizedFileURL.path,
                    "vanished folder falls back to nearest existing ancestor")

        let noAncestors = SessionSnapshot(tabs: [SessionSnapshot.Tab(
            panes: [SessionSnapshot.Pane(path: "")])])
        let fallbackOnly = SessionState(snapshot: noAncestors, fallback: home)
        expectEqual(fallbackOnly.activePane.currentURL.path, "/tmp",
                    "unresolvable path falls back to the fallback URL")
    }

    await test("restore clamps indices and survives empty snapshots") {
        let home = URL(fileURLWithPath: "/tmp")
        var snapshot = SessionSnapshot(tabs: [
            SessionSnapshot.Tab(panes: [SessionSnapshot.Pane(path: "/tmp")],
                                activePaneIndex: 7)],
            activeTabIndex: 9)
        let restored = SessionState(snapshot: snapshot, fallback: home)
        expectEqual(restored.activeTabIndex, 0, "out-of-range tab index clamped")
        expectEqual(restored.tabs[0].activePaneIndex, 0,
                    "out-of-range pane index clamped")

        snapshot = SessionSnapshot(tabs: [])
        let empty = SessionState(snapshot: snapshot, fallback: home)
        expectEqual(empty.tabs.count, 1, "empty snapshot yields one default tab")
        expectEqual(empty.activePane.currentURL.path, "/tmp",
                    "default tab opens at fallback")

        let recents = SessionSnapshot(
            tabs: [SessionSnapshot.Tab(panes: [SessionSnapshot.Pane(path: "/tmp")])],
            recentFolders: ["/tmp", "/private"])
        let withRecents = SessionState(snapshot: recents, fallback: home)
        expectEqual(withRecents.recentFolders.map(\.path), ["/tmp", "/private"],
                    "recent folders restored in order")
    }
```

- [x] **Step 2: Run to verify failure**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: compile error — restore inits undefined.

- [x] **Step 3: Implement restore**

`Sources/FileExplorerCore/SessionSnapshot.swift` — add inside `SessionSnapshot.Pane` (after `init(from:)`):

```swift
        /// The saved folder if it still exists as a directory, else its
        /// nearest existing directory ancestor, else `fallback`. Relative or
        /// empty paths go straight to `fallback` — `URL(fileURLWithPath:)`
        /// would resolve them against the process working directory, whose
        /// ancestor chain always "exists" and would mask the bad data.
        public func resolvedURL(fallback: URL) -> URL {
            guard path.hasPrefix("/") else { return fallback.standardizedFileURL }
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url.standardizedFileURL
            }
            // ancestorChain is root-first ending with url itself; nearest first.
            let ancestors = url.ancestorChain.dropLast().reversed()
            if let existing = ancestors.first(where: {
                fm.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }) {
                return existing
            }
            return fallback.standardizedFileURL
        }
```

`Sources/FileExplorerCore/PaneState.swift` — add after `init(url:)`:

```swift
    /// Restore from a saved snapshot. Setting `filter` before
    /// `filterExtensionsText` matters: the text's `didSet` re-derives
    /// `filter.extensions`, making the draft field the source of truth.
    public convenience init(snapshot: SessionSnapshot.Pane, fallback: URL) {
        self.init(url: snapshot.resolvedURL(fallback: fallback))
        showHidden = snapshot.showHidden
        viewMode = ViewMode(rawValue: snapshot.viewMode) ?? .list
        filter = snapshot.filter
        filterExtensionsText = snapshot.filterExtensionsText
        sortOrder = SortTokenCoder.comparators(from: snapshot.sort)
    }
```

`Sources/FileExplorerCore/TabState.swift` — add a designated init after the existing one (it must be designated: `panes` has a private setter):

```swift
    /// Restore from a saved snapshot; empty/oversized pane lists and
    /// out-of-range indices are clamped rather than trusted.
    public init(snapshot: SessionSnapshot.Tab, fallback: URL,
                onNavigated: (@MainActor (URL) -> Void)? = nil) {
        self.onNavigated = onNavigated
        let paneSnapshots = snapshot.panes.isEmpty
            ? [SessionSnapshot.Pane(path: fallback.path)]
            : Array(snapshot.panes.prefix(2))
        panes = paneSnapshots.map { paneSnapshot in
            let pane = PaneState(snapshot: paneSnapshot, fallback: fallback)
            pane.onNavigated = onNavigated
            return pane
        }
        activePaneIndex = max(0, min(snapshot.activePaneIndex, panes.count - 1))
    }
```

`Sources/FileExplorerCore/SessionState.swift` — add after `init(url:)` (same file as the private `tabs`/`recentFolders` setters and `recordRecent`, which this relies on):

```swift
    /// Restore from a saved snapshot; an empty snapshot degrades to the
    /// default single tab at `fallback`.
    public convenience init(snapshot: SessionSnapshot, fallback: URL) {
        self.init(url: fallback)
        if !snapshot.tabs.isEmpty {
            tabs = snapshot.tabs.map { tabSnapshot in
                TabState(snapshot: tabSnapshot, fallback: fallback) {
                    [weak self] visited in
                    self?.recordRecent(visited)
                }
            }
            activeTabIndex = max(0, min(snapshot.activeTabIndex, tabs.count - 1))
        }
        recentFolders = snapshot.recentFolders.map { URL(fileURLWithPath: $0) }
    }
```

- [x] **Step 4: Run to verify pass**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: `PASS`.

- [x] **Step 5: Commit**

```bash
git add Sources/FileExplorerCore Sources/FileExplorerTests
git commit -m "feat: session restore from snapshot with ancestor fallback"
```

---

### Task 4: AppSettings + SessionPersister (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/SessionPersister.swift`
- Create: `Sources/FileExplorerTests/SessionPersisterTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Write the failing tests — `Sources/FileExplorerTests/SessionPersisterTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func sessionPersisterTests() async {
    func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-persister-\(UUID().uuidString)")
    }

    await test("SessionPersister round-trips a session snapshot") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)

        expect(persister.loadSession() == nil, "no file yet → nil")

        let snapshot = SessionSnapshot(
            tabs: [SessionSnapshot.Tab(
                panes: [SessionSnapshot.Pane(path: "/tmp", showHidden: true)])],
            activeTabIndex: 0, recentFolders: ["/tmp"])
        persister.saveSession(snapshot)   // also creates the directory
        expectEqual(persister.loadSession(), snapshot,
                    "session survives save/load")
    }

    await test("SessionPersister tolerates corrupt session files") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try Data("not json{{{".utf8).write(
            to: dir.appendingPathComponent("session.json"))
        let persister = SessionPersister(directory: dir)
        expect(persister.loadSession() == nil, "corrupt session → nil, no crash")
    }

    await test("AppSettings round-trips and defaults") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)

        expectEqual(persister.loadSettings(), AppSettings(),
                    "missing settings → defaults")
        expectEqual(AppSettings().jpegQuality, 0.85, "default JPEG quality")

        persister.saveSettings(AppSettings(jpegQuality: 0.6))
        expectEqual(persister.loadSettings().jpegQuality, 0.6,
                    "settings survive save/load")

        try Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json"))
        expectEqual(persister.loadSettings(), AppSettings(),
                    "empty JSON object decodes to defaults (forward compat)")

        try Data("garbage".utf8).write(to: dir.appendingPathComponent("settings.json"))
        expectEqual(persister.loadSettings(), AppSettings(),
                    "corrupt settings → defaults, no crash")
    }
}
```

- [x] **Step 2: Register the suite — `Sources/FileExplorerTests/main.swift`**

Add after `await sessionSnapshotTests()`:

```swift
await sessionPersisterTests()
```

- [x] **Step 3: Run to verify failure**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: compile error — `SessionPersister`/`AppSettings` undefined.

- [x] **Step 4: Implement — `Sources/FileExplorerCore/SessionPersister.swift`**

```swift
import Foundation

/// App-wide preferences persisted as `settings.json`. Every field decodes
/// with a default so files written by any version keep loading.
public struct AppSettings: Codable, Equatable, Sendable {
    public var jpegQuality: Double

    public init(jpegQuality: Double = 0.85) {
        self.jpegQuality = jpegQuality
    }

    enum CodingKeys: String, CodingKey { case jpegQuality }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jpegQuality = try container.decodeIfPresent(
            Double.self, forKey: .jpegQuality) ?? 0.85
    }
}

/// Atomic JSON persistence for the session and settings. Load failures of
/// any kind (missing, corrupt, wrong shape) degrade to nil/defaults — the
/// app must never fail to launch over a bad state file. Save failures are
/// logged and swallowed.
public struct SessionPersister: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("FileExplorer", isDirectory: true)
    }

    private var sessionFile: URL { directory.appendingPathComponent("session.json") }
    private var settingsFile: URL { directory.appendingPathComponent("settings.json") }

    public func loadSession() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func saveSession(_ snapshot: SessionSnapshot) {
        write(snapshot, to: sessionFile)
    }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFile),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func saveSettings(_ settings: AppSettings) {
        write(settings, to: settingsFile)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: file, options: .atomic)
        } catch {
            NSLog("FileExplorer: failed to save %@: %@",
                  file.lastPathComponent, String(describing: error))
        }
    }
}
```

- [x] **Step 5: Run to verify pass**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: `PASS`.

- [x] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore/SessionPersister.swift \
    Sources/FileExplorerTests/SessionPersisterTests.swift \
    Sources/FileExplorerTests/main.swift
git commit -m "feat: SessionPersister atomic JSON store and AppSettings"
```

---

### Task 5: SessionAutosaver — debounced observation saves (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/SessionAutosaver.swift`
- Create: `Sources/FileExplorerTests/SessionAutosaverTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Write the failing tests — `Sources/FileExplorerTests/SessionAutosaverTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func sessionAutosaverTests() async {
    func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-autosave-\(UUID().uuidString)")
    }

    /// Polls until the saved session satisfies `condition` (or ~2 s passes).
    func waitForSession(
        _ persister: SessionPersister,
        _ condition: @escaping (SessionSnapshot) -> Bool
    ) async -> SessionSnapshot? {
        for _ in 0..<200 {
            if let saved = persister.loadSession(), condition(saved) {
                return saved
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    await test("saveNow writes the current session immediately") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let session = SessionState(url: URL(fileURLWithPath: "/tmp"))
        let autosaver = SessionAutosaver(session: session, persister: persister,
                                         debounceMilliseconds: 10)
        session.newTab()
        autosaver.saveNow()
        expectEqual(persister.loadSession()?.tabs.count, 2,
                    "saveNow persists without waiting for the debounce")
    }

    await test("mutations trigger a debounced save, repeatedly") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let session = SessionState(url: URL(fileURLWithPath: "/tmp"))
        let autosaver = SessionAutosaver(session: session, persister: persister,
                                         debounceMilliseconds: 10)
        autosaver.start()

        session.newTab()
        let first = await waitForSession(persister) { $0.tabs.count == 2 }
        expect(first != nil, "first mutation autosaved")

        // Re-registration after a save: a second mutation must also save.
        session.selectTab(0)
        let second = await waitForSession(persister) { $0.activeTabIndex == 0 }
        expect(second != nil, "observation re-registers after each save")

        // Deep pane mutation reaches the observed snapshot too.
        session.activePane.showHidden = true
        let third = await waitForSession(persister) {
            $0.tabs[0].panes[0].showHidden
        }
        expect(third != nil, "pane-level mutation autosaved")
        _ = autosaver   // keep alive through the waits
    }
}
```

- [x] **Step 2: Register the suite — `Sources/FileExplorerTests/main.swift`**

Add after `await sessionPersisterTests()`:

```swift
await sessionAutosaverTests()
```

- [x] **Step 3: Run to verify failure**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: compile error — `SessionAutosaver` undefined.

- [x] **Step 4: Implement — `Sources/FileExplorerCore/SessionAutosaver.swift`**

```swift
import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Watches the session graph via Observation and writes `session.json`
/// after a short debounce; also saves synchronously at app termination.
///
/// `withObservationTracking`'s onChange fires once, so each change
/// re-registers. `saveNow()` snapshots at write time, so changes landing
/// between a fire and the re-registration are still captured by that write.
@MainActor
public final class SessionAutosaver {
    private let session: SessionState
    private let persister: SessionPersister
    private let debounceMilliseconds: Int
    private var pendingSave: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    public init(session: SessionState, persister: SessionPersister,
                debounceMilliseconds: Int = 500) {
        self.session = session
        self.persister = persister
        self.debounceMilliseconds = debounceMilliseconds
    }

    public func start() {
        observe()
        #if canImport(AppKit)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; hop is safe.
            MainActor.assumeIsolated { self?.saveNow() }
        }
        #endif
    }

    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        persister.saveSession(session.snapshot())
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let delay = debounceMilliseconds
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func observe() {
        withObservationTracking {
            _ = session.snapshot()   // touches every persisted property
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleSave()
                self.observe()
            }
        }
    }

    isolated deinit {
        pendingSave?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }
}
```

- [x] **Step 5: Run to verify pass**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: `PASS`. If the debounce tests flake under load, widen the poll loop (not the debounce) and re-run; a genuine failure reproduces consistently.

- [x] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore/SessionAutosaver.swift \
    Sources/FileExplorerTests/SessionAutosaverTests.swift \
    Sources/FileExplorerTests/main.swift
git commit -m "feat: debounced session autosave with termination flush"
```

---

### Task 6: App wiring + verification sweep

**Files:**
- Modify: `Sources/FileExplorer/FileExplorerApp.swift:5-31`
- Modify: `docs/superpowers/plans/2026-07-07-milestone-7-session-persistence.md` (completion notes)

- [x] **Step 1: Wire restore + autosave into the app**

In `Sources/FileExplorer/FileExplorerApp.swift`, replace the `session` stored-property closure (lines 6–19) and `init()` (lines 24–31) with:

```swift
    private let session: SessionState
    private let autosaver: SessionAutosaver
```

and (keeping the existing `palette`/`renameModel`/`batchRenameModel` properties as they are):

```swift
    init() {
        let persister = SessionPersister(
            directory: SessionPersister.defaultDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let session: SessionState
        if let snapshot = persister.loadSession() {
            session = SessionState(snapshot: snapshot, fallback: home)
        } else {
            session = SessionState(url: home)
        }
        // Launch-path argument still wins: restore the session, then point
        // the active pane at the requested folder (terminal `fe .` helper).
        if let launchURL = Self.launchFolderURL() {
            Task { await session.activePane.navigate(to: launchURL) }
        }
        self.session = session
        let autosaver = SessionAutosaver(session: session, persister: persister)
        autosaver.start()
        self.autosaver = autosaver

        // When launched from `swift run` (no bundle), become a regular
        // foreground app so the window appears and takes focus.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private static func launchFolderURL() -> URL? {
        guard let path = CommandLine.arguments.dropFirst().first else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded)
    }
```

- [x] **Step 2: Build and full-suite check**

Run: `swift build 2>&1 | tail -3 && swift run FileExplorerTests 2>&1 | tail -3`
Expected: clean build, `PASS` (recount assertions honestly; expect roughly 340+).

- [x] **Step 3: Launch checks**

```bash
swift run FileExplorer & APP_PID=$!; sleep 6; kill -0 $APP_PID && echo ALIVE; kill $APP_PID
ls -la ~/Library/Application\ Support/FileExplorer/ && cat ~/Library/Application\ Support/FileExplorer/session.json
```

Expected: `ALIVE`; after the first navigation/mutation-driven autosave a `session.json` exists and contains a `tabs` array. (A pristine launch with zero mutations may not have written yet — if the file is missing, launch again, it restores defaults, and that's still correct behavior.)

Also verify the launch-path argument still works:

```bash
swift run FileExplorer /tmp & APP_PID=$!; sleep 6; kill $APP_PID
```

Expected: app stays alive; no crash with a restored session + path argument combined.

- [x] **Step 4: MANUAL walkthrough items (record, don't block)**

TCC blocks agent-driven UI automation on this machine; list these in the completion notes as MANUAL:
- Make tabs/dual-pane/filters, ⌘Q, relaunch → layout and folders restored.
- Delete a restored pane's folder while the app is closed, relaunch → pane opens at nearest ancestor.
- Corrupt `session.json` by hand, relaunch → default session, no crash.

- [x] **Step 5: Verification sweep — fix real bugs found, then close out**

Re-read the spec's M7 section; confirm each requirement has a passing test or a MANUAL entry. Fix any real bugs (commit as `fix: … (milestone 7 verification)`); append Completion Notes to this plan (date, final assertion count, bugs found, deferred items), mark checkboxes, then merge:

```bash
git add -A && git commit -m "docs: milestone 7 completion notes"
git checkout main && git merge --no-ff milestone-7-session-persistence \
    -m "merge: milestone 7 — session & settings persistence"
```

---

## Completion Notes (2026-07-07)

**Final assertion count:** PASS (368 assertions). Task 6 added no new tests; the count carries over unchanged from Task 5.

**Per-task summary:**
- **Task 1** — `TypePreset`/`DatePreset`/`SizePreset`/`FilterState`/`PaneState.ViewMode` made `Codable`; `SortToken`/`SortTokenCoder` added to translate `[KeyPathComparator<FileEntry>]` to a JSON-safe token list and back.
- **Task 2** — `SessionSnapshot` (`Pane`/`Tab`/root) added as the `Codable` mirror of the object graph; `snapshot()` capture methods added to `PaneState`, `TabState`, `SessionState`. All fields except `path` decode with defaults for forward compatibility.
- **Task 3** — Restore path: `SessionSnapshot.Pane.resolvedURL(fallback:)` walks the ancestor chain when a saved folder is gone; restore inits on `PaneState`/`TabState`/`SessionState` clamp out-of-range indices and degrade empty snapshots to one default tab.
- **Task 4** — `SessionPersister` (atomic JSON I/O, `session.json`/`settings.json` in `~/Library/Application Support/FileExplorer/`) and `AppSettings` (`jpegQuality`, default 0.85) added; load failures of any kind degrade to nil/defaults, save failures are logged and swallowed.
- **Task 5** — `SessionAutosaver` added: debounced (`500ms` default) observation-driven saves via `withObservationTracking`/`onChange` re-registration loop, plus a synchronous flush on `NSApplication.willTerminateNotification`.
- **Task 6** — Wired `SessionPersister`/`SessionAutosaver` into `FileExplorerApp.init()`: loads a saved session (falling back to home) then applies the launch-path CLI argument on top via `Task { await session.activePane.navigate(...) }`, so restore and the terminal `fe <path>` helper compose correctly. Added the `SessionAutosaver.observe()` doc invariant note (see below).

**Bugs found during implementation:**
- **Task 1 — Bool-not-Comparable substitution:** `KeyPathComparator(\FileEntry.isHidden)` doesn't compile because `Bool` isn't `Comparable`. The "unmapped key path dropped" test needed a real-but-unmapped comparator to exercise `SortTokenCoder.tokens`'s drop path, so a local `BoolComparator` stand-in (`KeyPathComparator(\FileEntry.isHidden, comparator: BoolComparator())`) was introduced in the test file — doc comment explains why, in `SessionSnapshotTests.swift`.
- **Task 5 — `/private/tmp` URL-standardization test trap:** the autosaver's navigation-mutation test originally used `/private/tmp` as a "distinct" target directory, but `URL.standardizedFileURL` collapses `/private/tmp` to `/tmp` (its own symlink alias) on macOS, making the persisted-path assertion vacuous regardless of correctness. Fixed by navigating to a freshly created temp subdirectory instead, with a comment recording the trap for future test authors.

**Accepted-minor items (not fixed, tracked as known/self-healing):**
- Recents restore (`SessionState(snapshot:fallback:)`) bypasses `recordRecent`'s dedup/cap logic — it assigns `recentFolders` directly from the snapshot array. Self-healing: the next real navigation goes through `recordRecent` and re-applies dedup/cap normally.
- `AppSettings.jpegQuality` is persisted but unclamped (no `0...1` enforcement) — deferred until Milestone 8 actually consumes the value in the export/convert path.
- `SessionAutosaver` writes synchronously on the main actor; acceptable at current `session.json` size (sub-1KB for a realistic multi-tab session) but would need to move off-main if the snapshot grows substantially (e.g., very large recent-folder history).

**Doc addition:** `Sources/FileExplorerCore/SessionAutosaver.swift` — added an invariant note above `observe()` recording that the no-lost-mutation guarantee depends on every persisted sub-state being value-typed and reassigned (not mutated in place) on change; a future refactor to a reference type would silently break `onChange` firing for that field.

**End-to-end verification performed:**
- `swift build` — clean (only pre-existing CLT linker search-path warnings).
- `swift run FileExplorerTests` — `PASS (368 assertions)`.
- `swift run FileExplorer` (no args) — process stayed alive (`ALIVE`) for 6s; `~/Library/Application Support/FileExplorer/` did not exist beforehand and no `session.json` was written by this mutation-free launch (correct: autosave fires on Observation `onChange`, not unconditionally on launch).
- `swift run FileExplorer /tmp` — process stayed alive (`ALIVE2`/`ALIVE3` across two runs); the launch-path navigation is itself a persisted mutation, so a second run was used to positively confirm the full write path: after the 500ms debounce, `~/Library/Application Support/FileExplorer/session.json` was created (directory did not previously exist — `saveSession`'s `createDirectory` call is confirmed working) containing a `"tabs"` array with `"path" : "\/tmp"`, matching the CLI argument. No pre-existing `session.json` was found or touched at any point during this task.

**MANUAL walkthrough (not automatable — TCC blocks agent-driven UI automation on this machine):**
- [ ] Make tabs/dual-pane/filters, ⌘Q, relaunch → layout and folders restored.
- [ ] Delete a restored pane's folder while the app is closed, relaunch → pane opens at nearest ancestor.
- [ ] Corrupt `session.json` by hand, relaunch → default session, no crash.

**Not merged to main** — this branch (`milestone-7-session-persistence`) awaits controller review before merge.
