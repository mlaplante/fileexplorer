# FileExplorer Milestone 10 (Search & Filters) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make search content-aware (⇧⌘F Spotlight palette with a deep-scan fallback), let filters be saved and recalled as named presets, and surface Finder tags as a display/assign/filter dimension.

**Architecture:** Tags become a first-class `FileEntry`/`FilterState` dimension (optional field → old session.json keeps decoding, matching the M8 custom-range pattern). Presets are `[FilterPreset]` on `AppSettings` managed through `SettingsModel`. Content search reuses the palette: `PaletteModel` gains a provider-driven mode (no local fuzzy rank), `SpotlightSearcher` (@MainActor NSMetadataQuery wrapper) supplies results, and a pure `ContentScanner` in Core is the unit-tested deep-scan fallback.

**Tech Stack:** Swift 6 SPM, CLT-only toolchain — **NO `@State`/`@FocusState`** (transient UI state on `@Observable` models, incl. popover flags on `PaneState`), no `xcodebuild`/`swift test`. Tests: `swift run FileExplorerTests` (522 assertions at start; counts are estimates — recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-10-search-filters`.

**Approved decisions (v3 spec + M9 execution learnings):**
- `FilterState.tags` is `Set<String>?` (nil = inactive) so synthesized Codable keeps decoding M7–M9 `session.json` files (same contract as `customDateRange`). Entry matches if it has ANY selected tag; folders always pass (engine convention).
- `FileEntry.tags` defaults to `[]` in the initializer so existing call sites and tests keep compiling.
- Preset apply order in the UI: set `pane.filter` FIRST, then `pane.filterExtensionsText` — the text field's `didSet` re-derives `filter.extensions`, keeping the draft field the source of truth (documented on `PaneState.init(snapshot:)`).
- Spotlight fallback signal (spec left it to implementation): when Spotlight returns **zero** results, the palette shows a "Deep Scan this folder…" action row that runs `ContentScanner`; Spotlight query errors auto-run the scanner. No indexing-state probing (`mdutil` shelling is not worth it for a personal tool).
- Content-search results are NOT fuzzy re-ranked (Spotlight/scanner relevance order is kept); `PaletteModel.ranksLocally = false` in this mode.
- Execution: Codex implements verbatim edits only; controller builds, tests, commits (see M9 completion notes / codex-sandbox-swift-spm-build-failure skill).

**File map:**
- Create: `Sources/FileExplorerCore/FilterPreset.swift`, `TagWriter.swift`, `ContentScanner.swift`, `SpotlightSearcher.swift`
- Create: `Sources/FileExplorer/TagDotsView.swift`
- Modify: `Sources/FileExplorerCore/FilterState.swift`, `FilterEngine.swift`, `FileEntry.swift`, `DirectoryLoader.swift`, `SessionPersister.swift` (AppSettings), `SettingsModel.swift`, `PaletteModel.swift`, `PaneState.swift` (popover flag + preset-name draft)
- Modify: `Sources/FileExplorer/FilterBarView.swift`, `SidebarView.swift`, `FileActionsMenu.swift`, `PaneView.swift`, `ThumbnailGridView.swift`, `PaletteCoordinator.swift`, `FileExplorerApp.swift`
- Create tests: `Sources/FileExplorerTests/TagFilterTests.swift`, `FilterPresetTests.swift`, `ContentScannerTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

---

### Task 1: Tag dimension in FilterState + FilterEngine (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/FilterState.swift`
- Modify: `Sources/FileExplorerCore/FilterEngine.swift`
- Create: `Sources/FileExplorerTests/TagFilterTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Branch**

```bash
cd /Users/mlaplante/Sites/fileexplorer
git checkout main && git checkout -b milestone-10-search-filters
```

- [ ] **Step 2: Failing tests — `Sources/FileExplorerTests/TagFilterTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func tagFilterTests() async {
    func entry(_ name: String, tags: [String] = [],
               isDirectory: Bool = false) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                  isDirectory: isDirectory, isHidden: false, isSymlink: false,
                  size: 1, created: nil, modified: Date(), contentType: nil,
                  tags: tags)
    }

    await test("tag filter keeps entries carrying any selected tag") {
        var filter = FilterState()
        filter.tags = ["Red", "Work"]
        let entries = [
            entry("red.txt", tags: ["Red"]),
            entry("work.txt", tags: ["Work", "Blue"]),
            entry("blue.txt", tags: ["Blue"]),
            entry("plain.txt"),
        ]
        let names = FilterEngine.apply(filter, to: entries).map(\.name)
        expectEqual(names, ["red.txt", "work.txt"], "any-of tag match")
    }

    await test("folders always pass the tag filter") {
        var filter = FilterState()
        filter.tags = ["Red"]
        let entries = [entry("folder", isDirectory: true), entry("file.txt")]
        let names = FilterEngine.apply(filter, to: entries).map(\.name)
        expectEqual(names, ["folder"], "folder passes, untagged file filtered")
    }

    await test("tags participate in isActive") {
        var filter = FilterState()
        expect(!filter.isActive, "empty filter inactive")
        filter.tags = ["Red"]
        expect(filter.isActive, "tag selection activates the filter")
    }

    await test("FilterState without tags key still decodes (forward compat)") {
        let old = #"{"extensions":["png"]}"#
        let decoded = try JSONDecoder().decode(
            FilterState.self, from: Data(old.utf8))
        expectEqual(decoded.extensions, ["png"], "old payload decodes")
        expect(decoded.tags == nil, "missing tags key → nil")

        var filter = FilterState()
        filter.tags = ["Red"]
        let data = try JSONEncoder().encode(filter)
        let roundTrip = try JSONDecoder().decode(FilterState.self, from: data)
        expectEqual(roundTrip, filter, "tags round-trip")
    }
}
```

- [ ] **Step 3: Register** — in `Sources/FileExplorerTests/main.swift`, add `await tagFilterTests()` after `await infoGathererTests()`.

- [ ] **Step 4: Run to verify failure** — `swift run FileExplorerTests 2>&1 | tail -5`; expect compile error (`tags` unknown).

- [ ] **Step 5: Implement — `Sources/FileExplorerCore/FilterState.swift`**

Add after `customSizeRange`:

```swift
    /// Finder-tag filter: entry passes if it carries ANY of these tags.
    /// OPTIONAL for the same forward-compat contract as the custom ranges:
    /// synthesized Codable decodes a missing key as nil, so session.json
    /// files written before M10 keep loading.
    public var tags: Set<String>?
```

Extend `isActive`:

```swift
    public var isActive: Bool {
        preset != nil || !extensions.isEmpty || datePreset != nil
            || sizePreset != nil || customDateRange != nil || customSizeRange != nil
            || tags != nil
    }
```

- [ ] **Step 6: Implement — `Sources/FileExplorerCore/FilterEngine.swift`**

Add before the final `return true` inside the filter closure:

```swift
            if let tags = filter.tags,
               entry.tags.allSatisfy({ !tags.contains($0) }) {
                return false
            }
```

(Note: this also needs Task 2's `FileEntry.tags` to compile. Tasks 1 and 2 are committed together in Task 2's commit if the suite can't go green in between — preferred order: apply Task 1 and Task 2 code, then run the suite once. The test file above already constructs `FileEntry(... tags:)`.)

- [ ] **Step 7: Proceed to Task 2 before running the suite** (FileEntry.tags is required to compile).

### Task 2: FileEntry.tags + DirectoryLoader + TagWriter (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/FileEntry.swift`
- Modify: `Sources/FileExplorerCore/DirectoryLoader.swift`
- Create: `Sources/FileExplorerCore/TagWriter.swift`
- Modify: `Sources/FileExplorerTests/TagFilterTests.swift` (append tests)
- Test file already registered.

- [ ] **Step 1: Append to `TagFilterTests.swift`** (inside `tagFilterTests()`, after the last test):

```swift
    await test("TagWriter round-trips through DirectoryLoader") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tagged.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        guard case .success = TagWriter.setTags(["Red", "Work"], on: file) else {
            return expect(false, "setTags succeeds")
        }
        let loaded = try DirectoryLoader.load(dir, includeHidden: false)
        expectEqual(loaded.first?.tags.sorted(), ["Red", "Work"],
                    "tags read back by the loader")

        guard case .success = TagWriter.setTags([], on: file) else {
            return expect(false, "clearing tags succeeds")
        }
        let cleared = try DirectoryLoader.load(dir, includeHidden: false)
        expectEqual(cleared.first?.tags ?? ["sentinel"], [],
                    "tags cleared")
    }
```

- [ ] **Step 2: Implement — `Sources/FileExplorerCore/FileEntry.swift`**

Add the stored property after `contentType`:

```swift
    /// Finder tag names (com.apple.metadata:_kMDItemUserTags), empty when none.
    public let tags: [String]
```

Change the initializer signature to (default keeps every existing call site compiling):

```swift
    public init(url: URL, name: String, isDirectory: Bool, isHidden: Bool,
                isSymlink: Bool, size: Int64, created: Date?, modified: Date,
                contentType: UTType?, tags: [String] = []) {
```

and add `self.tags = tags` in the body.

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/DirectoryLoader.swift`**

Add `.tagNamesKey` to `resourceKeys`:

```swift
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .contentTypeKey, .tagNamesKey,
    ]
```

and pass tags in the `FileEntry` construction:

```swift
                contentType: rv.contentType,
                tags: rv.tagNames ?? [])
```

- [ ] **Step 4: Implement — `Sources/FileExplorerCore/TagWriter.swift`**

**Implementation-time discovery:** `URLResourceValues.tagNames`'s SETTER is
`@available(macOS 26, *)` — it fails the macOS 15 deployment target. Write the
underlying xattr directly in Finder's own format instead (works everywhere,
Finder renders the colors):

```swift
import Foundation

/// Writes Finder tags. Blocking (tiny xattr write); callable from any actor.
/// Read-only volumes surface the underlying error.
///
/// `URLResourceValues.tagNames` only became SETTABLE in macOS 26, so with a
/// macOS 15 deployment target we write the underlying xattr directly in
/// Finder's own format: a binary plist array of "Name\nColorIndex" strings.
/// Reading back via the `.tagNamesKey` resource value (DirectoryLoader)
/// returns plain names — the color suffix is the xattr encoding, not part
/// of the tag name.
public enum TagWriter {
    private static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    /// Finder's color indices for the standard label names; unknown tags get
    /// 0 (no color) and render as gray dots.
    private static let colorIndex: [String: Int] = [
        "Gray": 1, "Grey": 1, "Green": 2, "Purple": 3, "Blue": 4,
        "Yellow": 5, "Red": 6, "Orange": 7,
    ]

    public static func setTags(_ tags: [String], on url: URL)
        -> Result<Void, FileOperationService.FileOpError> {
        do {
            if tags.isEmpty {
                // Removing a never-set attribute is success, not an error.
                if removexattr(url.path, xattrName, 0) != 0, errno != ENOATTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return .success(())
            }
            let payload = tags.map { "\($0)\n\(colorIndex[$0] ?? 0)" }
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload, format: .binary, options: 0)
            let status = data.withUnsafeBytes {
                setxattr(url.path, xattrName, $0.baseAddress, $0.count, 0, 0)
            }
            guard status == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return .success(())
        } catch {
            return .failure(.init(error))
        }
    }

    /// Toggle semantics for the context submenu: if EVERY target already has
    /// the tag, remove it from all; otherwise add it to all. Pure.
    public static func toggledTags(current: [String], tag: String,
                                   removing: Bool) -> [String] {
        removing ? current.filter { $0 != tag }
                 : current.contains(tag) ? current : current + [tag]
    }
}
```

- [ ] **Step 5: Run the suite** — `swift run FileExplorerTests 2>&1 | tail -3`; expect `PASS` (Tasks 1+2 compile together).

- [ ] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore/FilterState.swift Sources/FileExplorerCore/FilterEngine.swift \
        Sources/FileExplorerCore/FileEntry.swift Sources/FileExplorerCore/DirectoryLoader.swift \
        Sources/FileExplorerCore/TagWriter.swift Sources/FileExplorerTests/TagFilterTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: Finder tags as a FileEntry and filter dimension"
```

### Task 3: Tag UI — dots, context submenu, filter-bar menu

**Files:**
- Create: `Sources/FileExplorer/TagDotsView.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`, `ThumbnailGridView.swift`, `FileActionsMenu.swift`, `FilterBarView.swift`

Menu/badge glue over Task 2's logic; manual-walkthrough verification. Build must stay green.

- [ ] **Step 1: Create `Sources/FileExplorer/TagDotsView.swift`**

```swift
import SwiftUI
import FileExplorerCore

/// Finder-style colored tag dots. Standard label names map to their colors;
/// unknown tags render gray. Dots overlap slightly like Finder's.
struct TagDotsView: View {
    let tags: [String]

    static func color(for tag: String) -> Color {
        switch tag {
        case "Red": .red
        case "Orange": .orange
        case "Yellow": .yellow
        case "Green": .green
        case "Blue": .blue
        case "Purple": .purple
        case "Gray", "Grey": .gray
        default: .gray
        }
    }

    var body: some View {
        HStack(spacing: -3) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                Circle()
                    .fill(Self.color(for: tag))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1))
            }
        }
        .help(tags.joined(separator: ", "))
    }
}
```

- [ ] **Step 2: Table row — `Sources/FileExplorer/PaneView.swift`**

In the Name `TableColumn`'s `HStack`, after the `isSymlink` badge `if` block (still inside the HStack):

```swift
                    if !entry.tags.isEmpty {
                        TagDotsView(tags: entry.tags)
                    }
```

- [ ] **Step 3: Grid cell — `Sources/FileExplorer/ThumbnailGridView.swift`**

In `ThumbnailCell`, add a second overlay on the thumbnail `Group` (after the existing `.overlay(alignment: .bottomLeading)` block):

```swift
            .overlay(alignment: .bottomTrailing) {
                if !entry.tags.isEmpty {
                    TagDotsView(tags: entry.tags)
                        .padding(2)
                }
            }
```

- [ ] **Step 4: Tags context submenu — `Sources/FileExplorer/FileActionsMenu.swift`**

After the "Copy Path" `Menu` block (before the Divider that follows it), add:

```swift
        Menu("Tags") {
            let selectedEntries = pane.entries.filter { targets.contains($0.url) }
            let visibleTags = Set(pane.entries.flatMap(\.tags))
            let standardLabels = NSWorkspace.shared.fileLabels
                .filter { $0 != "None" }
            let allTags = Array(Set(standardLabels).union(visibleTags)).sorted()
            ForEach(allTags, id: \.self) { tag in
                let allHave = !selectedEntries.isEmpty
                    && selectedEntries.allSatisfy { $0.tags.contains(tag) }
                Toggle(isOn: Binding(
                    get: { allHave },
                    set: { _ in
                        Task { await applyTagToggle(tag, removing: allHave,
                                                    entries: selectedEntries) }
                    })) {
                    Label(tag, systemImage: "circle.fill")
                }
            }
            Divider()
            Button("New Tag…") {
                pane.newTagDraft = ""
                pane.showsNewTagPopover = true
            }
        }
        .disabled(targets.isEmpty)
```

The "New Tag…" free-text entry (spec requirement) uses the house popover pattern. Add to `Sources/FileExplorerCore/PaneState.swift`, next to the other transient popover flags:

```swift
    /// Transient new-tag popover state (context submenu → free-text entry;
    /// deliberately NOT read by snapshot()).
    public var showsNewTagPopover = false
    public var newTagDraft = ""
```

And in `Sources/FileExplorer/PaneView.swift`, attach the popover to the `Group` that hosts the table/grid (after the `.onKeyPress` modifiers), so it works in both view modes:

```swift
            .popover(isPresented: Binding(
                get: { pane.showsNewTagPopover },
                set: { pane.showsNewTagPopover = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("New tag name", text: Binding(
                        get: { pane.newTagDraft },
                        set: { pane.newTagDraft = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button("Add Tag to Selection") {
                        let tag = pane.newTagDraft
                            .trimmingCharacters(in: .whitespaces)
                        let targets = pane.entries.filter {
                            pane.selection.contains($0.url)
                        }
                        pane.showsNewTagPopover = false
                        guard !tag.isEmpty, !targets.isEmpty else { return }
                        Task {
                            for entry in targets {
                                _ = TagWriter.setTags(
                                    TagWriter.toggledTags(current: entry.tags,
                                                          tag: tag, removing: false),
                                    on: entry.url)
                            }
                            await pane.reload()
                        }
                    }
                    .disabled(pane.newTagDraft
                        .trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
```

And add this private method at the bottom of the `FileActions` struct (next to `appDisplayName`/`openWith`):

```swift
    private func applyTagToggle(_ tag: String, removing: Bool,
                                entries: [FileEntry]) async {
        var failures: [String] = []
        for entry in entries {
            let newTags = TagWriter.toggledTags(current: entry.tags, tag: tag,
                                                removing: removing)
            if case .failure(let error) = TagWriter.setTags(newTags, on: entry.url) {
                failures.append(error.message)
            }
        }
        await pane.reload()
        if !failures.isEmpty {
            pane.reportTagFailure(failures.prefix(3).joined(separator: " ")
                + (failures.count > 3 ? " (+\(failures.count - 3) more)" : ""))
        }
    }
```

This needs a tiny `PaneState` accessor (the op-error channel setter is private). In `Sources/FileExplorerCore/PaneState.swift`, next to `reportOpFailure`:

```swift
    /// Same channel, callable from the app layer's tag submenu (tag writes
    /// happen outside PaneState's own operation wrappers).
    public func reportTagFailure(_ message: String) {
        opErrorMessage = message
    }
```

- [ ] **Step 5: Filter-bar Tags menu — `Sources/FileExplorer/FilterBarView.swift`**

After the size `Menu`'s `.popover` block and before the extensions `TextField`, add:

```swift
            Menu {
                Button("Any Tags") { pane.filter.tags = nil }
                Divider()
                ForEach(Array(Set(pane.entries.flatMap(\.tags))).sorted(),
                        id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { pane.filter.tags?.contains(tag) == true },
                        set: { isOn in
                            var tags = pane.filter.tags ?? []
                            if isOn { tags.insert(tag) } else { tags.remove(tag) }
                            pane.filter.tags = tags.isEmpty ? nil : tags
                        }))
                }
            } label: {
                Label(pane.filter.tags.map { "\($0.count) Tag\($0.count == 1 ? "" : "s")" }
                          ?? "Tags",
                      systemImage: "tag")
            }
            .controlSize(.small)
            .fixedSize()
```

- [ ] **Step 6: Build + suite** — `swift build 2>&1 | tail -1 && swift run FileExplorerTests 2>&1 | tail -1`; expect clean, `PASS`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FileExplorer/TagDotsView.swift Sources/FileExplorer/PaneView.swift \
        Sources/FileExplorer/ThumbnailGridView.swift Sources/FileExplorer/FileActionsMenu.swift \
        Sources/FileExplorer/FilterBarView.swift Sources/FileExplorerCore/PaneState.swift
git commit -m "feat: tag dots, assign submenu, and tag filter menu"
```

### Task 4: FilterPreset + AppSettings + SettingsModel (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/FilterPreset.swift`
- Modify: `Sources/FileExplorerCore/SessionPersister.swift` (AppSettings), `SettingsModel.swift`
- Create: `Sources/FileExplorerTests/FilterPresetTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/FilterPresetTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func filterPresetTests() async {
    func makePersister() throws -> SessionPersister {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionPersister(directory: dir)
    }

    await test("AppSettings without filterPresets key still decodes") {
        let old = #"{"jpegQuality":0.9}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        expectEqual(decoded.jpegQuality, 0.9, "old field intact")
        expect(decoded.filterPresets.isEmpty, "missing key → empty list")
    }

    await test("filter presets round-trip through the persister") {
        let persister = try makePersister()
        defer { try? FileManager.default.removeItem(at: persister.directory) }
        var filter = FilterState()
        filter.preset = .images
        filter.tags = ["Work"]
        var settings = AppSettings()
        settings.filterPresets = [FilterPreset(name: "Work Images", filter: filter)]
        persister.saveSettings(settings)
        let loaded = persister.loadSettings()
        expectEqual(loaded.filterPresets, settings.filterPresets, "round-trip")
    }

    await test("SettingsModel saves, replaces, and deletes presets") {
        let persister = try makePersister()
        defer { try? FileManager.default.removeItem(at: persister.directory) }
        let model = SettingsModel(persister: persister)

        var imagesFilter = FilterState()
        imagesFilter.preset = .images
        model.savePreset(name: "Pics", filter: imagesFilter)
        expectEqual(model.settings.filterPresets.map(\.name), ["Pics"], "saved")

        var pdfFilter = FilterState()
        pdfFilter.preset = .pdfs
        model.savePreset(name: "Pics", filter: pdfFilter)
        expectEqual(model.settings.filterPresets.count, 1, "same name replaces")
        expectEqual(model.settings.filterPresets.first?.filter.preset, .pdfs,
                    "replacement took")

        // Persisted immediately (house rule: settings are tiny, save on write).
        let reloaded = SettingsModel(persister: persister)
        expectEqual(reloaded.settings.filterPresets.map(\.name), ["Pics"],
                    "persisted across model instances")

        model.deletePreset(name: "Pics")
        expect(model.settings.filterPresets.isEmpty, "deleted")
    }
}
```

- [ ] **Step 2: Register** — add `await filterPresetTests()` after `await tagFilterTests()` in `main.swift`.

- [ ] **Step 3: Run to verify failure** — expect compile errors.

- [ ] **Step 4: Implement — `Sources/FileExplorerCore/FilterPreset.swift`**

```swift
import Foundation

/// A named, recallable FilterState. Identity is the name: saving under an
/// existing name replaces that preset.
public struct FilterPreset: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var filter: FilterState

    public var id: String { name }

    public init(name: String, filter: FilterState) {
        self.name = name
        self.filter = filter
    }
}
```

- [ ] **Step 5: Implement — `AppSettings` in `Sources/FileExplorerCore/SessionPersister.swift`**

Replace the `AppSettings` struct with:

```swift
/// App-wide preferences persisted as `settings.json`. Every field decodes
/// with a default so files written by any version keep loading.
public struct AppSettings: Codable, Equatable, Sendable {
    public var jpegQuality: Double
    public var filterPresets: [FilterPreset]

    public init(jpegQuality: Double = 0.85, filterPresets: [FilterPreset] = []) {
        self.jpegQuality = min(max(jpegQuality, 0.1), 1.0)
        self.filterPresets = filterPresets
    }

    enum CodingKeys: String, CodingKey { case jpegQuality, filterPresets }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.85
        jpegQuality = min(max(raw, 0.1), 1.0)
        filterPresets = try container.decodeIfPresent(
            [FilterPreset].self, forKey: .filterPresets) ?? []
    }
}
```

- [ ] **Step 6: Implement — `Sources/FileExplorerCore/SettingsModel.swift`**

Add after `setJPEGQuality`:

```swift
    /// Saving under an existing name replaces that preset (name = identity).
    public func savePreset(name: String, filter: FilterState) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.filterPresets.removeAll { $0.name == trimmed }
        settings.filterPresets.append(FilterPreset(name: trimmed, filter: filter))
        persister.saveSettings(settings)
    }

    public func deletePreset(name: String) {
        settings.filterPresets.removeAll { $0.name == name }
        persister.saveSettings(settings)
    }
```

- [ ] **Step 7: Run suite** — expect `PASS`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FileExplorerCore/FilterPreset.swift Sources/FileExplorerCore/SessionPersister.swift \
        Sources/FileExplorerCore/SettingsModel.swift Sources/FileExplorerTests/FilterPresetTests.swift \
        Sources/FileExplorerTests/main.swift
git commit -m "feat: named filter presets persisted in settings"
```

### Task 5: Preset UI — save popover, sidebar section, palette commands

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift` (two transient fields)
- Modify: `Sources/FileExplorer/FilterBarView.swift`, `SidebarView.swift`, `PaletteCoordinator.swift`, `FileExplorerApp.swift`

- [ ] **Step 1: PaneState transient popover state** — in `Sources/FileExplorerCore/PaneState.swift`, next to the existing popover flags:

```swift
    /// Transient save-preset popover state (no @State on this toolchain;
    /// deliberately NOT read by snapshot()).
    public var showsSavePresetPopover = false
    public var savePresetNameDraft = ""
```

- [ ] **Step 2: Save Preset button — `Sources/FileExplorer/FilterBarView.swift`**

`FilterBarView` needs the settings model. Change the struct header to:

```swift
struct FilterBarView: View {
    @Bindable var pane: PaneState
    var settings: SettingsModel
```

(then update its call site — find with `rg -n "FilterBarView(" Sources/FileExplorer` — passing the `settings` that view already receives; `TabContentView` in `PaneView.swift` already has `settings`.)

Inside the trailing `if pane.filter.isActive` block, before the Clear button:

```swift
                Button("Save Preset…") {
                    pane.savePresetNameDraft = ""
                    pane.showsSavePresetPopover = true
                }
                .controlSize(.small)
                .popover(isPresented: Binding(
                    get: { pane.showsSavePresetPopover },
                    set: { pane.showsSavePresetPopover = $0 })) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Preset name", text: Binding(
                            get: { pane.savePresetNameDraft },
                            set: { pane.savePresetNameDraft = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Button("Save") {
                            settings.savePreset(name: pane.savePresetNameDraft,
                                                filter: pane.filter)
                            pane.showsSavePresetPopover = false
                        }
                        .disabled(pane.savePresetNameDraft
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(12)
                }
```

- [ ] **Step 3: Sidebar Presets section — `Sources/FileExplorer/SidebarView.swift`**

`SidebarView` gains the settings model:

```swift
struct SidebarView: View {
    @Bindable var session: SessionState
    var volumesModel: VolumesModel
    var settings: SettingsModel
```

(update the call site in `FileExplorerApp.swift`: `SidebarView(session: session, volumesModel: volumesModel, settings: settings)`.)

Add after the Volumes section:

```swift
            if !settings.settings.filterPresets.isEmpty {
                Section("Presets") {
                    ForEach(settings.settings.filterPresets) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            Label(preset.name, systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Preset") {
                                settings.deletePreset(name: preset.name)
                            }
                        }
                    }
                }
            }
```

And this private method below `row(_:)`:

```swift
    /// Order matters: filter first, then the extensions draft text — the
    /// text field's didSet re-derives filter.extensions (source of truth,
    /// same convention as PaneState.init(snapshot:)).
    private func apply(_ preset: FilterPreset) {
        let pane = session.activePane
        pane.filter = preset.filter
        pane.filterExtensionsText = preset.filter.extensions.sorted()
            .joined(separator: ", ")
    }
```

- [ ] **Step 4: Palette commands — `Sources/FileExplorer/PaletteCoordinator.swift`**

Thread settings through the commands registry. Change the two signatures:

```swift
    static func openCommands(_ palette: PaletteModel, session: SessionState,
                             settings: SettingsModel) {
        palette.present(mode: .commands)
        palette.setItems(commands(for: session, settings: settings).map {
            PaletteItem(id: $0.id, title: $0.name, subtitle: $0.shortcut)
        })
    }
```

`confirm` gains the parameter and passes it through:

```swift
    static func confirm(_ item: PaletteItem, palette: PaletteModel,
                        session: SessionState, settings: SettingsModel) {
```

and in its `.commands` case: `commands(for: session, settings: settings)`.

`commands(for:)` becomes `commands(for session: SessionState, settings: SettingsModel)` and appends after the existing entries:

```swift
        + settings.settings.filterPresets.map { preset in
            AppCommand(id: "preset:\(preset.name)",
                       name: "Apply Preset: \(preset.name)", shortcut: "") {
                let pane = session.activePane
                pane.filter = preset.filter
                pane.filterExtensionsText = preset.filter.extensions.sorted()
                    .joined(separator: ", ")
            }
        }
```

(Concretely: wrap the existing array literal in parentheses and append with `+`.)

Update the call sites in `FileExplorerApp.swift`: the Command Palette button becomes `PaletteCoordinator.openCommands(palette, session: session, settings: settings)`, and the overlay's confirm closure becomes `PaletteCoordinator.confirm(item, palette: palette, session: session, settings: settings)`.

- [ ] **Step 5: Build + suite** — expect clean, `PASS`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore/PaneState.swift Sources/FileExplorer/FilterBarView.swift \
        Sources/FileExplorer/PaneView.swift Sources/FileExplorer/SidebarView.swift \
        Sources/FileExplorer/PaletteCoordinator.swift Sources/FileExplorer/FileExplorerApp.swift
git commit -m "feat: save/apply/delete filter presets from filter bar, sidebar, palette"
```

(If `PaneView.swift` wasn't touched because `FilterBarView`'s call site lives elsewhere, adjust the `git add` list to the files actually modified.)

### Task 6: ContentScanner (pure deep-scan fallback, TDD)

**Files:**
- Create: `Sources/FileExplorerCore/ContentScanner.swift`
- Create: `Sources/FileExplorerTests/ContentScannerTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Failing tests — `Sources/FileExplorerTests/ContentScannerTests.swift`**

```swift
import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func contentScannerTests() async {
    await test("isTextLike gates by type and extension") {
        expect(ContentScanner.isTextLike(UTType.plainText, pathExtension: "txt"),
               "plain text passes")
        expect(ContentScanner.isTextLike(UTType.swiftSource, pathExtension: "swift"),
               "source code passes")
        expect(ContentScanner.isTextLike(UTType.json, pathExtension: "json"),
               "json passes")
        expect(!ContentScanner.isTextLike(UTType.jpeg, pathExtension: "jpg"),
               "images rejected")
        expect(ContentScanner.isTextLike(nil, pathExtension: "md"),
               "unknown type falls back to known text extension")
        expect(!ContentScanner.isTextLike(nil, pathExtension: "bin"),
               "unknown type + unknown extension rejected")
    }

    await test("scan finds case-insensitive substring matches in text files") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "The NEEDLE is here".write(
            to: dir.appendingPathComponent("hit.txt"), atomically: true, encoding: .utf8)
        try "nothing to see".write(
            to: dir.appendingPathComponent("miss.txt"), atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "needle again".write(
            to: sub.appendingPathComponent("nested.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("skip.jpg"))

        let hits = ContentScanner.scan(root: dir, query: "needle")
        let names = Set(hits.map(\.lastPathComponent))
        expectEqual(names, ["hit.txt", "nested.md"], "case-insensitive, recursive")
    }

    await test("scan respects the per-file size cap") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-scancap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "x", count: 4096) + "needle"
        try big.write(to: dir.appendingPathComponent("big.txt"),
                      atomically: true, encoding: .utf8)
        let capped = ContentScanner.scan(root: dir, query: "needle",
                                         maxFileBytes: 1024)
        expect(capped.isEmpty, "oversized file skipped")
        let uncapped = ContentScanner.scan(root: dir, query: "needle")
        expectEqual(uncapped.count, 1, "default cap admits the file")
    }

    await test("empty query matches nothing") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-scanempty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "content".write(to: dir.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        expect(ContentScanner.scan(root: dir, query: "  ").isEmpty,
               "blank query → no results")
    }
}
```

- [ ] **Step 2: Register** — add `await contentScannerTests()` after `await filterPresetTests()`.

- [ ] **Step 3: Run to verify failure**, then **Step 4: Implement — `Sources/FileExplorerCore/ContentScanner.swift`**

```swift
import Foundation
import UniformTypeIdentifiers

/// Deep-scan fallback for content search: streams text-like files under a
/// root through a case-insensitive substring match. Blocking — call off the
/// main actor. Bounded by entry cap and per-file size cap so a runaway tree
/// can't hang the scan.
public enum ContentScanner {
    /// Extensions treated as text when the UTType is unknown.
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "yml", "yaml", "csv",
        "swift", "js", "ts", "py", "rb", "sh", "zsh", "c", "h", "m",
        "cpp", "hpp", "css", "html", "htm", "plist", "log", "cfg",
        "conf", "ini", "toml", "sql",
    ]

    public static func isTextLike(_ type: UTType?, pathExtension: String) -> Bool {
        if let type {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode)
                || type.conforms(to: .json) || type.conforms(to: .xml)
                || type.conforms(to: .propertyList) || type.conforms(to: .yaml) {
                return true
            }
            // A concrete non-text type (image, video, archive…) is rejected
            // even if its extension looks texty.
            if !type.conforms(to: .data) || type.conforms(to: .image)
                || type.conforms(to: .audiovisualContent)
                || type.conforms(to: .archive) {
                return false
            }
        }
        return textExtensions.contains(pathExtension.lowercased())
    }

    /// Recursive scan of `root` (hidden files and package internals skipped).
    /// Returns files whose contents contain `query`, case-insensitively.
    public static func scan(root: URL, query: String,
                            maxFileBytes: Int64 = 2 * 1_048_576,
                            entryCap: Int = 50_000,
                            resultCap: Int = 200) -> [URL] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var hits: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > entryCap || hits.count >= resultCap { break }
            guard let rv = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey]),
                rv.isDirectory != true,
                Int64(rv.fileSize ?? 0) <= maxFileBytes,
                isTextLike(rv.contentType, pathExtension: url.pathExtension)
            else { continue }
            guard let contents = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            else { continue }
            if contents.lowercased().contains(needle) {
                hits.append(url)
            }
        }
        return hits
    }
}
```

- [ ] **Step 5: Run suite** — expect `PASS`. (If `UTType.yaml` fails to compile on this SDK, drop the `.yaml` conformance clause — the extension list covers yml/yaml.)

- [ ] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore/ContentScanner.swift \
        Sources/FileExplorerTests/ContentScannerTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: ContentScanner deep-scan fallback with text gate and caps"
```

### Task 7: Spotlight search + contents palette mode (⇧⌘F)

**Files:**
- Create: `Sources/FileExplorerCore/SpotlightSearcher.swift`
- Modify: `Sources/FileExplorerCore/PaletteModel.swift`
- Modify: `Sources/FileExplorer/PaletteCoordinator.swift`, `FileExplorerApp.swift`

- [ ] **Step 1: PaletteModel provider mode — `Sources/FileExplorerCore/PaletteModel.swift`**

Add a case to `Mode`:

```swift
        case contents = "Search File Contents"
```

Add after `selectedIndex`:

```swift
    /// When false (contents mode), typing does not fuzzy-rank preloaded
    /// items; instead each query edit invokes `onQueryChange` and results
    /// arrive via setItems in provider order.
    public private(set) var ranksLocally = true
    @ObservationIgnored public var onQueryChange: (@MainActor (String, Int) -> Void)?
```

In `present(mode:)`, after `self.mode = mode`, add:

```swift
        ranksLocally = mode != .contents
```

In `dismiss()`, add `onQueryChange = nil`.

Change `query`'s `didSet` to:

```swift
    public var query = "" {
        didSet {
            if ranksLocally {
                rerank()
            } else {
                onQueryChange?(query, presentToken)
            }
        }
    }
```

And in `setItems`, replace the final `rerank()` with:

```swift
        if ranksLocally {
            rerank()
        } else {
            results = Array(items.prefix(Self.maxResults))
            selectedIndex = 0
        }
```

In `present(mode:)`, contents mode starts idle rather than loading — change `isLoading = true` to:

```swift
        isLoading = mode != .contents
```

- [ ] **Step 2: Create `Sources/FileExplorerCore/SpotlightSearcher.swift`**

```swift
import Foundation

/// One-shot NSMetadataQuery wrapper for content search, scoped to a folder.
/// NSMetadataQuery needs the main run loop, hence @MainActor. Starting a new
/// search cancels the previous one. Completion always runs on the main actor.
@MainActor
public final class SpotlightSearcher {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    public init() {}

    public func search(term: String, in folder: URL,
                       completion: @escaping @MainActor ([URL]) -> Void) {
        cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@",
                                      trimmed)
        query.searchScopes = [folder]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Read the query back through self: capturing the local
                // NSMetadataQuery (non-Sendable) in this @Sendable closure
                // trips Swift 6 region isolation; the @MainActor class is
                // Sendable, so hopping through it is legal and equivalent
                // (cancel() replaced/cleared it iff a newer search started,
                // in which case this stale gather must be dropped anyway).
                guard let self, let query = self.query else { return }
                query.disableUpdates()
                let urls = (0..<query.resultCount).compactMap { index -> URL? in
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(
                              forAttribute: NSMetadataItemPathKey) as? String
                    else { return nil }
                    return URL(fileURLWithPath: path)
                }
                self.cancel()
                completion(urls)
            }
        }
        self.query = query
        query.start()
    }

    public func cancel() {
        query?.stop()
        query = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
```

- [ ] **Step 3: Coordinator wiring — `Sources/FileExplorer/PaletteCoordinator.swift`**

Add a shared searcher and debounce task at the top of the enum:

```swift
    /// Content-search machinery: one searcher app-wide (a new palette
    /// presentation cancels the previous query), debounce so we don't fire
    /// a Spotlight query per keystroke.
    private static let spotlight = SpotlightSearcher()
    private static var debounce: Task<Void, Never>?
```

Add the open function (next to `openFiles`):

```swift
    static func openContents(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .contents)
        let pane = session.activePane
        palette.targetPane = pane
        let scope = pane.currentURL
        palette.onQueryChange = { term, token in
            debounce?.cancel()
            debounce = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, token == palette.presentToken else { return }
                spotlight.search(term: term, in: scope) { urls in
                    guard token == palette.presentToken else { return }
                    var items = urls.prefix(PaletteModel.maxResults).map {
                        PaletteItem(id: $0.path, title: $0.lastPathComponent,
                                    subtitle: abbreviate($0.deletingLastPathComponent()))
                    }
                    if items.isEmpty, !term.trimmingCharacters(in: .whitespaces).isEmpty {
                        items = [PaletteItem(
                            id: deepScanID,
                            title: "Deep Scan this folder…",
                            subtitle: "Spotlight found nothing — read text files directly")]
                    }
                    palette.setItems(Array(items), token: token)
                }
            }
        }
    }

    private static let deepScanID = "__deep_scan__"

    private static func runDeepScan(_ palette: PaletteModel, pane: PaneState) {
        let token = palette.presentToken
        let scope = pane.currentURL
        let term = palette.query
        Task.detached(priority: .userInitiated) {
            let urls = ContentScanner.scan(root: scope, query: term)
            let items = urls.map {
                PaletteItem(id: $0.path, title: $0.lastPathComponent,
                            subtitle: abbreviate($0.deletingLastPathComponent()))
            }
            await palette.setItems(items, token: token)
        }
    }
```

In `confirm`, the `.files` case currently handles navigate+select; contents mode needs the same behavior plus the deep-scan row. Replace the `switch mode` with:

```swift
        switch mode {
        case .folders:
            let url = URL(fileURLWithPath: item.id)
            Task { await pane.navigate(to: url) }
        case .files, .contents:
            if item.id == deepScanID {
                // Re-present is not needed: keep the palette open and swap in
                // scanner results under the same token.
                palette.undismiss()
                runDeepScan(palette, pane: pane)
                return
            }
            let url = URL(fileURLWithPath: item.id)
            Task {
                await pane.navigate(to: url.deletingLastPathComponent())
                pane.selection = [url.standardizedFileURL]
            }
        case .commands:
            commands(for: session, settings: settings).first { $0.id == item.id }?.action()
        }
```

`confirm` calls `palette.dismiss()` before the switch; the deep-scan row must survive that. Add to `PaletteModel`:

```swift
    /// Re-opens the palette after a confirm that turned out to be an
    /// in-palette action (deep scan). Keeps token, mode, and query.
    public func undismiss() {
        isPresented = true
        isLoading = true
    }
```

(Note `targetPane` was already captured into `pane` before dismiss in `confirm`, and `runDeepScan` receives it explicitly, so the weak-clear in `dismiss()` is harmless. `onQueryChange` was also cleared by dismiss — acceptable: after a deep scan the query field is read-only in effect; editing the query again after undismiss re-fires nothing until the palette is reopened. Record this as a known minor in the walkthrough: to refine a deep-scanned query, close and reopen ⇧⌘F.)

- [ ] **Step 4: ⇧⌘F command + palette entry — `Sources/FileExplorer/FileExplorerApp.swift`**

In the `CommandMenu("Go")`, after the "Find File…" button:

```swift
                Button("Search File Contents…") {
                    PaletteCoordinator.openContents(palette, session: session)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
```

Do NOT add a palette-commands registry entry for content search: the registry has no palette reference, and the other palette modes (⌘G/⌘P) are deliberately absent from it too. The Go-menu button + ⇧⌘F is the complete surface for this feature.

- [ ] **Step 5: Build + suite** — expect clean, `PASS`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore/SpotlightSearcher.swift Sources/FileExplorerCore/PaletteModel.swift \
        Sources/FileExplorer/PaletteCoordinator.swift Sources/FileExplorer/FileExplorerApp.swift
git commit -m "feat: content search palette (⇧⌘F) with Spotlight and deep-scan fallback"
```

### Task 8: README, full pass, manual walkthrough, completion notes

**Files:**
- Modify: `README.md`
- Modify: this plan (check boxes, completion notes)

- [ ] **Step 1: README** — add to the shortcut table after the ⌘P row:

```markdown
| ⇧⌘F | Search file contents (palette) |
```

and extend the intro's feature list: change "fuzzy palettes for navigation and commands" to "fuzzy palettes for navigation, commands, and file-content search", and append ", saved filter presets, and Finder tags" after "previews".

- [ ] **Step 2: Full pass** — `swift build 2>&1 | tail -1 && swift run FileExplorerTests 2>&1 | tail -1`; expect clean + `PASS` (honest count).

- [ ] **Step 3: Bundle + launch** — `./Scripts/bundle.sh && open build/FileExplorer.app`.

- [ ] **Step 4: MANUAL walkthrough** (human; TCC blocks agent UI automation):
  - [ ] Tag dots render in list and grid for a Finder-tagged file; assigning/removing via the context submenu shows up in Finder.
  - [ ] "New Tag…" free-text entry adds a novel tag to the selection (popover appears over the pane after the menu closes).
  - [ ] Tag filter menu lists visible tags; selecting narrows the listing; persists across relaunch (session).
  - [ ] Save Preset… names and saves the active filter; sidebar Presets section applies it (including the extensions text field); right-click deletes; "Apply Preset: name" appears in ⇧⌘A.
  - [ ] Old `settings.json`/`session.json` from M9 load cleanly (launch once from main build first if paranoid).
  - [ ] ⇧⌘F: typing searches file contents under the current folder via Spotlight; result confirm navigates + selects.
  - [ ] Zero-hit query shows "Deep Scan this folder…"; running it surfaces scanner hits; corrupt/binary files don't wedge it.
  - [ ] Deep-scan-then-edit-query limitation behaves as documented (reopen palette to refine).
  - [ ] Unindexed location (e.g. a `.noindex` folder) → deep scan path works there.

- [ ] **Step 5: Commit + completion notes**

```bash
git add README.md docs/superpowers/plans/2026-07-08-milestone-10-search-filters.md
git commit -m "docs: milestone 10 README updates and completion notes"
```

---

## Completion Notes

**Completed 2026-07-08.** All 7 implementation tasks done (Codex implementer + Claude reviewers, controller builds/tests/commits). Final suite: **549 assertions, PASS** (522 at start).

**Implementation-time discoveries (already folded into the plan text above):**
- `URLResourceValues.tagNames` setter is macOS 26+; TagWriter writes the `_kMDItemUserTags` xattr directly (binary plist, "Name\nColorIndex").
- Swift 6 region isolation rejects capturing a local `NSMetadataQuery` in the observer closure; SpotlightSearcher reads it back through the Sendable @MainActor self.

**Review loop caught pre-merge:** New Tag popover mistargeting in grid view (targets captured at menu-click via `newTagTargets`); deep-scan confirm losing `targetPane` (restored after undismiss); `dismiss()` now bumps `presentToken` so in-flight Spotlight/scan results can't land in a closed/reopened palette.

**Deferred / accepted:**
- After a deep scan, editing the query requires reopening ⇧⌘F (documented limitation).
- The uncancelled NSMetadataQuery keeps gathering briefly after Escape (results dropped by token; bounded, folder-scoped).
- `deletePreset` doesn't trim its argument (all current callers pass stored, pre-trimmed names).
- Tag-dot stroke may show a faint seam on alternating table-row stripes (cosmetic).

**MANUAL walkthrough (human, ~10 min — TCC blocks agent UI automation):**
- [ ] Tag dots render in list and grid for a Finder-tagged file; assigning/removing via the context submenu shows up in Finder **with correct colors** (xattr write path).
- [ ] "New Tag…" free-text entry adds a novel tag — including via right-click on an UNSELECTED grid item (the mistarget fix).
- [ ] Tag filter menu lists visible tags; selecting narrows the listing; persists across relaunch (session).
- [ ] Save Preset… names and saves the active filter; sidebar Presets section applies it (extensions field updates too); right-click deletes; "Apply Preset: name" appears in ⇧⌘A.
- [ ] Old settings.json/session.json from M9 load cleanly.
- [ ] ⇧⌘F: typing searches file contents under the current folder via Spotlight; confirm navigates + selects on the pane the palette was opened for (try switching tabs mid-search).
- [ ] Zero-hit query shows "Deep Scan this folder…"; running it surfaces scanner hits; picking a hit lands on the original pane.
- [ ] Unindexed location (e.g. a `.noindex` folder) → deep scan path works there.
- [ ] Escape mid-search: no late results reappear when reopening the palette.
