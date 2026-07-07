# FileExplorer Milestone 4 (Fuzzy Find) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Spotlight-style palette with three modes — ⌘G jump-to-folder (favorites + recents + bounded scan under the current folder), ⌘P find-file (recursive enumeration under the current folder, capped), ⇧⌘A command palette — all ranked by one shared fuzzy matcher, fully keyboard-driven (type / ↑↓ / Enter / Esc).

**Architecture:** Core gains pure, tested pieces: `FuzzyMatcher` (subsequence scorer with prefix/word-boundary/camelCase/consecutive bonuses), `FolderScanner` + `FileSearcher` (blocking, capped; called via `Task.detached`), `PaletteModel` (@Observable: mode, query→ranked results, selection, present-token to discard stale async loads), and recents plumbing (`PaneState.onNavigated` → `TabState` → `SessionState.recentFolders`). App target adds `PaletteTextField` (NSViewRepresentable — self-focusing NSTextField whose delegate routes ↑↓/Enter/Esc) and `PaletteOverlayView` in a ZStack over the split view, plus a small app-command registry for ⇧⌘A.

**Tech Stack:** Swift 6 SPM (CLT toolchain — NO `@State`/`@FocusState`; @Observable/@Bindable/NSViewRepresentable only). Tests via `swift run FileExplorerTests` (129 assertions at start; counts below are estimates — recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-4-fuzzy-find`.

**Design decisions (approved):**
- ⌘P loads once per palette-open (cap 50k files, hidden/package-internals skipped), then re-ranks in memory per keystroke — no live streaming (deviation from spec's "streamed", recorded here).
- ⌘G candidates = standard favorites + session recents (MRU, cap 30) + subfolders of the current folder (BFS, depth 3, cap 2000).
- Results list caps at 50 rows; ties keep source order (favorites → recents → scanned).
- A `presentToken` guards against a slow scan landing after the palette was closed/reopened.
- File confirm navigates to the file's parent folder and selects the file.

---

### Task 1: FuzzyMatcher (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/FuzzyMatcher.swift`
- Create: `Sources/FileExplorerTests/FuzzyMatcherTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/FuzzyMatcherTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func fuzzyMatcherTests() async {
    await test("FuzzyMatcher matches subsequences case-insensitively") {
        expect(FuzzyMatcher.score(query: "doc", candidate: "Documents") != nil,
               "doc matches Documents")
        expect(FuzzyMatcher.score(query: "DOC", candidate: "documents") != nil,
               "match is case-insensitive")
        expect(FuzzyMatcher.score(query: "dcm", candidate: "Documents") != nil,
               "scattered subsequence matches")
        expect(FuzzyMatcher.score(query: "xyz", candidate: "Documents") == nil,
               "non-subsequence does not match")
        expect(FuzzyMatcher.score(query: "documentsx", candidate: "Documents") == nil,
               "query longer than matchable is nil")
        expectEqual(FuzzyMatcher.score(query: "", candidate: "anything"), 0,
                    "empty query scores zero (matches)")
    }

    await test("FuzzyMatcher prefers prefixes, word starts, and runs") {
        func s(_ q: String, _ c: String) -> Int { FuzzyMatcher.score(query: q, candidate: c)! }
        expect(s("doc", "Documents") > s("doc", "MyDocs"),
               "prefix run beats camelCase interior run")
        expect(s("doc", "MyDocs") > s("doc", "mydocs"),
               "camelCase boundary beats plain interior")
        expect(s("dow", "Downloads") > s("dow", "dawn-owl-wig"),
               "consecutive run beats scattered boundary hits")
    }

    await test("FuzzyMatcher.rank orders and filters") {
        let names = ["MyDocs", "Documents", "downloads", "notes.txt"]
        let ranked = FuzzyMatcher.rank(names, query: "doc") { $0 }
        expectEqual(ranked.first, "Documents", "best match first")
        expect(!ranked.contains("notes.txt") && !ranked.contains("downloads"),
               "non-matches dropped")
        expectEqual(FuzzyMatcher.rank(names, query: "") { $0 }, names,
                    "empty query returns original order")
        let tied = FuzzyMatcher.rank(["b-doc", "a-doc"], query: "doc") { $0 }
        expectEqual(tied, ["b-doc", "a-doc"], "ties keep source order")
    }
}
```

Add `await fuzzyMatcherTests()` to `main.swift` after `await sessionStateTests()`.

- [ ] **Step 2: Verify red** — `swift run FileExplorerTests` → "cannot find 'FuzzyMatcher' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/FuzzyMatcher.swift`**

```swift
import Foundation

/// Shared fuzzy scorer for the ⌘G/⌘P/⇧⌘A palettes.
public enum FuzzyMatcher {
    /// Case-insensitive subsequence score; nil when `query` is not a
    /// subsequence of `candidate`. Bonuses: candidate prefix, word/camelCase
    /// starts, consecutive runs. Mild penalty for long candidates.
    public static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let lower = Array(candidate.lowercased())
        let original = Array(candidate)
        var qi = 0
        var total = 0
        var streak = 0
        var previousWasSeparator = true

        for i in 0..<lower.count {
            let isBoundary = previousWasSeparator || original[i].isUppercase
            previousWasSeparator = !lower[i].isLetter && !lower[i].isNumber
            guard qi < q.count else { break }
            if lower[i] == q[qi] {
                qi += 1
                streak += 1
                total += 1 + streak * 3
                if isBoundary { total += 4 }
                if i == 0 { total += 10 }
            } else {
                streak = 0
            }
        }
        guard qi == q.count else { return nil }
        return total - lower.count / 4
    }

    /// Filters to matches and sorts best-first; ties keep source order.
    /// Empty query returns `items` unchanged.
    public static func rank<T>(_ items: [T], query: String,
                               key: (T) -> String) -> [T] {
        guard !query.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item in
                score(query: query, candidate: key(item)).map { (index, item, $0) }
            }
            .sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
            .map(\.1)
    }
}
```

- [ ] **Step 4: Verify green** — PASS (~144, recount honestly). If an ordering assertion fails, adjust the BONUS WEIGHTS (not the tests' intent) and report what you changed.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: FuzzyMatcher subsequence scorer and ranker"`

---

### Task 2: Recents plumbing (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Modify: `Sources/FileExplorerCore/TabState.swift`
- Modify: `Sources/FileExplorerCore/SessionState.swift`
- Create: `Sources/FileExplorerTests/RecentsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/RecentsTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func recentsTests() async {
    await test("SessionState records navigations as MRU recents") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        await session.activePane.navigate(to: a)
        await session.activePane.navigate(to: b)
        expectEqual(session.recentFolders.map(\.lastPathComponent), ["b", "a"],
                    "most recent first")

        await session.activePane.navigate(to: a)
        expectEqual(session.recentFolders.map(\.lastPathComponent), ["a", "b"],
                    "revisit moves to front without duplicate")
    }

    await test("recents recorded from new tabs and dual panes too") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        session.newTab()
        session.activeTab.toggleDual()
        await session.activePane.navigate(to: sub)
        expectEqual(session.recentFolders.first?.lastPathComponent, "sub",
                    "navigation in a dual pane of a new tab is recorded")
    }

    await test("recents are capped at 30") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionState(url: dir)
        for index in 0..<35 {
            let sub = dir.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            await session.activePane.navigate(to: sub)
        }
        expectEqual(session.recentFolders.count, 30, "cap enforced")
        expectEqual(session.recentFolders.first?.lastPathComponent, "d34",
                    "newest kept")
    }
}
```

Add `await recentsTests()` to `main.swift` after `await sessionStateTests()` (keep `fuzzyMatcherTests` wherever Task 1 put it — order of suites doesn't matter, just don't remove any).

- [ ] **Step 2: Verify red** — `SessionState` has no `recentFolders`.

- [ ] **Step 3: Implement.**

`PaneState.swift` — add near the top of the class:

```swift
    /// Invoked after every completed navigation (navigate/back/forward/up)
    /// with the new current URL; used by the session layer to record recents.
    public var onNavigated: (@MainActor (URL) -> Void)?
```

and at the END of `afterNavigation()` (after the `await reload()` line) add:

```swift
        onNavigated?(currentURL)
```

`TabState.swift` — thread the hook through pane creation:

```swift
    private let onNavigated: (@MainActor (URL) -> Void)?

    public init(url: URL, onNavigated: (@MainActor (URL) -> Void)? = nil) {
        self.onNavigated = onNavigated
        let pane = PaneState(url: url)
        pane.onNavigated = onNavigated
        panes = [pane]
    }
```

and in `toggleDual()`'s else-branch replace the append with:

```swift
            let pane = PaneState(url: activePane.currentURL)
            pane.onNavigated = onNavigated
            panes.append(pane)
```

`SessionState.swift` — add:

```swift
    /// Most-recently-visited folders across all tabs/panes, newest first.
    public private(set) var recentFolders: [URL] = []
    private static let recentsCap = 30
```

change `init` and `newTab()` to create hooked tabs:

```swift
    public init(url: URL) {
        tabs = []
        tabs = [makeTab(url: url)]
    }

    public func newTab() {
        tabs.append(makeTab(url: activePane.currentURL))
        activeTabIndex = tabs.count - 1
    }

    private func makeTab(url: URL) -> TabState {
        TabState(url: url) { [weak self] visited in
            self?.recordRecent(visited)
        }
    }

    private func recordRecent(_ url: URL) {
        recentFolders.removeAll { $0 == url }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > Self.recentsCap {
            recentFolders.removeLast(recentFolders.count - Self.recentsCap)
        }
    }
```

(Note: `tabs = []` then reassign is needed because `makeTab` references `self`. If the compiler objects, initialize with a plain `TabState(url: url)` and set `tabs[0]` panes' hook afterward — report whichever you needed.)

- [ ] **Step 4: Verify green** — PASS (~152, recount honestly), run twice.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: record recent folders across tabs and panes"`

---

### Task 3: FolderScanner + FileSearcher (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/FolderScanner.swift`
- Create: `Sources/FileExplorerCore/FileSearcher.swift`
- Create: `Sources/FileExplorerTests/ScannerTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/ScannerTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func scannerTests() async {
    await test("FolderScanner finds nested folders within depth, skipping hidden") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("one/two/three/four"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".hiddenDir"),
                               withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("file.txt"))

        let found = FolderScanner.subfolders(of: dir, maxDepth: 3, cap: 100)
        let names = Set(found.map(\.lastPathComponent))
        expect(names.contains("one"), "depth 1 found")
        expect(names.contains("two"), "depth 2 found")
        expect(names.contains("three"), "depth 3 found")
        expect(!names.contains("four"), "depth 4 beyond maxDepth")
        expect(!names.contains(".hiddenDir"), "hidden dirs skipped")
        expect(!names.contains("file.txt"), "files not included")
    }

    await test("FolderScanner respects the cap") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<10 {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("d\(index)"),
                withIntermediateDirectories: false)
        }
        expectEqual(FolderScanner.subfolders(of: dir, maxDepth: 2, cap: 4).count, 4,
                    "cap enforced")
    }

    await test("FileSearcher finds files recursively, skipping hidden, capped") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("nested/deep"),
                               withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("top.txt"))
        try Data().write(to: dir.appendingPathComponent("nested/mid.txt"))
        try Data().write(to: dir.appendingPathComponent("nested/deep/bottom.txt"))
        try Data().write(to: dir.appendingPathComponent(".hidden.txt"))

        let all = FileSearcher.files(under: dir, cap: 100)
        let names = Set(all.map(\.lastPathComponent))
        expect(names.contains("top.txt") && names.contains("mid.txt")
               && names.contains("bottom.txt"), "recursive files found")
        expect(!names.contains(".hidden.txt"), "hidden skipped")
        expect(!names.contains("nested"), "directories excluded")

        expectEqual(FileSearcher.files(under: dir, cap: 2).count, 2, "cap enforced")
    }
}
```

Add `await scannerTests()` to `main.swift` after `await recentsTests()`.

- [ ] **Step 2: Verify red** — "cannot find 'FolderScanner' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/FolderScanner.swift`**

```swift
import Foundation

public enum FolderScanner {
    /// Blocking BFS of subdirectories up to `maxDepth` levels below `root`,
    /// hidden dirs skipped, result capped. Call off the main actor.
    public static func subfolders(of root: URL, maxDepth: Int = 3,
                                  cap: Int = 2000) -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        while !queue.isEmpty && found.count < cap {
            let (dir, depth) = queue.removeFirst()
            guard depth < maxDepth else { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]) else { continue }
            for child in children where found.count < cap {
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    found.append(child)
                    queue.append((child, depth + 1))
                }
            }
        }
        return found
    }
}
```

**`Sources/FileExplorerCore/FileSearcher.swift`**

```swift
import Foundation

public enum FileSearcher {
    /// Blocking recursive enumeration of files under `root`, hidden files and
    /// package internals skipped, result capped. Call off the main actor.
    public static func files(under root: URL, cap: Int = 50_000) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if found.count >= cap { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if !isDirectory { found.append(url) }
        }
        return found
    }
}
```

- [ ] **Step 4: Verify green** — PASS (~163, recount honestly).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: bounded folder scanner and recursive file searcher"`

---

### Task 4: PaletteModel (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/PaletteModel.swift`
- Create: `Sources/FileExplorerTests/PaletteModelTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/PaletteModelTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func paletteModelTests() async {
    func item(_ title: String) -> PaletteItem {
        PaletteItem(id: title, title: title)
    }

    await test("PaletteModel presents, ranks, and dismisses") {
        let palette = PaletteModel()
        expect(!palette.isPresented, "hidden initially")

        palette.present(mode: .folders)
        expect(palette.isPresented, "presented")
        palette.setItems([item("Documents"), item("Downloads"), item("Music")])
        expectEqual(palette.results.count, 3, "empty query shows all")

        palette.query = "doc"
        expectEqual(palette.results.map(\.title), ["Documents"], "query filters+ranks")
        expectEqual(palette.selectedIndex, 0, "selection resets on query change")

        palette.dismiss()
        expect(!palette.isPresented, "dismissed")
    }

    await test("PaletteModel selection moves and clamps; confirm returns item") {
        let palette = PaletteModel()
        palette.present(mode: .files)
        palette.setItems([item("aa"), item("ab"), item("ac")])
        palette.query = "a"
        palette.moveSelection(1)
        expectEqual(palette.selectedIndex, 1, "down moves")
        palette.moveSelection(10)
        expectEqual(palette.selectedIndex, 2, "clamped at end")
        palette.moveSelection(-10)
        expectEqual(palette.selectedIndex, 0, "clamped at start")
        expectEqual(palette.selection?.title, "aa", "selection resolves")
    }

    await test("PaletteModel presentToken invalidates stale loads") {
        let palette = PaletteModel()
        palette.present(mode: .folders)
        let staleToken = palette.presentToken
        palette.dismiss()
        palette.present(mode: .folders)
        expect(palette.presentToken != staleToken, "token changes per presentation")
        palette.setItems([item("fresh")], token: palette.presentToken)
        expectEqual(palette.results.count, 1, "current-token items accepted")
        palette.setItems([item("stale1"), item("stale2")], token: staleToken)
        expectEqual(palette.results.map(\.title), ["fresh"],
                    "stale-token items ignored")
    }

    await test("PaletteModel caps results at 50") {
        let palette = PaletteModel()
        palette.present(mode: .commands)
        palette.setItems((0..<80).map { item("cmd\($0)") })
        expectEqual(palette.results.count, 50, "cap applied")
    }
}
```

Add `await paletteModelTests()` to `main.swift` after `await scannerTests()`.

- [ ] **Step 2: Verify red** — "cannot find 'PaletteItem'/'PaletteModel' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/PaletteModel.swift`**

```swift
import Foundation
import Observation

public struct PaletteItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String

    public init(id: String, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// State for the ⌘G/⌘P/⇧⌘A palette overlay: one mode at a time, fuzzy-ranked
/// results, keyboard selection. Async providers must pass the `presentToken`
/// they captured so results for a closed/reopened palette are dropped.
@MainActor
@Observable
public final class PaletteModel {
    public enum Mode: String, Sendable {
        case folders = "Go to Folder"
        case files = "Find File"
        case commands = "Commands"
    }

    public static let maxResults = 50

    public private(set) var mode: Mode = .folders
    public private(set) var isPresented = false
    public private(set) var presentToken = 0
    public private(set) var isLoading = false
    public var query = "" {
        didSet { rerank() }
    }
    public private(set) var results: [PaletteItem] = []
    public var selectedIndex = 0

    private var allItems: [PaletteItem] = []

    public init() {}

    public func present(mode: Mode) {
        self.mode = mode
        presentToken += 1
        query = ""
        allItems = []
        results = []
        selectedIndex = 0
        isLoading = true
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
        isLoading = false
    }

    /// Providers pass the token captured at present time; without it (UI
    /// setting synchronous items) the current token is assumed.
    public func setItems(_ items: [PaletteItem], token: Int? = nil) {
        if let token, token != presentToken { return }
        allItems = items
        isLoading = false
        rerank()
    }

    public func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    public var selection: PaletteItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    private func rerank() {
        results = Array(
            FuzzyMatcher.rank(allItems, query: query) { $0.title }
                .prefix(Self.maxResults))
        selectedIndex = 0
    }
}
```

- [ ] **Step 4: Verify green** — PASS (~178, recount honestly).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: PaletteModel with fuzzy-ranked results and stale-load token"`

---

### Task 5: Palette UI + command registry + shortcuts

**Files:**
- Create: `Sources/FileExplorer/PaletteTextField.swift`
- Create: `Sources/FileExplorer/PaletteOverlayView.swift`
- Create: `Sources/FileExplorer/PaletteCoordinator.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

UI glue — no unit tests. NO `@State`/`@FocusState`.

- [ ] **Step 1: Create `Sources/FileExplorer/PaletteTextField.swift`**

```swift
import SwiftUI
import AppKit
import FileExplorerCore

/// NSTextField bridge: self-focuses on appear and routes ↑/↓/Enter/Esc to the
/// palette (no @FocusState on this toolchain).
struct PaletteTextField: NSViewRepresentable {
    @Bindable var palette: PaletteModel
    var onConfirm: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(palette: palette, onConfirm: onConfirm)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Type to search…"
        field.font = .systemFont(ofSize: 18)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onConfirm = onConfirm
        if field.stringValue != palette.query {
            field.stringValue = palette.query
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let palette: PaletteModel
        var onConfirm: () -> Void

        init(palette: PaletteModel, onConfirm: @escaping () -> Void) {
            self.palette = palette
            self.onConfirm = onConfirm
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            palette.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                palette.moveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                palette.moveSelection(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                onConfirm()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                palette.dismiss()
                return true
            default:
                return false
            }
        }
    }
}
```

- [ ] **Step 2: Create `Sources/FileExplorer/PaletteOverlayView.swift`**

```swift
import SwiftUI
import FileExplorerCore

struct PaletteOverlayView: View {
    @Bindable var palette: PaletteModel
    var onConfirm: (PaletteItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(palette.mode.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if palette.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            PaletteTextField(palette: palette) {
                if let item = palette.selection { onConfirm(item) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(palette.results.enumerated()),
                                id: \.element.id) { index, item in
                            row(item, selected: index == palette.selectedIndex)
                                .id(item.id)
                                .onTapGesture { onConfirm(item) }
                        }
                    }
                }
                .onChange(of: palette.selectedIndex) { _, newIndex in
                    if palette.results.indices.contains(newIndex) {
                        proxy.scrollTo(palette.results[newIndex].id)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: Create `Sources/FileExplorer/PaletteCoordinator.swift`** — providers + confirm actions + command registry:

```swift
import Foundation
import AppKit
import FileExplorerCore

/// Wires palette modes to their data providers and confirm actions.
@MainActor
enum PaletteCoordinator {
    static func openFolders(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .folders)
        let token = palette.presentToken
        let current = session.activePane.currentURL
        let favorites = standardFavorites()
        let recents = session.recentFolders
        Task.detached(priority: .userInitiated) {
            let scanned = FolderScanner.subfolders(of: current)
            let ordered = dedupe(favorites + recents + scanned)
            let items = ordered.map { folderItem($0) }
            await palette.setItems(items, token: token)
        }
    }

    static func openFiles(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .files)
        let token = palette.presentToken
        let current = session.activePane.currentURL
        Task.detached(priority: .userInitiated) {
            let files = FileSearcher.files(under: current)
            let items = files.map {
                PaletteItem(id: $0.path, title: $0.lastPathComponent,
                            subtitle: abbreviate($0.deletingLastPathComponent()))
            }
            await palette.setItems(items, token: token)
        }
    }

    static func openCommands(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .commands)
        palette.setItems(commands(for: session).map {
            PaletteItem(id: $0.id, title: $0.name, subtitle: $0.shortcut)
        })
    }

    static func confirm(_ item: PaletteItem, palette: PaletteModel,
                        session: SessionState) {
        palette.dismiss()
        switch palette.mode {
        case .folders:
            let url = URL(fileURLWithPath: item.id)
            Task { await session.activePane.navigate(to: url) }
        case .files:
            let url = URL(fileURLWithPath: item.id)
            Task {
                let pane = session.activePane
                await pane.navigate(to: url.deletingLastPathComponent())
                pane.selection = [url.standardizedFileURL]
            }
        case .commands:
            commands(for: session).first { $0.id == item.id }?.action()
        }
    }

    struct AppCommand {
        let id: String
        let name: String
        let shortcut: String
        let action: @MainActor () -> Void
    }

    static func commands(for session: SessionState) -> [AppCommand] {
        [
            AppCommand(id: "back", name: "Back", shortcut: "⌘[") {
                Task { await session.activePane.goBack() }
            },
            AppCommand(id: "forward", name: "Forward", shortcut: "⌘]") {
                Task { await session.activePane.goForward() }
            },
            AppCommand(id: "up", name: "Enclosing Folder", shortcut: "⌘↑") {
                Task { await session.activePane.goUp() }
            },
            AppCommand(id: "home", name: "Go Home", shortcut: "⇧⌘H") {
                Task {
                    await session.activePane.navigate(
                        to: FileManager.default.homeDirectoryForCurrentUser)
                }
            },
            AppCommand(id: "newtab", name: "New Tab", shortcut: "⌘T") {
                session.newTab()
            },
            AppCommand(id: "closetab", name: "Close Tab", shortcut: "⌘W") {
                session.closeTab(at: session.activeTabIndex)
            },
            AppCommand(id: "dual", name: "Toggle Dual Pane", shortcut: "⇧⌘D") {
                session.activeTab.toggleDual()
            },
            AppCommand(id: "hidden", name: "Toggle Hidden Files", shortcut: "⇧⌘.") {
                session.activePane.showHidden.toggle()
                Task { await session.activePane.reload() }
            },
            AppCommand(id: "clearfilters", name: "Clear Filters", shortcut: "") {
                session.activePane.clearFilters()
            },
            AppCommand(id: "reveal", name: "Reveal in Finder", shortcut: "") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [session.activePane.currentURL])
            },
        ]
    }

    private static func standardFavorites() -> [URL] {
        let fm = FileManager.default
        var urls = [fm.homeDirectoryForCurrentUser]
        let dirs: [FileManager.SearchPathDirectory] =
            [.desktopDirectory, .documentDirectory, .downloadsDirectory,
             .picturesDirectory]
        for dir in dirs {
            if let url = fm.urls(for: dir, in: .userDomainMask).first,
               fm.fileExists(atPath: url.path) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func folderItem(_ url: URL) -> PaletteItem {
        PaletteItem(id: url.path,
                    title: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
                    subtitle: abbreviate(url.deletingLastPathComponent()))
    }

    private static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
```

- [ ] **Step 4: Wire into `Sources/FileExplorer/FileExplorerApp.swift`.**

Add a palette to the app struct (after `session`):

```swift
    private let palette = PaletteModel()
```

Wrap the `NavigationSplitView` in a ZStack (the `.frame(minWidth: 760, minHeight: 400)` moves to the ZStack; everything else stays on the split view):

```swift
        Window("FileExplorer", id: "main") {
            ZStack(alignment: .top) {
                NavigationSplitView {
                    // ... existing sidebar/detail content UNCHANGED ...
                }

                if palette.isPresented {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                        .onTapGesture { palette.dismiss() }
                    PaletteOverlayView(palette: palette) { item in
                        PaletteCoordinator.confirm(item, palette: palette,
                                                   session: session)
                    }
                    .padding(.top, 60)
                }
            }
            .frame(minWidth: 760, minHeight: 400)
        }
```

In `.commands`, extend the Go menu (after the Home button):

```swift
                Divider()
                Button("Go to Folder…") {
                    PaletteCoordinator.openFolders(palette, session: session)
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find File…") {
                    PaletteCoordinator.openFiles(palette, session: session)
                }
                .keyboardShortcut("p", modifiers: .command)
```

and add after the `CommandGroup(after: .toolbar)` block:

```swift
            CommandGroup(after: .windowArrangement) {
                Button("Command Palette…") {
                    PaletteCoordinator.openCommands(palette, session: session)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
```

- [ ] **Step 5: Verify** — `swift build` clean; `grep -rn "@State\|@FocusState" Sources/` empty; `swift run FileExplorerTests` PASS (same count as Task 4 end); launch check >5 s.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: fuzzy palette UI for go-to-folder, find-file, and commands"`

---

### Task 6: Final milestone verification

- [ ] **Step 1:** `swift run FileExplorerTests` → PASS ×2.
- [ ] **Step 2:** `./Scripts/bundle.sh && open build/FileExplorer.app`; idle check (~0% CPU, stable RSS) after 15 s; kill.
- [ ] **Step 3:** Walkthrough notes for the human: ⌘G/⌘P/⇧⌘A open the palette with focus in the field; typing ranks; ↑↓/Enter/Esc; folder jump navigates; file confirm navigates + selects; commands execute; loading spinner during big scans; palette over dual panes targets the active one.
- [ ] **Step 4:** Fix anything real; commit (`fix: … (milestone 4 verification)`).
