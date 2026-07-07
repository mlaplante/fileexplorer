# FileExplorer Milestone 2 (Filter) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real-time, composable filtering: type-preset chips (Images/PDFs/Videos/Documents), custom extension list, date presets, and size presets — all applicable simultaneously, with a filter bar in the pane and "N of M items" in the status bar.

**Architecture:** Pure filter logic in `FileExplorerCore` (`TypePreset`/`DatePreset`/`SizePreset`, `FilterState` value struct, `FilterEngine.apply`), integrated into `PaneState` as `filter` (didSet → recompute) so `visibleEntries = sort(filter(entries))`. UI is a `FilterBarView` of toggle-chips + Menus + an inline extension TextField — deliberately no popovers because `@State` does not compile on this CLT-only toolchain.

**Tech Stack:** Swift 6 SPM (CLT toolchain — `swift build` only, NO `@State`), UniformTypeIdentifiers, SwiftUI Menu/Toggle. Tests via `swift run FileExplorerTests` (executable harness; exit 0 = pass; 58 assertions at start of this milestone).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-2-filter`.

**Design decisions (approved):**
- Date/size filters use preset tokens stored in `FilterState` (`datePreset`/`sizePreset`), with ranges computed at apply time (`now` injected for tests). Custom range pickers: deferred (needs popover/@State).
- Folders always pass all filters so navigation stays usable while filtering.
- Extension text is a UI draft string on `PaneState` (`filterExtensionsText`), parsed into `filter.extensions` (lowercased, dots stripped) on every edit.

---

### Task 1: TypePreset, DatePreset, SizePreset (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/FilterPresets.swift`
- Create: `Sources/FileExplorerTests/FilterPresetsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/FilterPresetsTests.swift`**

```swift
import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func filterPresetsTests() async {
    await test("TypePreset matches by UTType conformance") {
        expect(TypePreset.images.matches(UTType(filenameExtension: "png")),
               "png is an image")
        expect(TypePreset.images.matches(UTType(filenameExtension: "heic")),
               "heic is an image")
        expect(!TypePreset.images.matches(UTType(filenameExtension: "txt")),
               "txt is not an image")
        expect(TypePreset.pdfs.matches(UTType(filenameExtension: "pdf")),
               "pdf matches PDFs")
        expect(!TypePreset.images.matches(UTType(filenameExtension: "pdf")),
               "pdf is not an image")
        expect(TypePreset.videos.matches(UTType(filenameExtension: "mp4")),
               "mp4 is a video")
        expect(TypePreset.videos.matches(UTType(filenameExtension: "mov")),
               "mov is a video")
        expect(TypePreset.documents.matches(UTType(filenameExtension: "txt")),
               "txt is a document")
        expect(TypePreset.documents.matches(UTType(filenameExtension: "docx")),
               "docx is a document")
        expect(!TypePreset.documents.matches(UTType(filenameExtension: "png")),
               "png is not a document")
        expect(!TypePreset.images.matches(nil), "nil content type never matches")
    }

    await test("DatePreset ranges are anchored to injected now") {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 7, hour: 15))!

        let today = DatePreset.today.range(now: now, calendar: calendar)
        expect(today.contains(now), "today contains now")
        expect(!today.contains(calendar.date(byAdding: .day, value: -1, to: now)!),
               "today excludes yesterday")

        let week = DatePreset.last7Days.range(now: now, calendar: calendar)
        expect(week.contains(calendar.date(byAdding: .day, value: -6, to: now)!),
               "last 7 days contains 6 days ago")
        expect(!week.contains(calendar.date(byAdding: .day, value: -8, to: now)!),
               "last 7 days excludes 8 days ago")

        let year = DatePreset.thisYear.range(now: now, calendar: calendar)
        expect(year.contains(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!),
               "this year contains January 2nd")
        expect(!year.contains(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!),
               "this year excludes last December")
    }

    await test("SizePreset ranges partition sensibly") {
        expect(SizePreset.under1MB.range.contains(500_000), "500 KB is under 1 MB")
        expect(!SizePreset.under1MB.range.contains(2_000_000), "2 MB is not under 1 MB")
        expect(SizePreset.oneTo100MB.range.contains(50 * 1_048_576), "50 MB is in 1–100 MB")
        expect(SizePreset.over100MB.range.contains(Int64(1) << 40), "1 TB is over 100 MB")
        expect(!SizePreset.over100MB.range.contains(1_048_576), "1 MB is not over 100 MB")
    }
}
```

Add `await filterPresetsTests()` to `Sources/FileExplorerTests/main.swift` after `await ancestorChainTests()`.

- [ ] **Step 2: Run tests to verify red**

Run: `swift run FileExplorerTests`
Expected: build FAILS with "cannot find 'TypePreset' in scope" (and siblings).

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/FilterPresets.swift`**

```swift
import Foundation
import UniformTypeIdentifiers

public enum TypePreset: String, CaseIterable, Sendable {
    case images = "Images"
    case pdfs = "PDFs"
    case videos = "Videos"
    case documents = "Documents"

    /// Word-processing formats that don't conform to `.text` because they are
    /// zipped/package formats.
    private static let wordProcessingIdentifiers: Set<String> = [
        "com.microsoft.word.doc",
        "org.openxmlformats.wordprocessingml.document",
        "com.apple.iwork.pages.sffpages",
        "org.oasis-open.opendocument.text",
    ]

    public func matches(_ type: UTType?) -> Bool {
        guard let type else { return false }
        switch self {
        case .images:
            return type.conforms(to: .image)
        case .pdfs:
            return type.conforms(to: .pdf)
        case .videos:
            return type.conforms(to: .movie) || type.conforms(to: .video)
        case .documents:
            return type.conforms(to: .text)
                || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet)
                || Self.wordProcessingIdentifiers.contains(type.identifier)
        }
    }
}

public enum DatePreset: String, CaseIterable, Sendable {
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case thisYear = "This Year"

    /// Computed at apply time so "Today" stays correct across reloads.
    public func range(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)...now
        case .last7Days:
            return calendar.date(byAdding: .day, value: -7, to: now)!...now
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: now)!...now
        case .thisYear:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now))!
            return start...now
        }
    }
}

public enum SizePreset: String, CaseIterable, Sendable {
    case under1MB = "Under 1 MB"
    case oneTo100MB = "1–100 MB"
    case over100MB = "Over 100 MB"

    public var range: ClosedRange<Int64> {
        let mb: Int64 = 1_048_576
        switch self {
        case .under1MB: return 0...(mb - 1)
        case .oneTo100MB: return mb...(100 * mb)
        case .over100MB: return (100 * mb + 1)...Int64.max
        }
    }
}
```

- [ ] **Step 4: Run tests to verify green**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0 (58 prior + 19 new = 77 assertions — recount honestly if it differs and say why).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: type/date/size filter presets"
```

---

### Task 2: FilterState + FilterEngine (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/FilterState.swift`
- Create: `Sources/FileExplorerCore/FilterEngine.swift`
- Create: `Sources/FileExplorerTests/FilterEngineTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/FilterEngineTests.swift`**

```swift
import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func filterEngineTests() async {
    func entry(_ name: String, dir: Bool = false, size: Int64 = 0,
               modified: Date = .distantPast) -> FileEntry {
        let url = URL(fileURLWithPath: "/t/\(name)")
        return FileEntry(url: url, name: name, isDirectory: dir, isHidden: false,
                         isSymlink: false, size: size, created: nil,
                         modified: modified,
                         contentType: dir ? nil : UTType(filenameExtension: url.pathExtension))
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let items = [
        entry("folder", dir: true),
        entry("photo.png", size: 2_000_000, modified: now),
        entry("clip.mp4", size: 200 * 1_048_576, modified: now),
        entry("notes.txt", size: 100, modified: Date(timeIntervalSince1970: 0)),
        entry("paper.pdf", size: 500_000, modified: now),
    ]

    await test("inactive filter passes everything through unchanged") {
        var f = FilterState()
        expect(!f.isActive, "default state is inactive")
        expectEqual(FilterEngine.apply(f, to: items, now: now).count, items.count,
                    "no filtering when inactive")
        f.preset = .images
        expect(f.isActive, "preset activates the filter")
    }

    await test("type preset filters files but folders always pass") {
        var f = FilterState()
        f.preset = .images
        let result = FilterEngine.apply(f, to: items, now: now)
        expectEqual(result.map(\.name).sorted(), ["folder", "photo.png"],
                    "images preset keeps folder + png")
    }

    await test("extension filter matches case-insensitively") {
        var f = FilterState()
        f.extensions = ["pdf", "txt"]
        let result = FilterEngine.apply(f, to: items, now: now)
        expectEqual(result.map(\.name).sorted(), ["folder", "notes.txt", "paper.pdf"],
                    "extension set keeps pdf + txt + folder")
    }

    await test("date and size presets compose with AND semantics") {
        var f = FilterState()
        f.datePreset = .last7Days
        let recent = FilterEngine.apply(f, to: items, now: now)
        expectEqual(recent.map(\.name).sorted(), ["clip.mp4", "folder", "paper.pdf", "photo.png"],
                    "date filter drops the ancient txt")

        f.sizePreset = .over100MB
        let bigRecent = FilterEngine.apply(f, to: items, now: now)
        expectEqual(bigRecent.map(\.name).sorted(), ["clip.mp4", "folder"],
                    "AND of date + size keeps only the big video")

        f.preset = .images
        let none = FilterEngine.apply(f, to: items, now: now)
        expectEqual(none.map(\.name), ["folder"],
                    "no image is over 100MB — only the folder passes")
    }
}
```

Add `await filterEngineTests()` to `main.swift` after `await filterPresetsTests()`.

- [ ] **Step 2: Run tests to verify red**

Run: `swift run FileExplorerTests`
Expected: build FAILS with "cannot find 'FilterState' in scope".

- [ ] **Step 3: Implement — `Sources/FileExplorerCore/FilterState.swift`**

```swift
import Foundation

public struct FilterState: Equatable, Sendable {
    public var preset: TypePreset?
    /// Lowercased extensions without leading dots, e.g. ["png", "jpg"].
    public var extensions: Set<String> = []
    public var datePreset: DatePreset?
    public var sizePreset: SizePreset?

    public init() {}

    public var isActive: Bool {
        preset != nil || !extensions.isEmpty || datePreset != nil || sizePreset != nil
    }
}
```

- [ ] **Step 4: Implement — `Sources/FileExplorerCore/FilterEngine.swift`**

```swift
import Foundation

public enum FilterEngine {
    /// Applies all active filters with AND semantics. Folders always pass so
    /// navigation stays possible while filtering. `now` anchors date presets
    /// (injectable for tests).
    public static func apply(_ filter: FilterState, to entries: [FileEntry],
                             now: Date = Date()) -> [FileEntry] {
        guard filter.isActive else { return entries }
        let dateRange = filter.datePreset?.range(now: now)
        let sizeRange = filter.sizePreset?.range
        return entries.filter { entry in
            if entry.isDirectory { return true }
            if let preset = filter.preset, !preset.matches(entry.contentType) {
                return false
            }
            if !filter.extensions.isEmpty,
               !filter.extensions.contains(entry.url.pathExtension.lowercased()) {
                return false
            }
            if let dateRange, !dateRange.contains(entry.modified) {
                return false
            }
            if let sizeRange, !sizeRange.contains(entry.size) {
                return false
            }
            return true
        }
    }
}
```

- [ ] **Step 5: Run tests to verify green**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0 (77 prior + 10 new = 87 assertions — recount honestly).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: FilterState and FilterEngine with AND-composed filters"
```

---

### Task 3: PaneState integration (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerTests/PaneFilterTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [ ] **Step 1: Write the failing test — `Sources/FileExplorerTests/PaneFilterTests.swift`**

```swift
import Foundation
import FileExplorerCore

@MainActor
func paneFilterTests() async {
    await test("PaneState filter narrows visibleEntries live") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("img".utf8).write(to: dir.appendingPathComponent("a.png"))
        try Data("doc".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)

        let pane = PaneState(url: dir)
        await pane.reload()
        expectEqual(pane.visibleEntries.count, 3, "unfiltered shows all")
        expectEqual(pane.totalCount, 3, "totalCount matches entries")

        pane.filter.preset = .images
        expectEqual(pane.visibleEntries.map(\.name), ["sub", "a.png"],
                    "images filter keeps folder + png, folders first")
        expectEqual(pane.totalCount, 3, "totalCount unaffected by filter")

        pane.filter = FilterState()
        expectEqual(pane.visibleEntries.count, 3, "clearing filter restores all")
    }

    await test("PaneState parses extension text into the filter") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()

        pane.filterExtensionsText = " .PNG, jpg ,"
        expectEqual(pane.filter.extensions, ["png", "jpg"],
                    "text parsed: trimmed, lowercased, dots stripped, empties dropped")
        expectEqual(pane.visibleEntries.map(\.name), ["a.png"], "filter applied live")

        pane.clearFilters()
        expect(!pane.filter.isActive, "clearFilters deactivates")
        expectEqual(pane.filterExtensionsText, "", "clearFilters empties the draft text")
        expectEqual(pane.visibleEntries.count, 2, "all entries back")
    }

    await test("filter persists across reloads and navigation") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        pane.filter.preset = .images
        await pane.reload()
        expectEqual(pane.visibleEntries.map(\.name), ["a.png"],
                    "filter still applied after reload")
    }
}
```

Add `await paneFilterTests()` to `main.swift` after `await filterEngineTests()`.

- [ ] **Step 2: Run tests to verify red**

Run: `swift run FileExplorerTests`
Expected: build FAILS — PaneState has no `filter` / `totalCount` / `filterExtensionsText` / `clearFilters`.

- [ ] **Step 3: Implement in `Sources/FileExplorerCore/PaneState.swift`**

Add stored properties (near `sortOrder`):

```swift
    public var filter = FilterState() {
        didSet { recomputeVisible() }
    }

    /// UI draft for the extension filter field; parsed into `filter.extensions`
    /// on every edit ("png, .JPG" → ["png", "jpg"]).
    public var filterExtensionsText = "" {
        didSet {
            filter.extensions = Set(
                filterExtensionsText.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                    .filter { !$0.isEmpty })
        }
    }
```

Add near `visibleEntries`:

```swift
    /// Count before filtering — the "M" in the status bar's "N of M items".
    public var totalCount: Int { entries.count }
```

Add a public method:

```swift
    public func clearFilters() {
        filterExtensionsText = ""
        filter = FilterState()
    }
```

Rename the private `applySort()` to `recomputeVisible()` (update the `entries`/`sortOrder` didSets) and change its body to:

```swift
    private func recomputeVisible() {
        visibleEntries = FileSorter.sort(
            FilterEngine.apply(filter, to: entries), using: sortOrder)
    }
```

Update `visibleEntries`' doc comment to mention filtering, e.g. "Filtered and sorted snapshot of `entries` … refreshed when `entries`, `sortOrder`, or `filter` changes."

- [ ] **Step 4: Run tests to verify green**

Run: `swift run FileExplorerTests`
Expected: PASS, exit 0 (87 prior + 11 new = 98 assertions — recount honestly). Run twice for stability.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: wire FilterEngine into PaneState with live recompute"
```

---

### Task 4: Filter bar UI

**Files:**
- Create: `Sources/FileExplorer/FilterBarView.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`

UI glue — no unit tests; logic stays in Core. NO `@State` (CLT constraint).

- [ ] **Step 1: Create `Sources/FileExplorer/FilterBarView.swift`**

```swift
import SwiftUI
import FileExplorerCore

struct FilterBarView: View {
    @Bindable var pane: PaneState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TypePreset.allCases, id: \.self) { preset in
                Toggle(preset.rawValue, isOn: Binding(
                    get: { pane.filter.preset == preset },
                    set: { pane.filter.preset = $0 ? preset : nil }))
                    .toggleStyle(.button)
                    .controlSize(.small)
            }

            Divider().frame(height: 14)

            Menu {
                Button("Any Time") { pane.filter.datePreset = nil }
                Divider()
                ForEach(DatePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { pane.filter.datePreset = preset }
                }
            } label: {
                Label(pane.filter.datePreset?.rawValue ?? "Date",
                      systemImage: "calendar")
            }
            .controlSize(.small)
            .fixedSize()

            Menu {
                Button("Any Size") { pane.filter.sizePreset = nil }
                Divider()
                ForEach(SizePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { pane.filter.sizePreset = preset }
                }
            } label: {
                Label(pane.filter.sizePreset?.rawValue ?? "Size",
                      systemImage: "scalemass")
            }
            .controlSize(.small)
            .fixedSize()

            TextField("ext, ext…", text: $pane.filterExtensionsText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 120)

            Spacer()

            if pane.filter.isActive {
                Button("Clear") { pane.clearFilters() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}
```

- [ ] **Step 2: Wire into `Sources/FileExplorer/PaneView.swift`**

In `body`'s VStack, insert the filter bar between the breadcrumb and the table:

```swift
        VStack(spacing: 0) {
            BreadcrumbView(pane: pane)
            Divider()
            FilterBarView(pane: pane)
            Divider()
            table
            Divider()
            statusBar
        }
```

Update `statusBar`'s first Text to show "N of M items" while filtering:

```swift
            if pane.filter.isActive {
                Text("\(pane.visibleEntries.count) of \(pane.totalCount) items")
            } else {
                Text("\(pane.visibleEntries.count) items")
            }
```

Also update the empty-state overlay so a fully-filtered-out folder doesn't claim to be empty. Replace the `else if pane.hasLoadedOnce && pane.visibleEntries.isEmpty` branch content with:

```swift
            } else if pane.hasLoadedOnce && pane.visibleEntries.isEmpty {
                if pane.filter.isActive {
                    ContentUnavailableView(
                        "No Matches", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No items match the current filters."))
                } else {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                }
            }
```

- [ ] **Step 3: Build and verify**

1. `swift build` → clean; `grep -rn "@State" Sources/` → empty.
2. `swift run FileExplorerTests` → PASS (98 assertions), exit 0.
3. Launch check: `swift run FileExplorer` backgrounded, alive >5 s, kill. (Visual verification deferred to milestone walkthrough.)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: filter bar with preset chips, date/size menus, extension field"
```

---

### Task 5: Final milestone verification

**Files:** none (verification only; fixes if found)

- [ ] **Step 1: Full test run** — `swift run FileExplorerTests` → PASS, exit 0, twice.

- [ ] **Step 2: Bundle + idle check** — `./Scripts/bundle.sh`, `open build/FileExplorer.app`, after 15 s `ps -p <pid> -o %cpu,rss` → CPU near 0, RSS stable ~130 MB (regression guard on the M1 idle bug). Kill it.

- [ ] **Step 3: Automated evidence where possible** — screenshots/keyboard driving are TCC-blocked for agents on this machine; note what needs the human walkthrough: chips narrow the table live, date/size menus filter, extension field filters as you type, Clear restores, "N of M items", "No Matches" overlay.

- [ ] **Step 4: Fix anything real found; commit fixes** (`fix: … (milestone 2 verification)`).
