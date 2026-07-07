# FileExplorer Milestone 3 (Dual Pane + Tabs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multiple in-window tabs (⌘T new, ⌘W close, ⌘1–9 switch), each remembering its own layout/filters/folder state; a dual-pane mode per tab (⇧⌘D) with two independent `PaneState`s, an active-pane highlight, and all commands/sidebar targeting the active pane.

**Architecture:** New Core session layer — `TabState` (1–2 `PaneState`s + active index) and `SessionState` (tabs + active tab), both `@MainActor @Observable` and unit-tested. The app target drops `AppState` in favor of `SessionState`; a custom `TabBarView` renders tab chips; the detail area renders only the active tab (state persists in the objects), as a single `PaneView` or an `HSplitView` of two. Panes self-start on first appearance via `PaneState.startIfNeeded()`.

**Tech Stack:** Swift 6 SPM (CLT toolchain — NO `@State`; use `@Observable`/`@Bindable`/manual Bindings only), SwiftUI HSplitView. Tests via `swift run FileExplorerTests` (99 assertions at milestone start; plan counts are estimates — recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-3-panes-tabs`.

**Design decisions (approved):**
- Only the active tab's content is rendered; switching tabs swaps the object graph in, so per-tab state (history, filters, selection) survives for free.
- ⌘W closes the current tab and is a NO-OP on the last tab (window close stays mouse-only) — deliberate v1 simplification, revisit if annoying.
- Toggling dual pane ON clones the active pane's folder into the new right pane and activates it; toggling OFF removes the right pane (its `PaneState` deinits; the watcher self-cleans).
- Active pane shown by an accent-colored 2 pt top bar; clicking anywhere in a pane activates it (simultaneousGesture so the Table still gets the click).
- Session persistence across app launches: NOT in this milestone (deferred with bookmarks persistence).

---

### Task 1: PaneState.startIfNeeded + TabState (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerCore/TabState.swift`
- Create: `Sources/FileExplorerTests/TabStateTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/TabStateTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func tabStateTests() async {
    let home = URL(fileURLWithPath: "/tmp")

    await test("TabState starts single-pane and toggles to dual") {
        let tab = TabState(url: home)
        expect(!tab.isDual, "starts single pane")
        expectEqual(tab.panes.count, 1, "one pane initially")
        expectEqual(tab.activePaneIndex, 0, "first pane active")

        tab.toggleDual()
        expect(tab.isDual, "dual after toggle")
        expectEqual(tab.panes.count, 2, "two panes")
        expectEqual(tab.activePaneIndex, 1, "new right pane becomes active")
        expectEqual(tab.panes[1].currentURL, tab.panes[0].currentURL,
                    "right pane clones left pane's folder")

        tab.toggleDual()
        expect(!tab.isDual, "single again after second toggle")
        expectEqual(tab.panes.count, 1, "back to one pane")
        expectEqual(tab.activePaneIndex, 0, "active index clamped back to 0")
    }

    await test("TabState activePane follows the index and clamps") {
        let tab = TabState(url: home)
        tab.toggleDual()
        tab.activePaneIndex = 0
        expect(tab.activePane === tab.panes[0], "activePane is left pane")
        tab.activePaneIndex = 1
        expect(tab.activePane === tab.panes[1], "activePane is right pane")
        tab.toggleDual()
        expect(tab.activePane === tab.panes[0], "activePane valid after collapse")
    }

    await test("TabState title tracks the active pane's folder") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let tab = TabState(url: dir)
        expectEqual(tab.title, dir.standardizedFileURL.lastPathComponent,
                    "title is folder name")
        await tab.activePane.navigate(to: sub)
        expectEqual(tab.title, "subfolder", "title follows navigation")
    }

    await test("PaneState startIfNeeded is idempotent") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneState(url: dir)
        pane.startIfNeeded()
        pane.startIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        expect(pane.hasLoadedOnce, "startIfNeeded triggers an initial load")
    }
}
```

Add `await tabStateTests()` to `main.swift` after `await paneFilterTests()`.

- [ ] **Step 2: Run tests to verify red**

Run: `swift run FileExplorerTests`
Expected: build FAILS — "cannot find 'TabState' in scope" and `PaneState` has no `startIfNeeded`.

- [ ] **Step 3: Add to `Sources/FileExplorerCore/PaneState.swift`** (near `start()`)

```swift
    private var started = false

    /// Begin watching and load once; safe to call every time the pane's view
    /// appears — only the first call does anything.
    public func startIfNeeded() {
        guard !started else { return }
        started = true
        watchCurrent()
        Task { await reload() }
    }
```

- [ ] **Step 4: Create `Sources/FileExplorerCore/TabState.swift`**

```swift
import Foundation
import Observation

/// One browser tab: one or two panes plus which of them is active.
@MainActor
@Observable
public final class TabState: Identifiable {
    public let id = UUID()
    public private(set) var panes: [PaneState]
    public var activePaneIndex = 0

    public init(url: URL) {
        panes = [PaneState(url: url)]
    }

    public var isDual: Bool { panes.count == 2 }

    public var activePane: PaneState {
        panes[min(activePaneIndex, panes.count - 1)]
    }

    /// Tab-chip label: the active pane's folder name.
    public var title: String {
        let name = activePane.currentURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    public func toggleDual() {
        if isDual {
            activePaneIndex = 0
            panes.removeLast()   // PaneState deinit stops its watcher
        } else {
            panes.append(PaneState(url: activePane.currentURL))
            activePaneIndex = 1
        }
    }
}
```

- [ ] **Step 5: Run tests to verify green**

Run: `swift run FileExplorerTests` → PASS, exit 0 (99 + ~14 new ≈ 113 — recount honestly). The `startIfNeeded` test involves a real watcher + async load; run twice for stability.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: TabState with dual-pane toggle and PaneState.startIfNeeded"
```

---

### Task 2: SessionState (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/SessionState.swift`
- Create: `Sources/FileExplorerTests/SessionStateTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/SessionStateTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func sessionStateTests() async {
    let home = URL(fileURLWithPath: "/tmp")

    await test("SessionState opens with one tab and adds/selects tabs") {
        let session = SessionState(url: home)
        expectEqual(session.tabs.count, 1, "one tab at launch")
        expectEqual(session.activeTabIndex, 0, "first tab active")

        session.newTab()
        expectEqual(session.tabs.count, 2, "new tab appended")
        expectEqual(session.activeTabIndex, 1, "new tab becomes active")
        expectEqual(session.activeTab.activePane.currentURL,
                    session.tabs[0].activePane.currentURL,
                    "new tab opens at the previous active pane's folder")

        session.selectTab(0)
        expectEqual(session.activeTabIndex, 0, "selectTab switches")
        session.selectTab(9)
        expectEqual(session.activeTabIndex, 0, "out-of-range select ignored")
    }

    await test("SessionState closeTab semantics") {
        let session = SessionState(url: home)
        session.newTab()
        session.newTab()   // 3 tabs, active = 2
        session.closeTab(at: 2)
        expectEqual(session.tabs.count, 2, "tab closed")
        expectEqual(session.activeTabIndex, 1, "active index moves to neighbor")

        session.selectTab(0)
        session.closeTab(at: 1)
        expectEqual(session.activeTabIndex, 0, "closing inactive tab keeps selection")
        expectEqual(session.tabs.count, 1, "one tab left")

        session.closeTab(at: 0)
        expectEqual(session.tabs.count, 1, "closing the last tab is a no-op")
    }

    await test("SessionState activePane tracks tab and pane switches") {
        let session = SessionState(url: home)
        session.activeTab.toggleDual()
        expect(session.activePane === session.activeTab.panes[1],
               "activePane follows dual toggle")
        session.newTab()
        expect(session.activePane === session.tabs[1].panes[0],
               "activePane follows new tab")
    }
}
```

Add `await sessionStateTests()` to `main.swift` after `await tabStateTests()`.

- [ ] **Step 2: Run tests to verify red**

Run: `swift run FileExplorerTests` → build FAILS with "cannot find 'SessionState' in scope".

- [ ] **Step 3: Create `Sources/FileExplorerCore/SessionState.swift`**

```swift
import Foundation
import Observation

/// The window's tab collection. Tabs are never empty; closing the last tab
/// is a no-op (the window itself is closed with the mouse).
@MainActor
@Observable
public final class SessionState {
    public private(set) var tabs: [TabState]
    public var activeTabIndex = 0

    public init(url: URL) {
        tabs = [TabState(url: url)]
    }

    public var activeTab: TabState {
        tabs[min(activeTabIndex, tabs.count - 1)]
    }

    public var activePane: PaneState { activeTab.activePane }

    /// New tab opens at the current active pane's folder (like Finder/WhimFiles).
    public func newTab() {
        tabs.append(TabState(url: activePane.currentURL))
        activeTabIndex = tabs.count - 1
    }

    public func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
    }

    public func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
    }
}
```

- [ ] **Step 4: Run tests to verify green**

Run: `swift run FileExplorerTests` → PASS (≈124 — recount honestly), exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: SessionState tab collection"
```

---

### Task 3: Tabs UI — TabBarView + SessionState wiring

**Files:**
- Create: `Sources/FileExplorer/TabBarView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`
- Modify: `Sources/FileExplorer/SidebarView.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`
- Delete: `Sources/FileExplorer/AppState.swift`

UI glue — no unit tests. NO `@State`.

- [ ] **Step 1: Create `Sources/FileExplorer/TabBarView.swift`**

```swift
import SwiftUI
import FileExplorerCore

struct TabBarView: View {
    @Bindable var session: SessionState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                chip(for: tab, at: index)
            }
            Button {
                session.newTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(.bar)
    }

    private func chip(for tab: TabState, at index: Int) -> some View {
        let isActive = index == session.activeTabIndex
        return HStack(spacing: 4) {
            Text(tab.title)
                .lineLimit(1)
                .font(.callout)
            if session.tabs.count > 1 {
                Button {
                    session.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { session.selectTab(index) }
    }
}
```

- [ ] **Step 2: Delete `Sources/FileExplorer/AppState.swift`**, then rewrite `Sources/FileExplorer/FileExplorerApp.swift`:

```swift
import SwiftUI
import FileExplorerCore

@main
struct FileExplorerApp: App {
    private let session = SessionState(
        url: FileManager.default.homeDirectoryForCurrentUser)

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
            NavigationSplitView {
                SidebarView(session: session)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            } detail: {
                TabContentView(session: session)
                    .navigationTitle(session.activePane.currentURL.lastPathComponent)
                    .toolbar {
                        ToolbarItemGroup(placement: .navigation) {
                            Button {
                                Task { await session.activePane.goBack() }
                            } label: { Image(systemName: "chevron.left") }
                            .disabled(!session.activePane.canGoBack)
                            .help("Back")

                            Button {
                                Task { await session.activePane.goForward() }
                            } label: { Image(systemName: "chevron.right") }
                            .disabled(!session.activePane.canGoForward)
                            .help("Forward")

                            Button {
                                Task { await session.activePane.goUp() }
                            } label: { Image(systemName: "chevron.up") }
                            .disabled(!session.activePane.canGoUp)
                            .help("Enclosing Folder")
                        }
                    }
            }
            .frame(minWidth: 760, minHeight: 400)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { session.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { session.closeTab(at: session.activeTabIndex) }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(session.tabs.count == 1)
            }
            CommandMenu("Go") {
                Button("Back") { Task { await session.activePane.goBack() } }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!session.activePane.canGoBack)
                Button("Forward") { Task { await session.activePane.goForward() } }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!session.activePane.canGoForward)
                Button("Enclosing Folder") { Task { await session.activePane.goUp() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!session.activePane.canGoUp)
                Divider()
                Button("Home") {
                    Task {
                        await session.activePane.navigate(
                            to: FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { session.activePane.showHidden },
                    set: { newValue in
                        session.activePane.showHidden = newValue
                        Task { await session.activePane.reload() }
                    }))
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Toggle Dual Pane") { session.activeTab.toggleDual() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowList) {
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") { session.selectTab(number - 1) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(number)")), modifiers: .command)
                        .disabled(session.tabs.count < number)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Create the tab-content container.** Add to the BOTTOM of `Sources/FileExplorer/TabBarView.swift` (same file keeps tab UI together):

```swift
/// Renders the tab bar plus only the ACTIVE tab's pane(s); inactive tabs keep
/// their state alive in SessionState but have no views.
struct TabContentView: View {
    @Bindable var session: SessionState

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(session: session)
            Divider()
            PaneAreaView(tab: session.activeTab)
        }
    }
}

/// Single- or dual-pane area for one tab, with active-pane highlight.
struct PaneAreaView: View {
    @Bindable var tab: TabState

    var body: some View {
        if tab.isDual {
            HSplitView {
                pane(at: 0)
                pane(at: 1)
            }
        } else {
            pane(at: 0)
        }
    }

    private func pane(at index: Int) -> some View {
        let paneState = tab.panes[index]
        let isActive = !tab.isDual || index == tab.activePaneIndex
        return VStack(spacing: 0) {
            Rectangle()
                .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .frame(height: 2)
            PaneView(pane: paneState)
        }
        .frame(minWidth: 300)
        .simultaneousGesture(TapGesture().onEnded {
            tab.activePaneIndex = index
        })
        .task(id: ObjectIdentifier(paneState)) {
            paneState.startIfNeeded()
        }
    }
}
```

- [ ] **Step 4: Retarget `Sources/FileExplorer/SidebarView.swift` to the session.** Change the property and the row action:

```swift
    @Bindable var session: SessionState
```

and in `row(_:)`:

```swift
            Task { await session.activePane.navigate(to: place.url) }
```

(Everything else in the file unchanged.)

- [ ] **Step 5: Remove the startup responsibilities PaneView doesn't own.** In `Sources/FileExplorer/PaneView.swift` no changes are strictly required, but VERIFY it still compiles against the new wiring (it takes `pane: PaneState` and is now created per active pane by `PaneAreaView`).

- [ ] **Step 6: Build and verify**

1. `swift build` → clean; `grep -rn "@State" Sources/` → empty; `grep -rn "AppState" Sources/` → empty.
2. `swift run FileExplorerTests` → PASS (same count as Task 2 end), exit 0.
3. Launch check: app runs >5 s, kill. (Interactive tab behavior deferred to walkthrough.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: in-window tabs and dual-pane layout targeting the active pane"
```

---

### Task 4: Final milestone verification

- [ ] **Step 1:** `swift run FileExplorerTests` → PASS, exit 0, twice.
- [ ] **Step 2:** `./Scripts/bundle.sh && open build/FileExplorer.app`; after 15 s, `ps -o %cpu,rss` → ~0% CPU, stable RSS; **also toggle nothing — just idle** (regression guard). Kill.
- [ ] **Step 3:** Note walkthrough items: ⌘T/⌘W/⌘1–9, tab chips select/close, tab state survives switching away and back (folder, filters, selection), ⇧⌘D dual pane, click-to-activate highlight, commands/sidebar hit the active pane, per-pane filters independent.
- [ ] **Step 4:** Fix anything real; commit (`fix: … (milestone 3 verification)`).
