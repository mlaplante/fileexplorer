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
    @ObservationIgnored private var failed = Set<String>()
    @ObservationIgnored private var bumpScheduled = false

    private init() {
        cache.countLimit = 500
    }

    private func scheduleGenerationBump() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            bumpScheduled = false
            generation += 1
        }
    }

    private static func key(_ entry: FileEntry) -> String {
        "\(entry.url.path)|\(entry.modified.timeIntervalSince1970)"
    }

    /// Cached image if available; kicks off generation otherwise.
    func image(for entry: FileEntry, side: CGFloat) -> NSImage? {
        _ = generation   // register observation
        let key = Self.key(entry)
        if failed.contains(key) { return nil }
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
            guard let cgImage = representation?.cgImage else {
                failed.insert(key)
                if failed.count > 2000 { failed.removeAll() }
                return
            }
            let nsImage = NSImage(cgImage: cgImage,
                                  size: CGSize(width: side, height: side))
            cache.setObject(nsImage, forKey: key as NSString)
            scheduleGenerationBump()
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
            .overlay(alignment: .bottomLeading) {
                if entry.isSymlink {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .foregroundStyle(.secondary)
                        .background(.background, in: Circle())
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !entry.tags.isEmpty {
                    TagDotsView(tags: entry.tags)
                        .padding(2)
                }
            }
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
    var actions: FileActions
    var open: (Set<URL>) -> Void

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(pane.visibleEntries) { entry in
                    ThumbnailCell(entry: entry,
                                  isSelected: pane.selection.contains(entry.url))
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("fxGrid"))
                        } action: { frame in
                            pane.rubberBandFrames[entry.url] = frame
                        }
                        .contentShape(Rectangle())
                        .draggable(entry.url)
                        .gesture(TapGesture(count: 2).onEnded {
                            open([entry.url])
                        })
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            let flags = NSEvent.modifierFlags
                            pane.clickSelect(entry.url,
                                             commandDown: flags.contains(.command),
                                             shiftDown: flags.contains(.shift))
                        })
                        .contextMenu {
                            actions.menu(for: pane.selection.contains(entry.url)
                                         ? pane.selection : [entry.url])
                        }
                }
            }
            .padding(8)
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
    }
}
