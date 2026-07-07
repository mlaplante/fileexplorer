# FileExplorer Milestone 5 (Previews) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quick Look (⌘Y / space, panel follows selection), hover previews for images and PDFs (~500 ms delay popover), and a thumbnail grid view mode per pane (list ⌥⌘1 / icons ⌥⌘2) backed by QuickLookThumbnailing with an in-memory cache.

**Architecture:** Core gains `PaneState.viewMode` (list/icons), `PreviewRenderer` (pure CGImage producers: ImageIO downsample + PDFKit first page — testable with generated fixtures), and `HoverPreviewModel` (@Observable debounce state machine with injectable delay). App target adds `QuickLookController` (NSObject conforming to `QLPreviewPanelDataSource`/`Delegate`, fed by the active pane's selection), hover popover wiring on Name cells, `ThumbnailGridView` (LazyVGrid + `QLThumbnailGenerator` + `NSCache` keyed by path+mtime), and View-menu items.

**Tech Stack:** Swift 6 SPM (CLT-only — NO `@State`/`@FocusState`; @Observable/@Bindable/manual Bindings/NSViewRepresentable). Frameworks: Quartz (QLPreviewPanel), QuickLookThumbnailing, ImageIO, PDFKit — all system frameworks, importable without Xcode. Tests: `swift run FileExplorerTests` (190 assertions at start; estimates below — recount honestly).

**Working directory:** `/Users/mlaplante/Sites/fileexplorer`, branch `milestone-5-previews`.

**Design decisions (approved):**
- Quick Look opens via menu ⌘Y and (attempted) space `.onKeyPress` on the table — space is NOT a global menu key-equivalent so typing in text fields stays safe; if `.onKeyPress` proves unreliable it degrades to ⌘Y-only (walkthrough item).
- The panel's item list = the active pane's `visibleEntries` (files only); its current index follows the pane selection while open.
- `QLPreviewPanel.shared()` is driven by setting `dataSource`/`delegate` directly (no responder-chain override) — pragmatic and standard for SwiftUI hosts.
- Hover preview: 500 ms delay, images + PDFs only, max 512 px, dismisses on hover end; renders off-main.
- Thumbnails: 96 px cells, `QLThumbnailGenerator`, NSCache keyed `path|mtime` (auto-invalidates on file change); grid double-click behaves like the table (folder navigates, file opens).
- View mode is per pane, remembered per tab (it lives on PaneState).

---

### Task 1: PaneState.viewMode + PreviewRenderer (TDD)

**Files:**
- Modify: `Sources/FileExplorerCore/PaneState.swift`
- Create: `Sources/FileExplorerCore/PreviewRenderer.swift`
- Create: `Sources/FileExplorerTests/PreviewRendererTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Write the failing test — `Sources/FileExplorerTests/PreviewRendererTests.swift`**

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func previewRendererTests() async {
    func writeTestPNG(to url: URL, width: Int, height: Int) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "test", code: 1)
        }
    }

    func writeTestPDF(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
    }

    await test("PreviewRenderer downsamples images to the max dimension") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("big.png")
        try writeTestPNG(to: png, width: 800, height: 400)

        let image = PreviewRenderer.downsampledImage(at: png, maxDimension: 200)
        expect(image != nil, "png renders")
        expectEqual(max(image!.width, image!.height), 200, "downsampled to max 200")

        let small = PreviewRenderer.downsampledImage(at: png, maxDimension: 2000)
        expectEqual(max(small!.width, small!.height), 800,
                    "never upscales beyond source size")
    }

    await test("PreviewRenderer renders PDF first pages and rejects non-previews") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("doc.pdf")
        try writeTestPDF(to: pdf)
        let page = PreviewRenderer.pdfFirstPage(at: pdf, maxDimension: 400)
        expect(page != nil, "pdf first page renders")
        expect(page!.width > 0 && page!.height > 0, "non-empty raster")

        let text = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        expect(PreviewRenderer.downsampledImage(at: text, maxDimension: 200) == nil,
               "text file is not an image")
        expect(PreviewRenderer.pdfFirstPage(at: text, maxDimension: 200) == nil,
               "text file is not a pdf")
    }

    await test("PaneState viewMode defaults to list and toggles") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneState(url: dir)
        expectEqual(pane.viewMode, .list, "list by default")
        pane.viewMode = .icons
        expectEqual(pane.viewMode, .icons, "switches to icons")
    }
}
```

**IMPORTANT:** define `writeTestPNG` and `writeTestPDF` at FILE scope (outside `previewRendererTests()`, not nested) — Task 2's hover test reuses `writeTestPNG` from another file in the same target.

Add `await previewRendererTests()` to `main.swift` after `await paletteModelTests()`.

- [x] **Step 2: Verify red** — `swift run FileExplorerTests` → no `PreviewRenderer`, no `viewMode`.

- [x] **Step 3: Implement.** In `Sources/FileExplorerCore/PaneState.swift` add (near `showHidden`):

```swift
    public enum ViewMode: String, Sendable {
        case list
        case icons
    }

    /// List vs thumbnail-grid presentation; per pane, remembered per tab.
    public var viewMode: ViewMode = .list
```

Create `Sources/FileExplorerCore/PreviewRenderer.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import PDFKit

/// Pure CGImage producers for hover previews. Blocking — call off the main
/// actor. Both return nil for files they can't render.
public enum PreviewRenderer {
    public static func downsampledImage(at url: URL,
                                        maxDimension: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    public static func pdfFirstPage(at url: URL, maxDimension: Int) -> CGImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(maxDimension) / max(bounds.width, bounds.height)
        let size = CGSize(width: max(bounds.width * scale, 1),
                          height: max(bounds.height * scale, 1))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
```

- [x] **Step 4: Verify green** — PASS (~199, recount honestly). Run twice.

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: PreviewRenderer and per-pane view mode"`

---

### Task 2: HoverPreviewModel (TDD)

**Files:**
- Create: `Sources/FileExplorerCore/HoverPreviewModel.swift`
- Create: `Sources/FileExplorerTests/HoverPreviewModelTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift`

- [x] **Step 1: Write the failing test — `Sources/FileExplorerTests/HoverPreviewModelTests.swift`**

```swift
import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func hoverPreviewModelTests() async {
    func entry(_ name: String, type: UTType?) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/t/\(name)"), name: name,
                  isDirectory: false, isHidden: false, isSymlink: false,
                  size: 1, created: nil, modified: .distantPast, contentType: type)
    }

    await test("HoverPreviewModel presents previewables after the delay") {
        let model = HoverPreviewModel(delay: .milliseconds(50))
        let image = entry("pic.png", type: UTType(filenameExtension: "png"))
        expect(HoverPreviewModel.isPreviewable(image), "png is previewable")

        model.hoverBegan(image)
        expect(model.presented == nil, "not presented before delay")
        try await Task.sleep(for: .milliseconds(150))
        expectEqual(model.presented?.url, image.url, "presented after delay")

        model.hoverEnded()
        expect(model.presented == nil, "dismissed on hover end")
    }

    await test("HoverPreviewModel ignores non-previewables and cancels on early exit") {
        let model = HoverPreviewModel(delay: .milliseconds(50))
        let text = entry("notes.txt", type: UTType(filenameExtension: "txt"))
        expect(!HoverPreviewModel.isPreviewable(text), "txt not previewable")
        model.hoverBegan(text)
        try await Task.sleep(for: .milliseconds(150))
        expect(model.presented == nil, "non-previewable never presents")

        let pdf = entry("doc.pdf", type: UTType(filenameExtension: "pdf"))
        expect(HoverPreviewModel.isPreviewable(pdf), "pdf is previewable")
        model.hoverBegan(pdf)
        model.hoverEnded()   // leave before the delay elapses
        try await Task.sleep(for: .milliseconds(150))
        expect(model.presented == nil, "early exit cancels the pending preview")
    }

    await test("HoverPreviewModel retarget replaces pending hover") {
        let model = HoverPreviewModel(delay: .milliseconds(50))
        let first = entry("a.png", type: UTType(filenameExtension: "png"))
        let second = entry("b.png", type: UTType(filenameExtension: "png"))
        model.hoverBegan(first)
        model.hoverBegan(second)   // moved to another row before delay
        try await Task.sleep(for: .milliseconds(150))
        expectEqual(model.presented?.url, second.url, "latest hover wins")
    }

    await test("HoverPreviewModel renders the presented file's image") {
        // Real file: model must eventually publish a rendered CGImage.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("real.png")
        try writeTestPNG(to: png, width: 64, height: 64)   // helper from PreviewRendererTests — move it to file scope there so both suites can use it
        let real = FileEntry(url: png, name: "real.png", isDirectory: false,
                             isHidden: false, isSymlink: false, size: 1,
                             created: nil, modified: .distantPast,
                             contentType: UTType(filenameExtension: "png"))

        let model = HoverPreviewModel(delay: .milliseconds(20))
        model.hoverBegan(real)
        try await Task.sleep(for: .milliseconds(400))
        expect(model.presented != nil, "presented")
        expect(model.presentedImage != nil, "rendered image published")
        model.hoverEnded()
        expect(model.presentedImage == nil, "image cleared on hover end")
    }
}
```

Add `await hoverPreviewModelTests()` to `main.swift` after `await previewRendererTests()`.

- [x] **Step 2: Verify red.**

- [x] **Step 3: Implement — `Sources/FileExplorerCore/HoverPreviewModel.swift`**

```swift
import Foundation
import Observation
import UniformTypeIdentifiers

/// Debounced hover state for image/PDF row previews: present after `delay`
/// of continuous hover, cancel on exit, retarget on row change. Owns the
/// rendered image too — render state must NOT live on view structs, which
/// SwiftUI re-initializes on parent re-render (and `.task(id:)` would not
/// re-fire, freezing a spinner).
@MainActor
@Observable
public final class HoverPreviewModel {
    public private(set) var presented: FileEntry?
    public private(set) var presentedImage: CGImage?

    private let delay: Duration
    private var pending: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
    }

    public static func isPreviewable(_ entry: FileEntry) -> Bool {
        guard !entry.isDirectory, let type = entry.contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    public func hoverBegan(_ entry: FileEntry) {
        pending?.cancel()
        guard Self.isPreviewable(entry) else {
            presented = nil
            presentedImage = nil
            return
        }
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            presented = entry
            let url = entry.url
            let isPDF = entry.contentType?.conforms(to: .pdf) == true
            let rendered = await Task.detached(priority: .userInitiated) {
                isPDF
                    ? PreviewRenderer.pdfFirstPage(at: url, maxDimension: 512)
                    : PreviewRenderer.downsampledImage(at: url, maxDimension: 512)
            }.value
            guard !Task.isCancelled, presented?.url == url else { return }
            presentedImage = rendered
        }
    }

    public func hoverEnded() {
        pending?.cancel()
        pending = nil
        presented = nil
        presentedImage = nil
    }
}
```

- [x] **Step 4: Verify green** — PASS (~209, recount honestly). Timing-based: run twice; a single flake → re-run, persistent failure → real bug.

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: HoverPreviewModel debounce state"`

---

### Task 3: Quick Look panel

**Files:**
- Create: `Sources/FileExplorer/QuickLookController.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

UI glue — no unit tests. NO `@State`.

- [x] **Step 1: Create `Sources/FileExplorer/QuickLookController.swift`**

```swift
import AppKit
import Quartz
import FileExplorerCore

/// Drives the shared QLPreviewPanel from the active pane: items are the
/// pane's visible FILES; the panel index follows the pane selection.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource,
                                 QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    func toggle(for pane: PaneState) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        refresh(from: pane)
        guard !urls.isEmpty else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Re-syncs items + current index from the pane; call on selection change
    /// while the panel is visible.
    func refresh(from pane: PaneState) {
        urls = pane.visibleEntries.filter { !$0.isDirectory }.map(\.url)
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
        if let selected = pane.selection.first,
           let index = urls.firstIndex(of: selected) {
            panel.currentPreviewItemIndex = index
        }
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared().isVisible
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!,
                                  previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }
    }
}
```

(If `Quartz` fails to import or the delegate signatures differ on this SDK, adapt minimally — the load-bearing behavior is: toggle shows/hides the shared panel with the pane's files, and selection sync moves `currentPreviewItemIndex`. QLPreviewPanel data-source methods are called on the main thread; `assumeIsolated` bridges the nonisolated protocol requirement.)

- [x] **Step 2: Wire selection-follow and space key in `Sources/FileExplorer/PaneView.swift`.** Add to the `table` property chain (after `.overlay { ... }`):

```swift
        .onChange(of: pane.selection) { _, _ in
            if QuickLookController.shared.isVisible {
                QuickLookController.shared.refresh(from: pane)
            }
        }
        .onKeyPress(.space) {
            QuickLookController.shared.toggle(for: pane)
            return .handled
        }
```

- [x] **Step 3: Menu item in `Sources/FileExplorer/FileExplorerApp.swift`.** In the `CommandGroup(after: .toolbar)` block (with Show Hidden Files / Toggle Dual Pane), add:

```swift
                Button("Quick Look") {
                    QuickLookController.shared.toggle(for: session.activePane)
                }
                .keyboardShortcut("y", modifiers: .command)
```

- [x] **Step 4: Verify** — `swift build` clean; `swift run FileExplorerTests` unchanged PASS; grep sweeps clean; launch check >5 s.

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: Quick Look panel following the active pane selection"`

---

### Task 4: Hover previews

**Files:**
- Create: `Sources/FileExplorer/HoverPreviewView.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`

- [x] **Step 1: Create `Sources/FileExplorer/HoverPreviewView.swift`**

```swift
import SwiftUI
import FileExplorerCore

/// Popover content. STATELESS — all render state lives on HoverPreviewModel
/// (view structs are re-initialized on parent re-render, so they must not
/// own async state on this no-@State toolchain).
struct HoverPreviewView: View {
    @Bindable var model: HoverPreviewModel

    var body: some View {
        Group {
            if let image = model.presentedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(width: 128, height: 128)
            }
        }
        .frame(maxWidth: 512, maxHeight: 512)
        .padding(6)
    }
}
```

- [x] **Step 2: Wire into the Name column in `Sources/FileExplorer/PaneView.swift`.** PaneView needs a hover model — add a stored property (plain let — PaneView is recreated per pane but the model is only transient hover state):

```swift
    private let hoverModel = HoverPreviewModel()
```

In the Name `TableColumn`'s cell content (the HStack), append these modifiers to the HStack:

```swift
                .onHover { hovering in
                    if hovering {
                        hoverModel.hoverBegan(entry)
                    } else if hoverModel.presented?.url == entry.url
                                || !hovering {
                        hoverModel.hoverEnded()
                    }
                }
                .popover(isPresented: Binding(
                    get: { hoverModel.presented?.url == entry.url },
                    set: { if !$0 { hoverModel.hoverEnded() } }),
                    arrowEdge: .trailing) {
                    HoverPreviewView(model: hoverModel)
                }
```

(Simplify the onHover else-branch if it's redundant — `hoverModel.hoverEnded()` on any un-hover is acceptable; report what you shipped.)

- [x] **Step 3: Verify** — build clean, tests unchanged, launch check. Report that popover behavior itself is walkthrough-verified only.

- [x] **Step 4: Commit** — `git add -A && git commit -m "feat: hover previews for images and PDFs"`

---

### Task 5: Thumbnail grid + view-mode menu

**Files:**
- Create: `Sources/FileExplorer/ThumbnailGridView.swift`
- Modify: `Sources/FileExplorer/PaneView.swift`
- Modify: `Sources/FileExplorer/FileExplorerApp.swift`

- [x] **Step 1: Create `Sources/FileExplorer/ThumbnailGridView.swift`**

```swift
import SwiftUI
import AppKit
import QuickLookThumbnailing
import FileExplorerCore

/// App-lifetime thumbnail store. Cells are STATELESS view structs (re-inited
/// on every parent re-render on this no-@State toolchain), so async state
/// lives here: an NSCache of images plus an observable `generation` counter
/// that bumps whenever a new thumbnail lands, re-rendering visible cells.
@MainActor
@Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// Bumped when any thumbnail finishes; cells read it so they re-evaluate.
    private(set) var generation = 0

    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var inFlight = Set<String>()

    private init() {
        cache.countLimit = 500
    }

    private static func key(_ entry: FileEntry) -> String {
        "\(entry.url.path)|\(entry.modified.timeIntervalSince1970)"
    }

    /// Cached image if available; kicks off generation otherwise.
    func image(for entry: FileEntry, side: CGFloat) -> NSImage? {
        _ = generation   // register observation
        let key = Self.key(entry)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        request(entry, key: key, side: side)
        return nil
    }

    private func request(_ entry: FileEntry, key: String, side: CGFloat) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url, size: CGSize(width: side, height: side),
            scale: 2, representationTypes: .thumbnail)
        Task {
            let representation = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            inFlight.remove(key)
            guard let cgImage = representation?.cgImage else { return }
            let nsImage = NSImage(cgImage: cgImage,
                                  size: CGSize(width: side, height: side))
            cache.setObject(nsImage, forKey: key as NSString)
            generation += 1
        }
    }
}

struct ThumbnailCell: View {
    let entry: FileEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image = ThumbnailStore.shared.image(for: entry, side: 96) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable().scaledToFit()
                }
            }
            .frame(width: 96, height: 96)
            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 104)
        }
        .padding(6)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ThumbnailGridView: View {
    @Bindable var pane: PaneState
    var open: (Set<URL>) -> Void

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(pane.visibleEntries) { entry in
                    ThumbnailCell(entry: entry,
                                  isSelected: pane.selection.contains(entry.url))
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).onEnded {
                            open([entry.url])
                        })
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            pane.selection = [entry.url]
                        })
                        .contextMenu {
                            // File operations arrive in Milestone 6.
                        }
                }
            }
            .padding(8)
        }
    }
}
```

- [x] **Step 2: Switch on view mode in `Sources/FileExplorer/PaneView.swift`.** In `body`'s VStack replace the bare `table` line with:

```swift
            if pane.viewMode == .icons {
                ThumbnailGridView(pane: pane) { open($0) }
            } else {
                table
            }
```

(`open(_:)` is the existing private method — it already handles folder-navigate vs file-open.)

- [x] **Step 3: View-menu items in `Sources/FileExplorer/FileExplorerApp.swift`.** In `CommandGroup(after: .toolbar)`, add before the Quick Look button:

```swift
                Picker("View", selection: Binding(
                    get: { session.activePane.viewMode },
                    set: { session.activePane.viewMode = $0 })) {
                    Text("as List").tag(PaneState.ViewMode.list)
                        .keyboardShortcut("1", modifiers: [.command, .option])
                    Text("as Icons").tag(PaneState.ViewMode.icons)
                        .keyboardShortcut("2", modifiers: [.command, .option])
                }
                .pickerStyle(.inline)
```

(If keyboardShortcut on Picker tags doesn't register, use two Buttons setting viewMode with those shortcuts instead — report which form shipped.)

- [x] **Step 4: Verify** — build clean; tests unchanged PASS; grep sweeps; launch check.

- [x] **Step 5: Commit** — `git add -A && git commit -m "feat: thumbnail grid view mode with QuickLook thumbnails"`

---

### Task 6: Final milestone verification

- [x] **Step 1:** `swift run FileExplorerTests` → PASS ×2.
- [x] **Step 2:** `./Scripts/bundle.sh && open build/FileExplorer.app`; idle check (~0% CPU, stable RSS ~15 s); kill.
- [x] **Step 3:** Walkthrough notes: ⌘Y/space Quick Look with arrow-follow; hover previews appear after ~0.5 s on images/PDFs and dismiss cleanly; ⌥⌘1/⌥⌘2 switch views; grid thumbnails load + cache (revisit is instant); grid selection/double-click; per-pane view modes in dual mode.
- [x] **Step 4:** Fix anything real; commit (`fix: … (milestone 5 verification)`).

---

## Completion Notes (2026-07-07)

All 6 tasks implemented, reviewed, verified. Final: `swift run FileExplorerTests` → PASS (214 assertions); idle ~0% CPU.

**Interactive verification breakthrough:** UI automation (System Events + AX + screenshots) now works on this machine. 9/11 walkthrough items VERIFIED live, including the M1-era open question — **Scene-level @Observable reactivity works** (title/toolbar/breadcrumb/content update together). Also verified: hidden toggle, tabs, dual-pane layout, filter chips ("15 of 18 items"), ⌘G/⇧⌘A palettes, ⌘P opens Find File (no Print conflict), Quick Look opens at selection, icons grid with real thumbnails, live watcher. Remaining MANUAL (synthetic mouse events unreliable on contended desktop): dual-pane click-to-activate tint, hover preview popover.

Deviations/additions beyond plan text:
- `@preconcurrency import Quartz` (QLPreviewItem not Sendable on this SDK).
- HoverPreviewModel gained an injectable `Renderer` seam; stale-image-on-retarget bug found and fixed with a genuinely discriminating red/green test.
- Quick Look: first-open index fix; follows icon mode and tab/pane switches (post-review); toggle/refresh deduped.
- ThumbnailStore: failed-generation memoization (no re-request storms).

**Deferred to M6+:** grid multi-select (single-tap replaces selection — matters once batch ops land); hoverModel hoisting off the view struct (latent, no visible failure); generation-counter coalescing for very large folders.
