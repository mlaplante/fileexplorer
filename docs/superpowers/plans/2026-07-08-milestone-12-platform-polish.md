# FileExplorer Milestone 12 (Platform & Polish) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish v3: Settings window (General + Shortcuts), Miller-column view, rubber-band grid selection, customizable keyboard shortcuts, and a lightweight GitHub-release update check — plus the FileActionsMenu split the M11 review recommended.

**Architecture:** Pure logic in Core as always (`UpdateChecker` semver compare, `KeyChord`/`ShortcutRegistry` codec+merge+conflicts, `RubberBand` rect-selection resolver, `ColumnsModel` chain computation); app-layer glue reads them. Settings persist through the existing `AppSettings`/`SettingsModel` with decodeIfPresent forward-compat. Menus resolve shortcuts through the registry so overrides apply live.

**Tech Stack:** Swift 6 SPM, CLT-only — **NO `@State`/`@FocusState`**; executable test harness (`swift run FileExplorerTests`, 610 assertions at start — recount honestly; **redirect test output to a file, piping through grep gets garbled by the RTK hook**).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-12-platform-polish`.

**Approved decisions (v3 spec + M11 learnings):**
- Update check: GitHub releases API (`mlaplante/fileexplorer`), throttled to once per 24 h, toggleable, silent on failure; banner links to the release page. No Sparkle.
- Shortcut customization covers the **character-key** app commands (New File, Duplicate, New Folder, Compare Panes, Toggle Dual Pane, Toggle Hidden, Go Home, Go to Folder, Find File, Search Contents, Command Palette, Quick Look, Get Info). Fixed-key commands (Return rename, ⌘⌫ trash, ⌘O open, ⌘[/⌘] history, ⌘1–9 tabs, ⌘T/W) stay hardcoded — recording arbitrary special keys isn't worth the surface for v3.
- Column view is a third `ViewMode` (`⌥⌘3`); old session.json files decode unknown rawValues to `.list` (existing `ViewMode(rawValue:) ?? .list` restore path — verify, don't assume). Ancestor columns are read-only browse columns; the LAST column is the pane's real listing (filters/sort apply there only). ← goes up, → enters a single selected folder.
- Rubber-band drag REPLACES the selection; ⇧ or ⌘ held at drag-START unions with the pre-drag selection. Cell frames tracked in a named coordinate space via `onGeometryChange`.
- Task 1 splits `FileActionsMenu.menu(for:)` into per-concern `@ViewBuilder` sections — pure refactor, zero behavior change (M11 final-review observation).
- Execution model: Codex applies edits (verbatim for Core/TDD tasks, adaptive-with-reading for UI glue); controller builds/tests/commits. Test output → file, then read.

**File map:**
- Create: `Sources/FileExplorerCore/UpdateChecker.swift`, `KeyChord.swift`, `ShortcutRegistry.swift`, `RubberBand.swift`, `ColumnsModel.swift`
- Create: `Sources/FileExplorer/UpdateModel.swift`, `SettingsScenes.swift`, `ColumnBrowserView.swift`
- Modify: `Sources/FileExplorerCore/SessionPersister.swift` (AppSettings), `SettingsModel.swift`, `PaneState.swift` (ViewMode.columns + owned models)
- Modify: `Sources/FileExplorer/FileActionsMenu.swift` (split), `ThumbnailGridView.swift` (rubber band), `PaneView.swift` (columns mode), `FileExplorerApp.swift` (Settings scene, registry-driven shortcuts, ⌥⌘3, banner)
- Create tests: `Sources/FileExplorerTests/UpdateCheckerTests.swift`, `ShortcutTests.swift`, `RubberBandTests.swift`, `ColumnsModelTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

---

### Task 1: Split FileActionsMenu (pure refactor)

**Files:** Modify `Sources/FileExplorer/FileActionsMenu.swift` only.

- [ ] **Step 1: Branch** — `git checkout main && git checkout -b milestone-12-platform-polish`
- [ ] **Step 2: Refactor.** Read the file. Split `menu(for:)`'s ~190-line body into private `@ViewBuilder` computed sections, each taking `targets: [URL]` as a parameter where needed, preserving EXACT content and order:

```swift
    @ViewBuilder
    func menu(for urls: Set<URL>) -> some View {
        let targets = Array(urls)
        openSection(targets)
        Divider()
        clipboardSection(targets)
        Divider()          // preserve every existing Divider position
        renameSection(targets)
        // …continue for: newItemsSection, paneTransferSection,
        // imageToolsSection(targets), archiveSection, sizeAndHashSection,
        // trashSection — grouping adjacent items exactly as they appear
        // today; the rendered menu must be IDENTICAL.
    }

    @ViewBuilder
    private func openSection(_ targets: [URL]) -> some View { /* moved items */ }
```

The exact grouping is the implementer's choice; the invariant is byte-identical rendered menu content and order (verify by diffing the extracted bodies against the original — no logic edits, no reordering, no renamed actions).
- [ ] **Step 3: Verify** — `swift build` clean; `swift run FileExplorerTests > /tmp/fx-t.txt 2>&1; tail -1 /tmp/fx-t.txt` → `PASS (610 assertions)` (unchanged count).
- [ ] **Step 4: Commit** — `git add Sources/FileExplorer/FileActionsMenu.swift && git commit -m "refactor: split FileActionsMenu into per-concern sections"`

### Task 2: UpdateChecker + settings fields + banner (TDD on the pure part)

**Files:**
- Create: `Sources/FileExplorerCore/UpdateChecker.swift`, `Sources/FileExplorer/UpdateModel.swift`
- Modify: `Sources/FileExplorerCore/SessionPersister.swift`, `SettingsModel.swift`, `Sources/FileExplorer/FileExplorerApp.swift`
- Create: `Sources/FileExplorerTests/UpdateCheckerTests.swift`; modify `main.swift`

- [ ] **Step 1: Failing tests — `UpdateCheckerTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func updateCheckerTests() async {
    await test("isNewer compares dotted versions numerically") {
        expect(UpdateChecker.isNewer(remote: "0.2.0", local: "0.1.0"), "minor bump")
        expect(UpdateChecker.isNewer(remote: "1.0.0", local: "0.9.9"), "major beats nines")
        expect(UpdateChecker.isNewer(remote: "0.1.10", local: "0.1.9"), "numeric not lexical")
        expect(!UpdateChecker.isNewer(remote: "0.1.0", local: "0.1.0"), "equal is not newer")
        expect(!UpdateChecker.isNewer(remote: "0.0.9", local: "0.1.0"), "older is not newer")
    }

    await test("isNewer tolerates v-prefixes and ragged lengths") {
        expect(UpdateChecker.isNewer(remote: "v0.2", local: "0.1.5"), "v-prefix + short remote")
        expect(!UpdateChecker.isNewer(remote: "v0.1", local: "0.1.0"), "0.1 == 0.1.0")
        expect(!UpdateChecker.isNewer(remote: "garbage", local: "0.1.0"), "unparseable → not newer")
    }

    await test("update check due only after the throttle interval") {
        let now = Date(timeIntervalSince1970: 2_000_000)
        expect(UpdateChecker.isDue(lastCheck: nil, now: now), "never checked → due")
        expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-3600), now: now),
               "1h ago → not due")
        expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now),
               "25h ago → due")
    }
}
```

- [ ] **Step 2: Register** after `await fileHasherTests()`; verify red.
- [ ] **Step 3: Implement — `UpdateChecker.swift`**

```swift
import Foundation

/// Pure pieces of the release check: semver-ish comparison and throttling.
/// Networking lives in the app layer (UpdateModel) — silent on failure.
public enum UpdateChecker {
    /// Numeric dotted comparison; leading "v" stripped; missing components
    /// are zero; any unparseable component makes the remote NOT newer
    /// (fail-quiet posture for a background check).
    public static func isNewer(remote: String, local: String) -> Bool {
        func components(_ raw: String) -> [Int]? {
            let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            let parts = trimmed.split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }
        }
        guard let remoteParts = components(remote),
              let localParts = components(local) else { return false }
        let count = max(remoteParts.count, localParts.count)
        for index in 0..<count {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let l = index < localParts.count ? localParts[index] : 0
            if r != l { return r > l }
        }
        return false
    }

    public static let throttleInterval: TimeInterval = 24 * 3600

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= throttleInterval
    }
}
```

- [ ] **Step 4: AppSettings fields** — in `SessionPersister.swift`, `AppSettings` gains `updateCheckEnabled: Bool` (default true) and `lastUpdateCheckAt: Date?` with `decodeIfPresent` defaults in the custom `init(from:)` (add the CodingKeys; encode side stays synthesized). `SettingsModel` gains:

```swift
    public func setUpdateCheckEnabled(_ enabled: Bool) {
        settings.updateCheckEnabled = enabled
        persister.saveSettings(settings)
    }

    public func markUpdateCheck(at date: Date = Date()) {
        settings.lastUpdateCheckAt = date
        persister.saveSettings(settings)
    }
```

- [ ] **Step 5: `UpdateModel.swift`** (app layer)

```swift
import Foundation
import AppKit
import Observation
import FileExplorerCore

/// Launch-time release check: throttled, toggleable, silent on failure.
@MainActor
@Observable
final class UpdateModel {
    private(set) var availableVersion: String?
    private(set) var releaseURL: URL?

    private static let latestReleaseAPI = URL(string:
        "https://api.github.com/repos/mlaplante/fileexplorer/releases/latest")!

    func checkIfDue(settings: SettingsModel) {
        guard settings.settings.updateCheckEnabled,
              UpdateChecker.isDue(lastCheck: settings.settings.lastUpdateCheckAt)
        else { return }
        settings.markUpdateCheck()
        check()
    }

    /// Unthrottled (Settings "Check Now" also uses this).
    func check() {
        let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "0"
        Task {
            guard let (data, response) = try? await URLSession.shared.data(
                    from: Self.latestReleaseAPI),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                  let tag = payload["tag_name"] as? String
            else { return }   // silent: network/parse failures are invisible
            if UpdateChecker.isNewer(remote: tag, local: local) {
                availableVersion = tag
                releaseURL = (payload["html_url"] as? String).flatMap(URL.init)
                    ?? URL(string: "https://github.com/mlaplante/fileexplorer/releases")
            }
        }
    }

    func dismiss() { availableVersion = nil }

    func openReleasePage() {
        if let releaseURL { NSWorkspace.shared.open(releaseURL) }
        dismiss()
    }
}
```

- [ ] **Step 6: Banner + launch hook — `FileExplorerApp.swift`.** Add `private let updateModel = UpdateModel()`; call `updateModel.checkIfDue(settings: settings)` from the existing `DispatchQueue.main.async` block in `init()`. In the main window's `ZStack(alignment: .top)`, after the palette overlay block, add:

```swift
                if let version = updateModel.availableVersion {
                    HStack(spacing: 8) {
                        Text("FileExplorer \(version) is available.")
                        Button("View Release") { updateModel.openReleasePage() }
                        Button("Dismiss") { updateModel.dismiss() }
                    }
                    .font(.callout)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                }
```

- [ ] **Step 7: Verify green** (assertion count grows), **Step 8: Commit** — `feat: throttled GitHub release check with banner`.

### Task 3: KeyChord + ShortcutRegistry (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/KeyChord.swift`, `ShortcutRegistry.swift`
- Modify: `SessionPersister.swift` (AppSettings.shortcutOverrides), `SettingsModel.swift`
- Create: `Sources/FileExplorerTests/ShortcutTests.swift`; modify `main.swift`

- [ ] **Step 1: Failing tests — `ShortcutTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func shortcutTests() async {
    await test("KeyChord displays macOS-style modifier glyph order") {
        let chord = KeyChord(key: "k", command: true, shift: true,
                             option: false, control: false)
        expectEqual(chord.display, "⇧⌘K", "shift-command-K")
        let full = KeyChord(key: "x", command: true, shift: true,
                            option: true, control: true)
        expectEqual(full.display, "⌃⌥⇧⌘X", "canonical glyph order")
    }

    await test("KeyChord round-trips through Codable") {
        let chord = KeyChord(key: "d", command: true, shift: false,
                             option: true, control: false)
        let data = try JSONEncoder().encode(chord)
        expectEqual(try JSONDecoder().decode(KeyChord.self, from: data), chord,
                    "round-trip")
    }

    await test("registry resolves defaults and overrides") {
        let defaults = ShortcutRegistry.defaultChord(for: .duplicate)
        expectEqual(defaults, KeyChord(key: "d", command: true, shift: false,
                                       option: false, control: false),
                    "⌘D default")
        let override = KeyChord(key: "j", command: true, shift: true,
                                option: false, control: false)
        let effective = ShortcutRegistry.effectiveChord(
            for: .duplicate, overrides: [ShortcutRegistry.Command.duplicate.rawValue: override])
        expectEqual(effective, override, "override wins")
        expectEqual(ShortcutRegistry.effectiveChord(for: .newFile, overrides: [:]),
                    ShortcutRegistry.defaultChord(for: .newFile), "no override → default")
    }

    await test("conflict detection flags duplicate effective chords") {
        let clash = ShortcutRegistry.defaultChord(for: .newFile) // ⌥⌘N
        let overrides = [ShortcutRegistry.Command.duplicate.rawValue: clash]
        let conflicts = ShortcutRegistry.conflicts(overrides: overrides)
        expect(conflicts.contains { $0.contains(.duplicate) && $0.contains(.newFile) },
               "duplicate vs newFile clash detected")
        expect(ShortcutRegistry.conflicts(overrides: [:]).isEmpty,
               "defaults are conflict-free")
    }

    await test("AppSettings persists shortcut overrides forward-compatibly") {
        let old = #"{"jpegQuality":0.9}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        expect(decoded.shortcutOverrides.isEmpty, "missing key → empty")
        var settings = AppSettings()
        settings.shortcutOverrides = ["duplicate": KeyChord(
            key: "j", command: true, shift: false, option: false, control: false)]
        let data = try JSONEncoder().encode(settings)
        let round = try JSONDecoder().decode(AppSettings.self, from: data)
        expectEqual(round.shortcutOverrides, settings.shortcutOverrides, "round-trip")
    }
}
```

- [ ] **Step 2: Register + red.** **Step 3: Implement — `KeyChord.swift`**

```swift
import Foundation

/// A customizable key combination: one character key plus modifiers.
/// Special keys (Return, Delete, arrows) are deliberately out of scope —
/// fixed-key commands keep their hardcoded shortcuts.
public struct KeyChord: Codable, Equatable, Sendable {
    public var key: String   // single lowercase character
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool, shift: Bool,
                option: Bool, control: Bool) {
        self.key = key.lowercased()
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// macOS HIG glyph order: ⌃ ⌥ ⇧ ⌘.
    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "")
            + (command ? "⌘" : "") + key.uppercased()
    }
}
```

- [ ] **Step 4: Implement — `ShortcutRegistry.swift`**

```swift
import Foundation

/// The customizable command set and its default chords. Effective chord =
/// override if present, else default. Pure.
public enum ShortcutRegistry {
    public enum Command: String, CaseIterable, Sendable {
        case newFile, duplicate, newFolder, comparePanes, dualPane,
             toggleHidden, goHome, gotoFolder, findFile, contentSearch,
             commandPalette, quickLook, getInfo

        public var displayName: String {
            switch self {
            case .newFile: "New File"
            case .duplicate: "Duplicate"
            case .newFolder: "New Folder"
            case .comparePanes: "Compare Panes"
            case .dualPane: "Toggle Dual Pane"
            case .toggleHidden: "Toggle Hidden Files"
            case .goHome: "Go Home"
            case .gotoFolder: "Go to Folder…"
            case .findFile: "Find File…"
            case .contentSearch: "Search File Contents…"
            case .commandPalette: "Command Palette…"
            case .quickLook: "Quick Look"
            case .getInfo: "Get Info"
            }
        }
    }

    private static let defaults: [Command: KeyChord] = [
        .newFile: KeyChord(key: "n", command: true, shift: false, option: true, control: false),
        .duplicate: KeyChord(key: "d", command: true, shift: false, option: false, control: false),
        .newFolder: KeyChord(key: "n", command: true, shift: true, option: false, control: false),
        .comparePanes: KeyChord(key: "k", command: true, shift: true, option: false, control: false),
        .dualPane: KeyChord(key: "d", command: true, shift: true, option: false, control: false),
        .toggleHidden: KeyChord(key: ".", command: true, shift: true, option: false, control: false),
        .goHome: KeyChord(key: "h", command: true, shift: true, option: false, control: false),
        .gotoFolder: KeyChord(key: "g", command: true, shift: false, option: false, control: false),
        .findFile: KeyChord(key: "p", command: true, shift: false, option: false, control: false),
        .contentSearch: KeyChord(key: "f", command: true, shift: true, option: false, control: false),
        .commandPalette: KeyChord(key: "a", command: true, shift: true, option: false, control: false),
        .quickLook: KeyChord(key: "y", command: true, shift: false, option: false, control: false),
        .getInfo: KeyChord(key: "i", command: true, shift: false, option: false, control: false),
    ]

    public static func defaultChord(for command: Command) -> KeyChord {
        defaults[command]!
    }

    public static func effectiveChord(for command: Command,
                                      overrides: [String: KeyChord]) -> KeyChord {
        overrides[command.rawValue] ?? defaultChord(for: command)
    }

    /// Groups of commands whose EFFECTIVE chords collide.
    public static func conflicts(overrides: [String: KeyChord]) -> [[Command]] {
        var byChord: [KeyChord: [Command]] = [:]
        for command in Command.allCases {
            byChord[effectiveChord(for: command, overrides: overrides),
                    default: []].append(command)
        }
        return byChord.values.filter { $0.count > 1 }.map { $0 }
    }
}
```

(`KeyChord` needs `Hashable` for the dictionary key — add it to the struct's conformances.)

- [ ] **Step 5: AppSettings** — add `shortcutOverrides: [String: KeyChord]` (default `[:]`, decodeIfPresent, CodingKeys entry). `SettingsModel` gains:

```swift
    public func setShortcutOverride(_ chord: KeyChord,
                                    for command: ShortcutRegistry.Command) {
        settings.shortcutOverrides[command.rawValue] = chord
        persister.saveSettings(settings)
    }

    public func clearShortcutOverride(for command: ShortcutRegistry.Command) {
        settings.shortcutOverrides.removeValue(forKey: command.rawValue)
        persister.saveSettings(settings)
    }

    public func resetAllShortcuts() {
        settings.shortcutOverrides = [:]
        persister.saveSettings(settings)
    }

    public func chord(for command: ShortcutRegistry.Command) -> KeyChord {
        ShortcutRegistry.effectiveChord(for: command,
                                        overrides: settings.shortcutOverrides)
    }
```

- [ ] **Step 6: Green + commit** — `feat: KeyChord and ShortcutRegistry with persisted overrides`.

### Task 4: Settings window + registry-driven menu shortcuts

**Files:**
- Create: `Sources/FileExplorer/SettingsScenes.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

- [ ] **Step 1: `SettingsScenes.swift`** — General pane (JPG quality via the existing presets, update toggle, Check Now button showing `lastUpdateCheckAt`), Shortcuts pane (one row per `ShortcutRegistry.Command`: displayName, effective `chord.display`, Record button, per-row Reset when overridden, a global Reset All button, inline conflict warning via `ShortcutRegistry.conflicts`). Recorder: an `@Observable ShortcutRecorderModel` holding `recordingCommand: ShortcutRegistry.Command?`; starting recording installs an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` that captures the first character-key chord (`event.charactersIgnoringModifiers`, length 1), writes it via `settings.setShortcutOverride`, removes the monitor, and swallows the event (return nil). Escape cancels. All view state on the model — no `@State`.
- [ ] **Step 2: Settings scene — `FileExplorerApp.swift`.** Add after the Info window scene:

```swift
        Settings {
            SettingsRootView(settings: settings, updateModel: updateModel)
        }
```

- [ ] **Step 3: Registry-driven shortcuts.** Add a tiny bridge (in `SettingsScenes.swift` or a small extension file):

```swift
extension KeyChord {
    var keyboardShortcut: KeyboardShortcut? {
        guard let character = key.first, key.count == 1 else { return nil }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}
```

Then in `FileExplorerApp.swift`, replace the hardcoded `.keyboardShortcut(...)` on the 13 registry commands with `.keyboardShortcut(settings.chord(for: .newFile).keyboardShortcut)` etc. (the optional-taking overload exists; commands re-evaluate when settings change because `SettingsModel` is `@Observable`). The View-menu Picker rows (⌥⌘1/2/3) and fixed-key commands are untouched.
- [ ] **Step 4: Build + suite green; manual sanity deferred to walkthrough. Commit** — `feat: Settings window and customizable shortcuts`.

### Task 5: Column view (⌥⌘3)

**Files:**
- Create: `Sources/FileExplorerCore/ColumnsModel.swift`, `Sources/FileExplorer/ColumnBrowserView.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift`, `Sources/FileExplorer/PaneView.swift`, `FileExplorerApp.swift`
- Create: `Sources/FileExplorerTests/ColumnsModelTests.swift`; modify `main.swift`

- [ ] **Step 1: Failing tests — `ColumnsModelTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func columnsModelTests() async {
    await test("columnChain yields capped ancestors plus current") {
        let url = URL(fileURLWithPath: "/a/b/c/d/e")
        let chain = ColumnsModel.columnChain(for: url, maxColumns: 3)
        expectEqual(chain.map(\.path), ["/a/b/c", "/a/b/c/d", "/a/b/c/d/e"],
                    "last three path levels")
        let short = ColumnsModel.columnChain(for: URL(fileURLWithPath: "/tmp"),
                                             maxColumns: 4)
        expectEqual(short.map(\.path), ["/", "/tmp"], "root-bounded chain")
    }

    await test("refresh loads listings for every column") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-col-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("f.txt"),
                      atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ColumnsModel()
        await model.refresh(for: sub, showHidden: false, maxColumns: 2)
        expectEqual(model.columns.count, 2, "two columns")
        expectEqual(model.columns.last?.url.lastPathComponent, "sub", "current last")
        expectEqual(model.columns.last?.entries.map(\.name), ["f.txt"],
                    "current column lists contents")
        expect(model.columns.first?.entries.contains { $0.name == "sub" } == true,
               "ancestor column lists the child dir")
    }
}
```

- [ ] **Step 2: Register + red. Step 3: Implement — `ColumnsModel.swift`**

```swift
import Foundation
import Observation

/// Backs the Miller-column browser: one loaded listing per visible column.
/// Ancestor columns are plain name-sorted listings; the CURRENT column is
/// rendered from the pane's own visibleEntries (filters/sort apply there),
/// so this model's last column is used only for its URL identity.
@MainActor
@Observable
public final class ColumnsModel {
    public struct Column: Identifiable, Sendable {
        public let url: URL
        public let entries: [FileEntry]
        public var id: String { url.path }
    }

    public private(set) var columns: [Column] = []
    private var generation = 0

    public init() {}

    /// The trailing `maxColumns` levels of the path, root-bounded, ending
    /// at `url` itself. Pure.
    public static func columnChain(for url: URL, maxColumns: Int) -> [URL] {
        let chain = url.standardizedFileURL.ancestorChain
        return Array(chain.suffix(maxColumns))
    }

    public func refresh(for url: URL, showHidden: Bool,
                        maxColumns: Int = 4) async {
        generation += 1
        let myGeneration = generation
        let chain = Self.columnChain(for: url, maxColumns: maxColumns)
        let loaded = await Task.detached(priority: .userInitiated) {
            chain.map { columnURL in
                Column(url: columnURL,
                       entries: (try? DirectoryLoader.load(
                           columnURL, includeHidden: showHidden)) ?? [])
            }
        }.value
        guard myGeneration == generation else { return }
        columns = loaded
    }
}
```

**Check `URL.ancestorChain`'s contract first** (`Sources/FileExplorerCore/URL+AncestorChain.swift`): the test assumes it yields root→…→self INCLUSIVE of self, ordered outermost-first. If it excludes self or orders differently, adapt `columnChain` (not the tests' expectations — those encode the required behavior).

- [ ] **Step 4: PaneState** — `ViewMode` gains `case columns`; PaneState gains `public let columnsModel = ColumnsModel()` (owned like `hoverPreview`). Confirm the snapshot-restore path (`ViewMode(rawValue:) ?? .list`) still compiles untouched — old session files with unknown rawValues fall back to `.list`, and M12 files opened by older builds do the same.
- [ ] **Step 5: `ColumnBrowserView.swift`** — horizontal `ScrollView` + `HStack` of columns. Ancestor columns: `List` of that column's entries (folders + files, name-sorted as loaded); clicking a FOLDER navigates the pane to it (`Task { await pane.navigate(to: url) }`); the entry matching the next column's URL renders `.fontWeight(.semibold)`. The LAST column renders `pane.visibleEntries` with `List(selection:)` bound to `pane.selection` (same row content as the table's Name column: icon, name, symlink badge, tag dots — reuse by extracting the row HStack from PaneView into a shared small view if convenient, otherwise duplicate the 10 lines). Double-click opens via the pane's `openSelection`. `onKeyPress(.leftArrow)` → `pane.goUp()`; `onKeyPress(.rightArrow)` → if exactly one selected folder, navigate into it. `.task(id: pane.currentURL)` + `.task(id: pane.showHidden)` call `pane.columnsModel.refresh(for: pane.currentURL, showHidden: pane.showHidden)`. Columns ~220 pt wide, `frame(minWidth:)`.
- [ ] **Step 6: PaneView** — the `Group` currently switches `pane.viewMode == .icons` → grid, else table. Make it a three-way switch adding `.columns` → `ColumnBrowserView(pane: pane, actions: FileActions(...))` (context menu on rows via `actions.menu(for:)` like the grid). **FileExplorerApp** — the View picker gains `Text("as Columns").tag(PaneState.ViewMode.columns).keyboardShortcut("3", modifiers: [.command, .option])`.
- [ ] **Step 7: Green + commit** — `feat: Miller-column view mode (⌥⌘3)`.

### Task 6: Rubber-band grid selection (TDD on the resolver)

**Files:**
- Create: `Sources/FileExplorerCore/RubberBand.swift`
- Modify: `Sources/FileExplorer/ThumbnailGridView.swift`, `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerTests/RubberBandTests.swift`; modify `main.swift`

- [ ] **Step 1: Failing tests — `RubberBandTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func rubberBandTests() async {
    let a = URL(fileURLWithPath: "/tmp/a")
    let b = URL(fileURLWithPath: "/tmp/b")
    let c = URL(fileURLWithPath: "/tmp/c")
    let frames = [
        a: CGRect(x: 0, y: 0, width: 100, height: 100),
        b: CGRect(x: 200, y: 0, width: 100, height: 100),
        c: CGRect(x: 0, y: 200, width: 100, height: 100),
    ]

    await test("normalizedRect handles any drag direction") {
        let rect = RubberBand.normalizedRect(from: CGPoint(x: 250, y: 250),
                                             to: CGPoint(x: 50, y: 50))
        expectEqual(rect, CGRect(x: 50, y: 50, width: 200, height: 200),
                    "up-left drag normalizes")
    }

    await test("select replaces with intersecting cells") {
        let rect = CGRect(x: 50, y: 50, width: 200, height: 200)
        expectEqual(RubberBand.select(frames: frames, rect: rect,
                                      base: [c], union: false),
                    [a, b, c], "all three intersect; base ignored on replace")
        let narrow = CGRect(x: 0, y: 0, width: 50, height: 50)
        expectEqual(RubberBand.select(frames: frames, rect: narrow,
                                      base: [b], union: false),
                    [a], "only a intersects")
    }

    await test("union mode keeps the pre-drag base selection") {
        let narrow = CGRect(x: 0, y: 0, width: 50, height: 50)
        expectEqual(RubberBand.select(frames: frames, rect: narrow,
                                      base: [b], union: true),
                    [a, b], "base unioned")
    }
}
```

- [ ] **Step 2: Register + red. Step 3: Implement — `RubberBand.swift`**

```swift
import Foundation

/// Pure rubber-band selection math; the grid owns gesture + frame tracking.
public enum RubberBand {
    public static func normalizedRect(from origin: CGPoint,
                                      to current: CGPoint) -> CGRect {
        CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
               width: abs(current.x - origin.x),
               height: abs(current.y - origin.y))
    }

    public static func select(frames: [URL: CGRect], rect: CGRect,
                              base: Set<URL>, union: Bool) -> Set<URL> {
        let hit = Set(frames.filter { $0.value.intersects(rect) }.keys)
        return union ? base.union(hit) : hit
    }
}
```

- [ ] **Step 4: Transient drag state on PaneState** (house pattern, not snapshotted):

```swift
    /// Transient rubber-band drag state for the icon grid (view-layer
    /// geometry; deliberately NOT read by snapshot()).
    @ObservationIgnored public var rubberBandFrames: [URL: CGRect] = [:]
    public var rubberBandRect: CGRect?
    @ObservationIgnored public var rubberBandBase = Set<URL>()
    @ObservationIgnored public var rubberBandUnion = false
```

(`rubberBandRect` IS observed — the grid draws the marquee from it.)

- [ ] **Step 5: Grid glue — `ThumbnailGridView.swift`.** Cells report frames in a named space; a background drag drives selection live:

```swift
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(pane.visibleEntries) { entry in
                    ThumbnailCell(...)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("fxGrid"))
                        } action: { frame in
                            pane.rubberBandFrames[entry.url] = frame
                        }
                        // existing modifiers unchanged
                }
            }
            .padding(8)
        }
        .coordinateSpace(name: "fxGrid")
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("fxGrid"))
                .onChanged { value in
                    if pane.rubberBandRect == nil {
                        let flags = NSEvent.modifierFlags
                        pane.rubberBandUnion = flags.contains(.shift)
                            || flags.contains(.command)
                        pane.rubberBandBase = pane.selection
                    }
                    let rect = RubberBand.normalizedRect(
                        from: value.startLocation, to: value.location)
                    pane.rubberBandRect = rect
                    pane.selection = RubberBand.select(
                        frames: pane.rubberBandFrames, rect: rect,
                        base: pane.rubberBandBase, union: pane.rubberBandUnion)
                }
                .onEnded { _ in pane.rubberBandRect = nil }
        )
        .overlay {
            if let rect = pane.rubberBandRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .border(Color.accentColor.opacity(0.6), width: 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
```

**Caveats for the implementer:** the overlay's coordinate space is the ScrollView's own frame space, not "fxGrid" content space — if the marquee visibly misaligns when the grid is scrolled, wrap the overlay INSIDE the ScrollView content (as a `.overlay` on the LazyVGrid, which shares the content coordinate space) instead. Prune stale frames on entry removal is unnecessary (frames dict only ever read for currently-rendered URLs intersecting; stale keys are harmless because selection assignment goes through `RubberBand.select` over frames of rendered cells — but if visibleEntries shrinks mid-drag the stale rect may select ghosts; acceptable for v3, note in walkthrough).

- [ ] **Step 6: Green + commit** — `feat: rubber-band selection in the icon grid`.

### Task 7: README, walkthrough, final review, merge

- [ ] **Step 1: README** — shortcut table gains `| ⌥⌘3 | View as Columns |`; blurb mentions Settings window and column view; a "Updating" note: the app checks GitHub releases daily (toggleable in Settings).
- [ ] **Step 2: Full gate** — build, suite (file-redirected output), `./Scripts/bundle.sh`.
- [ ] **Step 3: MANUAL walkthrough:**
  - [ ] Settings ⌘, opens; JPG quality + update toggle persist; Check Now works against a fixture/newer tag.
  - [ ] Shortcuts pane: record ⇧⌘J for Duplicate → menu updates live; conflict warning on a clash; per-row and global reset.
  - [ ] ⌥⌘3 columns: ancestors browse, → descends, ← ascends, filters/sort apply to last column only; session restores column mode.
  - [ ] Rubber band: drag selects; ⇧-drag unions; marquee aligns while scrolled; no ghost selections.
  - [ ] Update banner appears for a newer release tag; Dismiss and View Release behave; no banner when up-to-date/offline.
  - [ ] FileActionsMenu split: context menu renders identically to pre-M12 (spot-check every section).
- [ ] **Step 4: Final whole-milestone review** (cross-cutting: settings forward/backward compat with M9-M11 files; shortcut overrides vs fixed keys; column view session round-trip; rubber band vs click-select interplay).
- [ ] **Step 5: Completion notes + merge** (user precedent: merge to main, no push).

---

## Completion Notes

**Completed 2026-07-08.** All 6 implementation tasks done; **v3 is feature-complete**. Final suite: **641 assertions, PASS** (610 at start).

**Swift 6 concurrency traps hit and fixed at execution time (all app-target, invisible to the Core-only test run):**
- Escaping closure in the App struct's `init` can't capture mutating self — hoist stored-property references into locals first.
- `NSEvent` is non-Sendable: extract keyCode/characters/modifierFlags BEFORE `MainActor.assumeIsolated`, return a Bool decision out, map to `nil`/event outside.
- `isolated deinit` required to tear down the recorder's event monitor (same pattern as VolumesModel).

**Deferred / accepted:**
- Rubber-band: stale frames during a mid-drag listing change can ghost-select briefly (documented in plan; walkthrough item).
- Shortcut recording is character-keys-with-⌘ only; special keys stay fixed (spec decision).
- Ancestor columns in column view are read-only browse lists; no drag targets.

**MANUAL walkthrough (human, ~10 min):**
- [ ] Settings ⌘,: JPG quality + update toggle persist; Check Now updates the timestamp; banner appears only for a newer tag; Dismiss/View Release behave.
- [ ] Shortcuts: record a chord (e.g. ⇧⌘J for Duplicate) → menu shows it immediately; Escape cancels recording; conflict warning on a clash; per-row Reset and Reset All.
- [ ] Old settings.json (pre-M12) loads; M12 settings.json opened by an M11 build doesn't crash it (extra keys ignored).
- [ ] ⌥⌘3 columns: ancestors browse, bold trail, → descends into a selected folder, ← ascends, filters/sort apply to the last column only, session restores column mode; context menu works on last-column rows.
- [ ] Rubber band in icon view: drag-select, ⇧-drag unions, marquee aligns while scrolled, click-select still works, no ghost selections after files change mid-drag.
- [ ] Context menu identical to pre-M12 (menu split spot-check).
