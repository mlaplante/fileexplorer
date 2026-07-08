# FileExplorer Milestone 8 (Interaction Debt) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pay off the remaining v1 interaction debt: grid multi-select, Finder-parity drop move/copy, JPG-quality convert presets + output selection, A↔B batch-rename swaps, direct-pane rename sheets, symlink badges, live volume list + sidebar location highlight, ⌘W-closes-window on last tab, custom date/size filter ranges, and four internal cleanups.

**Architecture:** Pure decision logic lands in Core as unit-testable helpers (`SelectionResolver`, `DropDecision`, `RenameExecutor`, `FilterEngine` range support, `SettingsModel`); views wire them up. Sheet models gain a weak target-pane reference. New optional `FilterState` fields keep M7's `session.json` decoding (synthesized Codable + optionals = decodeIfPresent).

**Tech Stack:** Swift 6 SPM, CLT-only toolchain — **NO `@State`** (transient UI state lives on `@Observable` models, incl. two popover flags on `PaneState`), no `xcodebuild`/`swift test`. Tests: `swift run FileExplorerTests` (368 assertions at start; counts are estimates — recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-8-interaction-debt`.

**Approved decisions (v2 spec `docs/superpowers/specs/2026-07-07-fileexplorer-v2-design.md`):**
- Drop: ⌥ forces copy; else same-volume = move, cross-volume = copy. Both route through existing `FileOperationService` + undo.
- JPG quality: Convert submenu presets 60/80/90/100, persisted via `AppSettings.jpegQuality` (M7's `SessionPersister`). No Settings window.
- Custom filter ranges are OPTIONAL `FilterState` fields (`ClosedRange` is Codable) — old session.json must keep decoding. Custom range overrides the preset in the engine; UI keeps them mutually exclusive.
- MANUAL walkthrough items (TCC): actual gesture/drag/popover interactions. All decision logic is unit-tested in Core.

**File map:**
- Create: `Sources/FileExplorerCore/SelectionResolver.swift`, `DropDecision.swift`, `RenameExecutor.swift`, `SettingsModel.swift`
- Modify: `Sources/FileExplorerCore/FilterState.swift`, `FilterEngine.swift`, `RenamePlan.swift`, `PaneState.swift`, `SessionPersister.swift` (quality clamp)
- Modify: `Sources/FileExplorer/ThumbnailGridView.swift`, `PaneView.swift`, `FileActionsMenu.swift`, `RenameSheet.swift`, `BatchRenameSheet.swift`, `SidebarView.swift`, `FilterBarView.swift`, `TabBarView.swift`, `FileExplorerApp.swift`
- Create tests: `SelectionResolverTests.swift`, `DropDecisionTests.swift`, `RenameExecutorTests.swift`, `SettingsModelTests.swift`; extend `FilterEngineTests.swift`, `RenamePlanTests.swift`, `PaneBatchToolsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

---

### Task 1: Grid multi-select (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/SelectionResolver.swift`
- Modify: `Sources/FileExplorerCore/PaneState.swift` (selectionAnchor)
- Modify: `Sources/FileExplorer/ThumbnailGridView.swift`
- Create: `Sources/FileExplorerTests/SelectionResolverTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Branch**

```bash
cd /Users/mlaplante/Sites/fileexplorer
git checkout main && git checkout -b milestone-8-interaction-debt
```

- [x] **Step 2: Failing tests — `Sources/FileExplorerTests/SelectionResolverTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func selectionResolverTests() async {
    let u = (0...4).map { URL(fileURLWithPath: "/tmp/f\($0)") }

    await test("plain click replaces selection") {
        let next = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [u[0], u[1]], anchor: u[0],
            commandDown: false, shiftDown: false)
        expectEqual(next, [u[2]], "plain click selects only the clicked item")
    }

    await test("command click toggles membership") {
        let added = SelectionResolver.resolve(
            clicked: u[3], in: u, current: [u[1]], anchor: u[1],
            commandDown: true, shiftDown: false)
        expectEqual(added, [u[1], u[3]], "cmd-click adds unselected item")

        let removed = SelectionResolver.resolve(
            clicked: u[1], in: u, current: [u[1], u[3]], anchor: u[1],
            commandDown: true, shiftDown: false)
        expectEqual(removed, [u[3]], "cmd-click removes selected item")
    }

    await test("shift click extends a contiguous range from the anchor") {
        let forward = SelectionResolver.resolve(
            clicked: u[3], in: u, current: [u[1]], anchor: u[1],
            commandDown: false, shiftDown: true)
        expectEqual(forward, [u[1], u[2], u[3]], "range extends forward")

        let backward = SelectionResolver.resolve(
            clicked: u[0], in: u, current: [u[2]], anchor: u[2],
            commandDown: false, shiftDown: true)
        expectEqual(backward, [u[0], u[1], u[2]], "range extends backward")

        let union = SelectionResolver.resolve(
            clicked: u[4], in: u, current: [u[0], u[3]], anchor: u[3],
            commandDown: false, shiftDown: true)
        expectEqual(union, [u[0], u[3], u[4]], "shift keeps prior selection (union)")
    }

    await test("shift without anchor or with stale anchor degrades to plain") {
        let noAnchor = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [], anchor: nil,
            commandDown: false, shiftDown: true)
        expectEqual(noAnchor, [u[2]], "no anchor → clicked item only")

        let stale = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [],
            anchor: URL(fileURLWithPath: "/tmp/gone"),
            commandDown: false, shiftDown: true)
        expectEqual(stale, [u[2]], "anchor not in list → clicked item only")
    }
}
```

- [x] **Step 3: Register** — in `main.swift`, add `await selectionResolverTests()` after `await sessionAutosaverTests()`.

- [x] **Step 4: Run to verify failure** — `swift run FileExplorerTests 2>&1 | tail -5`; expect compile error (SelectionResolver undefined).

- [x] **Step 5: Implement — `Sources/FileExplorerCore/SelectionResolver.swift`**

```swift
import Foundation

/// Pure click-selection semantics matching NSTableView/Finder:
/// plain = replace; ⌘ = toggle; ⇧ = contiguous range from the anchor
/// unioned with the current selection. Views own gesture detection; this
/// owns the set math so it stays unit-testable.
public enum SelectionResolver {
    public static func resolve(clicked: URL, in ordered: [URL],
                               current: Set<URL>, anchor: URL?,
                               commandDown: Bool, shiftDown: Bool) -> Set<URL> {
        if commandDown {
            var next = current
            if next.contains(clicked) {
                next.remove(clicked)
            } else {
                next.insert(clicked)
            }
            return next
        }
        if shiftDown, let anchor,
           let anchorIndex = ordered.firstIndex(of: anchor),
           let clickedIndex = ordered.firstIndex(of: clicked) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            return current.union(ordered[range])
        }
        return [clicked]
    }
}
```

Add to `PaneState` (near `selection`; NOT persisted — transient UI state):

```swift
    /// Last plain-clicked item in the icon grid; anchors ⇧-click ranges.
    /// Transient (not persisted), cleared implicitly when stale (resolver
    /// degrades to plain-click when the anchor leaves visibleEntries).
    @ObservationIgnored public var selectionAnchor: URL?
```

- [x] **Step 6: Run to verify pass** — expect PASS (~377).

- [x] **Step 7: Wire the grid — `Sources/FileExplorer/ThumbnailGridView.swift`**

Replace the single-tap `simultaneousGesture` on the cell:

```swift
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            let flags = NSEvent.modifierFlags
                            pane.selection = SelectionResolver.resolve(
                                clicked: entry.url,
                                in: pane.visibleEntries.map(\.url),
                                current: pane.selection,
                                anchor: pane.selectionAnchor,
                                commandDown: flags.contains(.command),
                                shiftDown: flags.contains(.shift))
                            if !flags.contains(.shift) {
                                pane.selectionAnchor = entry.url
                            }
                        })
```

(`import AppKit` is already present in this file.)

- [x] **Step 8: Build + suite + commit**

```bash
swift build 2>&1 | tail -3 && swift run FileExplorerTests 2>&1 | tail -3
git add Sources && git commit -m "feat: grid multi-select with cmd-toggle and shift-range"
```

Modifier-click gestures themselves are MANUAL walkthrough items.

---

### Task 2: Finder-parity drop semantics (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/DropDecision.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`
- Create: `Sources/FileExplorerTests/DropDecisionTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Failing tests — `Sources/FileExplorerTests/DropDecisionTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func dropDecisionTests() async {
    await test("decide follows Finder parity") {
        expectEqual(DropDecision.decide(optionDown: false, sameVolume: true),
                    .move, "same volume, no modifier → move")
        expectEqual(DropDecision.decide(optionDown: false, sameVolume: false),
                    .copy, "cross volume, no modifier → copy")
        expectEqual(DropDecision.decide(optionDown: true, sameVolume: true),
                    .copy, "option forces copy on same volume")
        expectEqual(DropDecision.decide(optionDown: true, sameVolume: false),
                    .copy, "option forces copy across volumes")
    }

    await test("sameVolume detects shared and unknown volumes") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("m8-drop-\(UUID().uuidString)")
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        expect(DropDecision.sameVolume(a, b), "two temp dirs share a volume")
        expect(!DropDecision.sameVolume(
                   dir.appendingPathComponent("missing"), b),
               "unreadable source → false (decide() then copies — safe default)")
    }
}
```

- [x] **Step 2: Register** — `await dropDecisionTests()` after `await selectionResolverTests()`.

- [x] **Step 3: Red run**, then implement — `Sources/FileExplorerCore/DropDecision.swift`:

```swift
import Foundation

/// Finder-parity drop semantics: ⌥ forces copy; otherwise a same-volume
/// drop moves and a cross-volume drop copies. Unknown volume identity
/// degrades to `false` → copy, the non-destructive default.
public enum DropDecision: Equatable, Sendable {
    case move
    case copy

    public static func decide(optionDown: Bool, sameVolume: Bool) -> DropDecision {
        if optionDown { return .copy }
        return sameVolume ? .move : .copy
    }

    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let idA = try? a.resourceValues(forKeys: [.volumeIdentifierKey])
                  .volumeIdentifier,
              let idB = try? b.resourceValues(forKeys: [.volumeIdentifierKey])
                  .volumeIdentifier else { return false }
        return idA.isEqual(idB)
    }
}
```

- [x] **Step 4: Green run** (~383), then wire `PaneView.swift`: add `import AppKit` at the top and replace the `.dropDestination` closure body:

```swift
            .dropDestination(for: URL.self) { urls, _ in
                let outside = urls.filter {
                    $0.deletingLastPathComponent().standardizedFileURL != pane.currentURL
                }
                guard !outside.isEmpty else { return false }
                let optionDown = NSEvent.modifierFlags.contains(.option)
                let sameVolume = outside.allSatisfy {
                    DropDecision.sameVolume($0, pane.currentURL)
                }
                Task {
                    switch DropDecision.decide(optionDown: optionDown,
                                               sameVolume: sameVolume) {
                    case .move:
                        await pane.moveSelected(outside, into: pane.currentURL)
                    case .copy:
                        await pane.copySelected(outside, into: pane.currentURL)
                    }
                }
                return true
            }
```

- [x] **Step 5: Build + suite + commit** — `git commit -m "feat: drop into pane moves on same volume, option/cross-volume copies"`. Actual drags are MANUAL.

---

### Task 3: Convert quality presets + output selection (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/SettingsModel.swift`
- Modify: `Sources/FileExplorerCore/SessionPersister.swift` (clamp), `Sources/FileExplorerCore/PaneState.swift` (convertSelected)
- Modify: `Sources/FileExplorer/FileActionsMenu.swift`, `PaneView.swift`, `TabBarView.swift`, `ThumbnailGridView.swift`, `FileExplorerApp.swift` (threading)
- Create: `Sources/FileExplorerTests/SettingsModelTests.swift`; extend `PaneBatchToolsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Failing tests.** Create `Sources/FileExplorerTests/SettingsModelTests.swift`:

```swift
import Foundation
import FileExplorerCore

@MainActor
func settingsModelTests() async {
    await test("SettingsModel loads, updates, persists, and clamps quality") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)

        let model = SettingsModel(persister: persister)
        expectEqual(model.settings.jpegQuality, 0.85, "defaults on first launch")

        model.setJPEGQuality(0.6)
        expectEqual(model.settings.jpegQuality, 0.6, "update applies in memory")
        expectEqual(persister.loadSettings().jpegQuality, 0.6,
                    "update persists immediately")

        let reloaded = SettingsModel(persister: persister)
        expectEqual(reloaded.settings.jpegQuality, 0.6, "fresh model reads saved value")

        expectEqual(AppSettings(jpegQuality: 7).jpegQuality, 1.0,
                    "quality clamps to 1.0 max")
        expectEqual(AppSettings(jpegQuality: -1).jpegQuality, 0.1,
                    "quality clamps to 0.1 min")
    }
}
```

And append to the END of the existing `paneBatchToolsTests()` in `Sources/FileExplorerTests/PaneBatchToolsTests.swift` (it already has `makeTempDir()` and `writeTestPNG(to:width:height:)` helpers and a local `fm`):

```swift
    await test("convertSelected selects its outputs") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let png = dir.appendingPathComponent("shot.png")
        try writeTestPNG(to: png, width: 16, height: 16)

        let pane = PaneState(url: dir)
        await pane.reload()
        await pane.convertSelected([png], to: .jpeg, jpegQuality: 0.9)

        expectEqual(pane.selection,
                    [dir.appendingPathComponent("shot.jpg").standardizedFileURL],
                    "converted output selected")
        expect(pane.opErrorMessage == nil, "no error on clean conversion")
    }
```

- [x] **Step 2: Register** — `await settingsModelTests()` after `await dropDecisionTests()`. Red run.

- [x] **Step 3: Implement.**

`Sources/FileExplorerCore/SettingsModel.swift`:

```swift
import Foundation
import Observation

/// Observable wrapper around `AppSettings` + its persister. UI mutations go
/// through setters so every change persists immediately (settings are tiny).
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var settings: AppSettings
    private let persister: SessionPersister   // let: no @ObservationIgnored needed

    public init(persister: SessionPersister) {
        self.persister = persister
        settings = persister.loadSettings()
    }

    public func setJPEGQuality(_ quality: Double) {
        settings.jpegQuality = AppSettings(jpegQuality: quality).jpegQuality
        persister.saveSettings(settings)
    }
}
```

In `SessionPersister.swift`, clamp inside `AppSettings`:

```swift
    public init(jpegQuality: Double = 0.85) {
        self.jpegQuality = min(max(jpegQuality, 0.1), 1.0)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.85
        jpegQuality = min(max(raw, 0.1), 1.0)
    }
```

In `PaneState.swift`, change `convertSelected` signature and add output selection (mirrors `batchRename`):

```swift
    public func convertSelected(_ urls: [URL], to format: ImageConverter.Format,
                                jpegQuality: Double = 0.85) async {
        let results = await Task.detached(priority: .userInitiated) {
            ImageConverter.convert(urls, to: format, jpegQuality: jpegQuality)
        }.value
        // … existing created/failures/undo bookkeeping unchanged …
        await reload()
        // … existing opErrorMessage assembly unchanged …
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }
```

- [x] **Step 4: Thread `SettingsModel` down and build the menu.**

`FileExplorerApp.swift` `init()`: after creating `persister`, add `let settings = SettingsModel(persister: persister)` stored as `private let settings: SettingsModel`; pass `settings: settings` to `TabContentView`.
`TabBarView.swift`: `TabContentView` and `PaneAreaView` each gain `var settings: SettingsModel` and pass it down to `PaneView`.
`PaneView.swift`: gains `var settings: SettingsModel`; passes it into both `FileActions(...)` constructions.
`ThumbnailGridView.swift`: no change beyond receiving the updated `FileActions` (it already takes a built `FileActions`).
`FileActionsMenu.swift`: add `let settings: SettingsModel` and replace the convert menu:

```swift
        Menu("Convert Image To") {
            Button("JPG") {
                Task { await pane.convertSelected(
                    targets, to: .jpeg,
                    jpegQuality: settings.settings.jpegQuality) }
            }
            Button("PNG") {
                Task { await pane.convertSelected(targets, to: .png) }
            }
            Divider()
            Menu("JPG Quality") {
                ForEach([0.6, 0.8, 0.9, 1.0], id: \.self) { quality in
                    Toggle("\(Int((quality * 100).rounded()))", isOn: Binding(
                        get: { settings.settings.jpegQuality == quality },
                        set: { if $0 { settings.setJPEGQuality(quality) } }))
                }
            }
        }
        .disabled(targets.isEmpty)
```

- [x] **Step 5: Green run (~389), build, commit** — `git commit -m "feat: JPG quality presets persisted in settings; convert selects outputs"`. Submenu interaction is MANUAL.

---

### Task 4: Batch-rename A↔B swaps (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/RenamePlan.swift` (vacated-name awareness)
- Create: `Sources/FileExplorerCore/RenameExecutor.swift` (two-phase execution)
- Modify: `Sources/FileExplorerCore/PaneState.swift` (batchRename uses executor)
- Extend: `Sources/FileExplorerTests/RenamePlanTests.swift`, create `RenameExecutorTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Failing tests.** Append to `renamePlanTests()`. The suffix rule produces a genuine in-batch name handoff: with items `[a.txt, ax.txt]` and suffix `"x"`, `a.txt → ax.txt` targets a name currently held by batch member `ax.txt`, which itself moves to `axx.txt` (vacating its name):

```swift
    await test("plan allows targets vacated by the batch, blocks outside holders") {
        let a = URL(fileURLWithPath: "/t/a.txt")
        let ax = URL(fileURLWithPath: "/t/ax.txt")
        var rules = RenameRules()
        rules.suffix = "x"

        let plan = RenamePlan.plan(urls: [a, ax], rules: rules,
                                   existingNames: ["a.txt", "ax.txt"])
        expectEqual(plan[0].newName, "ax.txt", "suffix applied to first item")
        expect(plan[0].conflict == nil,
               "in-batch vacated name is not a conflict")
        expectEqual(plan[1].newName, "axx.txt", "second item moves away")
        expect(plan[1].conflict == nil, "vacating item itself is clean")

        // Same target, but the holder is NOT in the batch → still blocked.
        let blocked = RenamePlan.plan(urls: [a], rules: rules,
                                      existingNames: ["a.txt", "ax.txt"])
        expectEqual(blocked[0].conflict, .existingFile,
                    "outside-holder target stays blocked")
    }
```

(Note: the vacated check is plan-level optimism — if the vacating item's own rename later fails on disk, phase 2 of the executor fails the dependent rename and rolls it back; that path is covered by the executor's blocked-target test below.)

Create `Sources/FileExplorerTests/RenameExecutorTests.swift`:

```swift
import Foundation
import FileExplorerCore

@MainActor
func renameExecutorTests() async {
    func makeDir(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        for name in names {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        return dir
    }

    await test("executor performs a two-item swap via temp phase") {
        let dir = try makeDir(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [
            RenamePlan.Item(source: dir.appendingPathComponent("a.txt"),
                            newName: "b.txt", conflict: nil),
            RenamePlan.Item(source: dir.appendingPathComponent("b.txt"),
                            newName: "a.txt", conflict: nil),
        ]
        let outcome = RenameExecutor.execute(items)
        expectEqual(outcome.pairs.count, 2, "both renames succeed")
        expect(outcome.failures.isEmpty, "no failures")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        expectEqual(Set(names), ["a.txt", "b.txt"], "same names, swapped files")
    }

    await test("executor handles a three-cycle") {
        let dir = try makeDir(["1.txt", "2.txt", "3.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [
            RenamePlan.Item(source: dir.appendingPathComponent("1.txt"),
                            newName: "2.txt", conflict: nil),
            RenamePlan.Item(source: dir.appendingPathComponent("2.txt"),
                            newName: "3.txt", conflict: nil),
            RenamePlan.Item(source: dir.appendingPathComponent("3.txt"),
                            newName: "1.txt", conflict: nil),
        ]
        let outcome = RenameExecutor.execute(items)
        expectEqual(outcome.pairs.count, 3, "cycle resolves")
        expect(outcome.failures.isEmpty, "no failures")
    }

    await test("executor rolls back to originals when a final target is blocked") {
        let dir = try makeDir(["a.txt", "blocker.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Plan says a.txt → blocker.txt is clean (stale existingNames), but
        // the file exists on disk → phase 2 must fail and phase-1 temp names
        // must be rolled back so a.txt still exists.
        let items = [RenamePlan.Item(source: dir.appendingPathComponent("a.txt"),
                                     newName: "blocker.txt", conflict: nil)]
        let outcome = RenameExecutor.execute(items)
        expect(outcome.pairs.isEmpty, "no success recorded")
        expectEqual(outcome.failures.count, 1, "failure surfaced")
        expect(FileManager.default.fileExists(
                   atPath: dir.appendingPathComponent("a.txt").path),
               "source restored to its original name")
    }

    await test("executor skips conflicted and unchanged items") {
        let dir = try makeDir(["a.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [
            RenamePlan.Item(source: dir.appendingPathComponent("a.txt"),
                            newName: "a.txt", conflict: .unchanged),
            RenamePlan.Item(source: dir.appendingPathComponent("ghost.txt"),
                            newName: "x.txt", conflict: .invalidName),
        ]
        let outcome = RenameExecutor.execute(items)
        expect(outcome.pairs.isEmpty && outcome.failures.count == 1,
               "unchanged silently skipped; conflicted reported")
    }
}
```

- [x] **Step 2: Register** (`await renameExecutorTests()` after settings), red run.

- [x] **Step 3: Implement.**

`RenamePlan.swift` — vacated-name awareness in the conflict pass:

```swift
        // Names the batch itself is renaming away; a target equal to one of
        // these is legal (two-phase execution makes the handoff safe).
        let vacated = Set(proposals.filter { $0.0.lastPathComponent != $0.1 }
            .map { $0.0.lastPathComponent })
        …
            } else if existingNames.contains(newName), !vacated.contains(newName) {
                conflict = .existingFile
```

Create `Sources/FileExplorerCore/RenameExecutor.swift`:

```swift
import Foundation

/// Applies a rename plan in two phases so in-batch name handoffs (A↔B swaps,
/// cycles) work: every clean item first moves to a unique temp name, then to
/// its final name. A phase-2 failure rolls that item back to its original
/// name so no file is ever stranded at a temp name.
public enum RenameExecutor {
    public struct Outcome: Sendable {
        public let pairs: [(from: URL, to: URL)]   // successes, original→final
        public let failures: [String]
    }

    public static func execute(_ items: [RenamePlan.Item]) -> Outcome {
        let fm = FileManager.default
        var pairs: [(from: URL, to: URL)] = []
        var failures: [String] = []

        struct Staged {
            let originalURL: URL
            let tempURL: URL
            let finalURL: URL
        }
        var staged: [Staged] = []

        // Phase 1: clean items → unique temp names in place.
        for (index, item) in items.enumerated() {
            switch item.conflict {
            case .unchanged:
                continue
            case .some(let conflict):
                failures.append(
                    "“\(item.source.lastPathComponent)” skipped (\(conflict)).")
            case nil:
                let dir = item.source.deletingLastPathComponent()
                let temp = dir.appendingPathComponent(
                    ".fx-rename-\(UUID().uuidString)-\(index)")
                do {
                    try fm.moveItem(at: item.source, to: temp)
                    staged.append(Staged(
                        originalURL: item.source, tempURL: temp,
                        finalURL: dir.appendingPathComponent(item.newName)))
                } catch {
                    failures.append("Couldn't rename “\(item.source.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
        }

        // Phase 2: temp → final; on failure, roll back to the original name.
        for stage in staged {
            do {
                try fm.moveItem(at: stage.tempURL, to: stage.finalURL)
                pairs.append((from: stage.originalURL, to: stage.finalURL))
            } catch {
                failures.append("Couldn't rename “\(stage.originalURL.lastPathComponent)” to “\(stage.finalURL.lastPathComponent)”: \(error.localizedDescription)")
                try? fm.moveItem(at: stage.tempURL, to: stage.originalURL)
            }
        }
        return Outcome(pairs: pairs, failures: failures)
    }
}
```

`PaneState.batchRename` — replace the per-item loop with the executor (keep the surrounding undo/reload/opErrorMessage/selection bookkeeping identical, feeding it `outcome.pairs`/`outcome.failures`):

```swift
    public func batchRename(_ urls: [URL], rules: RenameRules) async {
        let existing = Set(entries.map(\.name))
        let plan = RenamePlan.plan(urls: urls, rules: rules, existingNames: existing)
        let outcome = RenameExecutor.execute(plan)
        if let undoManager, !outcome.pairs.isEmpty {
            UndoRecorder.recordMove(outcome.pairs, actionName: "Batch Rename",
                                    on: undoManager, pane: self)
        }
        await reload()
        opErrorMessage = outcome.failures.isEmpty
            ? nil
            : outcome.failures.prefix(3).joined(separator: " ")
                + (outcome.failures.count > 3 ? " (+\(outcome.failures.count - 3) more)" : "")
        if !outcome.pairs.isEmpty {
            selection = Set(outcome.pairs.map { $0.to.standardizedFileURL })
        }
    }
```

Note: `Outcome.pairs` tuple labels must match `UndoRecorder.recordMove`'s expected `(from:to:)` shape — check `UndoRecorder.swift` and adapt if it wants a different label pair.

- [x] **Step 4: Green run (~400), build, existing RenamePlan/undo tests still green, commit** — `git commit -m "feat: two-phase batch rename enables A-B swaps and cycles"`.

---

### Task 5: Direct-pane rename sheets

**Files:**
- Modify: `Sources/FileExplorer/RenameSheet.swift`, `BatchRenameSheet.swift` (models gain weak pane; confirm order), `FileActionsMenu.swift`, `FileExplorerApp.swift`

- [x] **Step 1:** `RenameSheetModel` gains a target pane (weak — a tab may close under an open sheet):

```swift
    @ObservationIgnored weak var pane: PaneState?

    func present(for url: URL, in pane: PaneState) {
        self.pane = pane
        target = url
        draftName = url.lastPathComponent
    }
```

(dismiss() also sets `pane = nil`.) In `RenameSheet.confirm()`, call `onConfirm(target, newName)` BEFORE `model.dismiss()` so the App closure can still read `model.pane`; verify the sheet still dismisses (target nils right after).

`BatchRenameModel` identically: `@ObservationIgnored weak var pane: PaneState?`, `present(targets:existingNames:in:)`, dismiss clears it; mirror the confirm-order change in `BatchRenameSheet` if it dismisses before invoking its apply closure.

- [x] **Step 2:** Update the three presentation sites:
- `FileActionsMenu.swift`: `renameModel.present(for: url, in: pane)` and `batchRenameModel.present(targets: …, existingNames: …, in: pane)`.
- `FileExplorerApp.swift` File-menu "Rename…": `renameModel.present(for: url, in: session.activePane)`.
- `FileExplorerApp.swift` sheet callbacks:

```swift
                RenameSheet(model: renameModel) { url, newName in
                    let pane = renameModel.pane ?? session.activePane
                    Task { await pane.renameSelected(url, to: newName) }
                }
                …
                BatchRenameSheet(model: batchRenameModel) { targets, rules in
                    let pane = batchRenameModel.pane ?? session.activePane
                    Task { await pane.batchRename(targets, rules: rules) }
                }
```

- [x] **Step 3:** Build + suite (~unchanged count) + commit — `git commit -m "fix: rename sheets act on the pane they were opened from"`. Right-click-on-inactive-pane behavior is MANUAL.

---

### Task 6: Custom date/size filter ranges (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/FilterState.swift`, `FilterEngine.swift`, `PaneState.swift` (two popover flags)
- Modify: `Sources/FileExplorer/FilterBarView.swift`
- Extend: `Sources/FileExplorerTests/FilterEngineTests.swift`, `SessionSnapshotTests.swift`

- [x] **Step 1: Failing tests.** Append INSIDE `filterEngineTests()` (its local `entry(_:dir:size:modified:)` helper and `now` constant are in scope there):

```swift
    await test("custom date range overrides preset and filters entries") {
        var f = FilterState()
        f.datePreset = .today   // preset alone would pass anything from today
        f.customDateRange = now.addingTimeInterval(-7_200)...now.addingTimeInterval(-3_600)
        let inRange = entry("mid.png", size: 10,
                            modified: now.addingTimeInterval(-5_400))
        let tooNew = entry("new.png", size: 10, modified: now)
        let result = FilterEngine.apply(f, to: [inRange, tooNew], now: now)
        expectEqual(result.map(\.name), ["mid.png"],
                    "custom range wins over the preset")
    }

    await test("custom size range filters entries; folders pass") {
        var f = FilterState()
        f.customSizeRange = Int64(1_000)...Int64(5_000)
        let result = FilterEngine.apply(
            f, to: [entry("dir", dir: true), entry("small.txt", size: 500),
                    entry("mid.txt", size: 3_000), entry("big.txt", size: 10_000)],
            now: now)
        expectEqual(result.map(\.name).sorted(), ["dir", "mid.txt"],
                    "only the in-range file and the folder pass")
    }
```

Append to `sessionSnapshotTests()`:

```swift
    await test("FilterState with custom ranges round-trips; old JSON still decodes") {
        var filter = FilterState()
        filter.customSizeRange = Int64(1)...Int64(2)
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        expectEqual(decoded, filter, "custom ranges survive encode/decode")

        let legacy = #"{"extensions":[]}"#   // pre-M8 filter JSON, no range keys
        let old = try JSONDecoder().decode(FilterState.self, from: Data(legacy.utf8))
        expect(old.customDateRange == nil && old.customSizeRange == nil,
               "old session.json filters decode with nil custom ranges")
    }
```

- [x] **Step 2: Red run**, then implement.

`FilterState.swift`:

```swift
public struct FilterState: Equatable, Sendable, Codable {
    public var preset: TypePreset?
    /// Lowercased extensions without leading dots, e.g. ["png", "jpg"].
    public var extensions: Set<String> = []
    public var datePreset: DatePreset?
    public var sizePreset: SizePreset?
    /// Custom ranges override the corresponding preset when set (M8).
    /// OPTIONAL by contract: synthesized Codable decodes missing keys as nil,
    /// which keeps M7-era session.json files loading.
    public var customDateRange: ClosedRange<Date>?
    public var customSizeRange: ClosedRange<Int64>?

    public init() {}

    public var isActive: Bool {
        preset != nil || !extensions.isEmpty || datePreset != nil
            || sizePreset != nil || customDateRange != nil || customSizeRange != nil
    }
}
```

`FilterEngine.swift`:

```swift
        let dateRange = filter.customDateRange ?? filter.datePreset?.range(now: now)
        let sizeRange = filter.customSizeRange ?? filter.sizePreset?.range
```

`PaneState.swift` — transient popover flags near `filterExtensionsText`. They must be plain observable vars (NOT `@ObservationIgnored` — the popover's `isPresented` Binding needs change tracking to re-render); they stay out of persistence because `snapshot()` never reads them:

```swift
    /// Transient popover visibility for the filter bar's custom-range editors
    /// (no @State on this toolchain; deliberately NOT read by snapshot()).
    public var showsCustomDatePopover = false
    public var showsCustomSizePopover = false
```

- [x] **Step 3: Filter bar UI.** In `FilterBarView.swift`, add a "Custom Range…" entry to each menu and anchor popovers on the menu labels:

Date menu gains, after the preset ForEach:

```swift
                Divider()
                Button("Custom Range…") {
                    pane.filter.datePreset = nil
                    if pane.filter.customDateRange == nil {
                        let now = Date()
                        pane.filter.customDateRange =
                            now.addingTimeInterval(-86_400 * 7)...now
                    }
                    pane.showsCustomDatePopover = true
                }
```

…and the preset buttons each also clear the custom range (`pane.filter.customDateRange = nil`) so the two stay mutually exclusive; "Any Time" clears both. Attach to the date `Menu`:

```swift
            .popover(isPresented: Binding(
                get: { pane.showsCustomDatePopover },
                set: { pane.showsCustomDatePopover = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("From", selection: Binding(
                        get: { pane.filter.customDateRange?.lowerBound ?? Date() },
                        set: { newStart in
                            let end = pane.filter.customDateRange?.upperBound ?? Date()
                            pane.filter.customDateRange = min(newStart, end)...max(newStart, end)
                        }), displayedComponents: .date)
                    DatePicker("To", selection: Binding(
                        get: { pane.filter.customDateRange?.upperBound ?? Date() },
                        set: { newEnd in
                            let start = pane.filter.customDateRange?.lowerBound ?? Date()
                            pane.filter.customDateRange = min(start, newEnd)...max(start, newEnd)
                        }), displayedComponents: .date)
                    Button("Clear") {
                        pane.filter.customDateRange = nil
                        pane.showsCustomDatePopover = false
                    }
                }
                .padding(12)
                .frame(width: 240)
            }
```

Size menu mirrors it with two MB text fields (parse Int64 MB → bytes; empty min → 0, empty max → `Int64.max`; both empty → nil range). Update both menu LABELS to show "Custom" when a custom range is set:

```swift
                Label(pane.filter.customDateRange != nil ? "Custom"
                      : pane.filter.datePreset?.rawValue ?? "Date",
                      systemImage: "calendar")
```

(size label analogous). `clearFilters()` in `PaneState` already resets `filter = FilterState()` which clears both ranges — no change needed there.

- [x] **Step 4: Green run (~410), build, commit** — `git commit -m "feat: custom date and size filter ranges with popover editors"`. Popover interaction is MANUAL; range decode/apply logic is tested.

---

### Task 7: Browse polish — symlink badge, live volumes, sidebar highlight, ⌘W

**Files:**
- Modify: `Sources/FileExplorer/PaneView.swift`, `ThumbnailGridView.swift`, `SidebarView.swift`, `FileExplorerApp.swift`

- [x] **Step 1: Symlink badge.** `PaneView.swift` Name column, inside the HStack after the Text:

```swift
                    if entry.isSymlink {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                            .foregroundStyle(.secondary)
                            .help("Symbolic link")
                    }
```

`ThumbnailGridView.swift` `ThumbnailCell`: overlay the icon Group:

```swift
            .overlay(alignment: .bottomLeading) {
                if entry.isSymlink {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .foregroundStyle(.secondary)
                        .background(.background, in: Circle())
                }
            }
```

- [x] **Step 2: Live volumes.** In `SidebarView.swift`, add an app-lifetime model and take it as a parameter (view structs are stateless on this toolchain — the model must be OWNED BY `FileExplorerApp`, not the view):

```swift
/// Observes NSWorkspace mount/unmount and republishes the volume list.
/// App-lifetime: owned by FileExplorerApp (stateless view structs must not
/// own @Observable models on this no-@State toolchain).
@MainActor
@Observable
final class VolumesModel {
    private(set) var volumes: [StandardPlaces.Place] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?
                .volumeName ?? url.lastPathComponent
            return StandardPlaces.Place(name: name, url: url,
                                        systemImage: "externaldrive")
        }
    }
}
```

`SidebarView` drops its computed `volumes` property, gains `var volumesModel: VolumesModel`, iterates `volumesModel.volumes`. `FileExplorerApp` adds `private let volumesModel = VolumesModel()` and passes it: `SidebarView(session: session, volumesModel: volumesModel)`. (`import AppKit` in SidebarView.swift.)

- [x] **Step 3: Sidebar current-location highlight.** In `SidebarView.row(_:)`:

```swift
    private func row(_ place: StandardPlaces.Place) -> some View {
        let isCurrent = place.url.standardizedFileURL.path
            == session.activePane.currentURL.path
        return Button {
            Task { await session.activePane.navigate(to: place.url) }
        } label: {
            Label(place.name, systemImage: place.systemImage)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
    }
```

- [x] **Step 4: ⌘W on last tab.** `FileExplorerApp.swift`:

```swift
                Button("Close Tab") {
                    if session.tabs.count == 1 {
                        NSApp.keyWindow?.performClose(nil)
                    } else {
                        session.closeTab(at: session.activeTabIndex)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
```

(remove the `.disabled(session.tabs.count == 1)`).

- [x] **Step 5: Build + suite + launch check + commit**

```bash
swift build 2>&1 | tail -3 && swift run FileExplorerTests 2>&1 | tail -3
swift run FileExplorer & APP_PID=$!; sleep 6; kill -0 $APP_PID && echo ALIVE; kill $APP_PID
git add Sources && git commit -m "feat: symlink badges, live volume list, sidebar highlight, cmd-W closes last window"
```

Badge/highlight/mount visuals are MANUAL.

---

### Task 8: Internal cleanups

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift` (showHidden didSet, hoverPreview), `Sources/FileExplorer/FileExplorerApp.swift` (drop manual reload), `Sources/FileExplorer/PaneView.swift` (use pane.hoverPreview), `Sources/FileExplorer/ThumbnailGridView.swift` (generation coalescing), `Sources/FileExplorer/FileActionsMenu.swift` (Calculate Size gating), `Sources/FileExplorer/BatchRenameSheet.swift` (isNoOp)
- Extend: `Sources/FileExplorerTests/PaneStateTests.swift`

- [x] **Step 1: showHidden didSet (TDD).** Append to `paneStateTests()`: build a temp dir with a hidden file, start a pane, flip `pane.showHidden = true`, poll (≤2 s) until `pane.entries` contains the hidden file WITHOUT calling `reload()` manually; then flip back and poll for its disappearance. Red run. Implement in `PaneState`:

```swift
    public var showHidden = false {
        didSet {
            guard oldValue != showHidden, started else { return }
            Task { await reload() }
        }
    }
```

(`started` gate: the restore init sets showHidden before the pane ever loads — no wasted reload.) Then in `FileExplorerApp.swift`, simplify the toggle:

```swift
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { session.activePane.showHidden },
                    set: { session.activePane.showHidden = $0 }))
```

- [x] **Step 2: Hoist hoverModel.** `PaneState` gains:

```swift
    /// Hover-preview state; owned here because view structs are re-inited on
    /// every parent render on this toolchain (M5 deferred hoisting).
    public let hoverPreview = HoverPreviewModel()
```

`PaneView` deletes `private let hoverModel = HoverPreviewModel()` and uses `pane.hoverPreview` in the three call sites (onHover ×2, popover binding + content).

- [x] **Step 3: Generation coalescing.** In `ThumbnailStore`, replace the direct `generation += 1` in the request completion with a coalesced bump:

```swift
    @ObservationIgnored private var bumpScheduled = false

    private func scheduleGenerationBump() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            bumpScheduled = false
            generation += 1
        }
    }
```

(call `scheduleGenerationBump()` where `generation += 1` was). One re-render per 50 ms burst instead of one per thumbnail.

- [x] **Step 4: Menu nits.** `FileActionsMenu.swift` — Calculate Size only enabled when a directory is targeted:

```swift
        Button("Calculate Size") {
            Task { await pane.calculateFolderSizes(targets) }
        }
        .disabled(!targets.contains { url in
            pane.entries.first(where: { $0.url == url })?.isDirectory == true
        })
```

`BatchRenameSheet.swift` — wire the unused `RenameRules.isNoOp` into the Apply button's disabled condition (find the apply/confirm button; add `model.rules.isNoOp ||` to its existing disable expression). If the sheet already disables on `applicableCount == 0` and `isNoOp` is fully redundant with it, DELETE `isNoOp` from `RenameRules` instead and say so in the commit.

- [x] **Step 5: Build + full suite + commit** — `git commit -m "refactor: showHidden auto-reload, hoisted hover model, coalesced thumbnail re-renders, menu gating"`.

---

### Task 9: Verification sweep, completion notes, merge gate

- [x] **Step 1:** Full suite ×2 (`swift run FileExplorerTests`) — PASS both, record final count. `swift build -c release 2>&1 | tail -2` clean.
- [x] **Step 2:** Launch checks: plain launch alive >5 s; launch with `/tmp` arg alive; relaunch restores prior session (session.json now includes any custom ranges — verify it decodes by launching after setting a custom filter… settable only manually → list as MANUAL).
- [x] **Step 3:** Re-read the v2 spec's M8 section; each bullet has a test, a wired UI path, or a MANUAL entry. Fix real bugs found (`fix: … (milestone 8 verification)`).
- [x] **Step 4:** Append Completion Notes (final assertion count; bugs found; MANUAL list: modifier-click gestures, real drags in/out, quality submenu, custom-range popovers, mount/unmount refresh, ⌘W-last-tab window close, badge visuals). Mark all checkboxes.
- [ ] **Step 5:** Controller runs the final whole-branch review, then merges:

```bash
git checkout main && git merge --no-ff milestone-8-interaction-debt \
    -m "merge: milestone 8 — interaction debt (v2 complete)"
```

---

## Completion Notes (2026-07-08)

**Suite:** 462 assertions at the start of this task; unchanged after this task (no fixes were needed — recounted twice, both PASS 462). `swift build -c release` clean (only the pre-existing CLT linker search-path warnings). Launch checks: plain launch alive >5s; `swift run FileExplorer /tmp` alive >5s; both killed cleanly.

**Per-task summary (all committed + two-stage reviewed):**
- **Task 1** — Grid multi-select: `SelectionResolver` (Core) + `PaneState.clickSelect` wire ⌘-toggle and ⇧-range into `ThumbnailGridView`, matching table semantics.
- **Task 2** — Finder-parity drop: `DropDecision` (Core) decides move/copy from ⌥ + same-volume; `PaneView`'s `.dropDestination` routes through existing `FileOperationService`/undo.
- **Task 3** — Convert quality + output selection: `SettingsModel` persists `jpegQuality` via `SessionPersister`; Convert submenu gains JPG Quality presets 60/80/90/100; `convertSelected` selects its outputs.
- **Task 4** — Batch-rename A↔B swaps: `RenamePlan` gains vacated-name awareness; `RenameExecutor` two-phase (temp-name) execution enables swaps/cycles with rollback on phase-2 failure.
- **Task 5** — Direct-pane rename sheets: `RenameSheetModel`/`BatchRenameModel` carry a weak target pane so right-click-rename and batch-rename act on the pane they were opened from, not `session.activePane`.
- **Task 6** — Custom date/size filter ranges: `FilterState.customDateRange`/`customSizeRange` (optional, Codable-compatible with pre-M8 session.json) override presets in `FilterEngine`; `FilterBarView` gains popover editors.
- **Task 7** — Browse polish: symlink badges in table + grid; `VolumesModel` observes `NSWorkspace` mount/unmount and republishes the volume list; sidebar highlights the active pane's current location; ⌘W closes the window on the last tab.
- **Task 8** — Internal cleanups: `showHidden` auto-reloads via `didSet` (gated on `started`); `HoverPreviewModel` hoisted onto `PaneState`; `ThumbnailStore` coalesces generation bumps (one re-render per 50ms burst); Calculate Size disables when no target is a folder; `RenameRules.isNoOp` deleted as redundant with `BatchRenameSheet`'s existing `applicableCount == 0` gate.

**Review-driven fixes during the milestone:**
- `f449171` — shift-range pivot semantics: selection recomputes from a pivot so a shift-range can grow AND shrink; shift-click can also bootstrap an anchor.
- `55363e1` — swap-undo two-phase relocate fix: `UndoRecorder.recordMove` now restores swapped/cycled rename pairs via a single two-phase `RenameExecutor.relocate()` call instead of a pair-by-pair loop, avoiding spurious "already exists" failures.
- `5d645e0` — vacated-set fixpoint in `RenamePlan` + loud rollback-collision recovery in `RenameExecutor` (data-integrity Critical found by adversarial review, empirically reproduced).
- `3704dd1` — MB-field Int64 overflow clamp in the custom size-filter parser (Critical, crash reachable by pasting a huge number then applying the filter).

**Accepted minors/notes (no fix needed, or deliberately out of scope):**
- Grid shift-click deliberately diverges from the spec's literal "matching the Table's semantics": SwiftUI Table replaces the range on ⇧-click, while the grid unions from a pivot and can shrink — Finder's icon-view behavior (rationale documented in `SelectionResolver.swift`).
- `RenameExecutor.execute`/`relocate` share the recovery ladder but duplicate their staging loops (readability follow-up: `execute` could wrap `relocate`); the "vacated set" RenamePlan test carries leftover E/L/C scaffolding narration worth a cleanup pass.
- Both-MB-fields-empty leaves a `0...Int64.max` custom size range ("Custom" chip + Clear button visible) instead of reverting to nil/"Any Size" — filters correctly, cosmetic drift from the plan.
- Mixed-volume drops copy the whole batch (`PaneView`'s drop handler uses `allSatisfy` for same-volume — provably-safe simplification: any cross-volume item in the batch forces copy for all).
- No "Moved/Copied N items" success feedback in the status bar (follow-up; failures already surface there via `opErrorMessage`).
- `jpegQuality` default 0.85 matches no preset (60/80/90/100), so there's no initial checkmark in the JPG Quality submenu until the user picks one.
- The 0.85 default is duplicated across `PaneState.convertSelected`, `SessionPersister`'s `AppSettings` init/decoder, and `ImageConverter.convert` — no single source of truth, but each is independently clamped/correct.
- Batch-rename failure display truncates at 3 (`opErrorMessage`) — a `RenameExecutor` rollback-recovery message could be among the ones cut, though the file itself still lands at a visible "(restored)" name so no data is hidden, only the message.
- `relocate()`'s rollback-collision path has no dedicated undo-time test (only the execute-path collision is covered by `RenameExecutorTests`).
- Sheet-model pane bookkeeping (`RenameSheetModel`/`BatchRenameModel`'s weak `pane` wiring) is untestable from the `FileExplorerTests` harness — those types live in the `FileExplorer` executable target, which `Package.swift` doesn't link into the test target.
- `HoverPreviewModel`'s pending task self-cleans (~500ms) when a pane closes; no explicit cancellation was added since the existing self-cleanup already prevents a leak.

**Spec sweep (v2 spec, Milestone 8 section) — every bullet covered:**
- Convert quality / presets / persistence → `SettingsModel`, `FileActionsMenu`'s JPG Quality submenu, `SettingsModelTests`.
- Convert selects outputs → `PaneState.convertSelected` (line ~322), `PaneBatchToolsTests`.
- Rename swaps (A↔B, cycles) → `RenamePlan` vacated-name pass + `RenameExecutor` two-phase execution, `RenamePlanTests`/`RenameExecutorTests`.
- Direct-pane unification → `RenameSheetModel`/`BatchRenameModel` weak `pane`, `FileActionsMenu.present(...)` call sites.
- Grid multi-select → `SelectionResolver`/`PaneState.clickSelect`, wired in `ThumbnailGridView`, `SelectionResolverTests`.
- Drop into pane (Finder parity) → `DropDecision`, wired in `PaneView`'s `.dropDestination`, `DropDecisionTests`.
- Symlink badge → `PaneView` (table) and `ThumbnailGridView.ThumbnailCell` (grid), both checking `entry.isSymlink`.
- Volumes live refresh + sidebar highlight → `VolumesModel` (NSWorkspace observers) in `SidebarView.swift`, `SidebarView.row(_:)` `isCurrent` check.
- ⌘W on last tab → `FileExplorerApp`'s "Close Tab" now calls `NSApp.mainWindow?.performClose(nil)` when `session.tabs.count == 1` (fixed from `keyWindow` during Task 8 review so it works even with a sheet key).
- Custom date/size filter ranges → `FilterState.customDateRange`/`customSizeRange` (optional, backward-compatible), `FilterEngine.apply` override logic, `FilterBarView` popovers, `FilterEngineTests`/`SessionSnapshotTests`.
- Internal cleanups (showHidden didSet, hoverModel hoist, generation coalescing, isNoOp) → all confirmed present in `PaneState.swift`/`ThumbnailGridView.swift`/`FileActionsMenu.swift`, per Task 8 commit `224ab20`.

No gaps or bugs found during this sweep; no additional fixes were required.

**MANUAL walkthrough** (TCC blocks agent-driven UI automation — verify by hand before merge):

- [ ] ⌘-click and ⇧-click multi-select in the icon grid, including a shift-range that shrinks back after growing.
- [ ] Drag-drop move within a volume vs. ⌥-drag copy vs. cross-volume drop (defaults to copy).
- [ ] JPG Quality submenu: presets 60/80/90/100 show a checkmark on the active value and persist across relaunch.
- [ ] Custom date and size range popovers, including pasting a huge number into the size filter's MB field — should clamp, not crash.
- [ ] Symlink badges render correctly in both table and grid views.
- [ ] Volume mount/unmount live-refreshes the sidebar's volume list.
- [ ] Sidebar highlights the current location under both Favorites and Volumes.
- [ ] ⌘W closes the window when it's the last tab, including with a sheet open (mainWindow fix).
- [ ] Right-click → Rename on an INACTIVE pane renames in that pane, not the active one.
- [ ] Convert selects its output files and Quick Look refreshes to show them.
