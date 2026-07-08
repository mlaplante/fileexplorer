import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
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

    /// Card geometry shared with the grid's column sizing.
    static let cardWidth: CGFloat = 188
    static let imageHeight: CGFloat = 126
    private static let cornerRadius: CGFloat = 10

    /// Photo-like content fills the card edge-to-edge (cropping is fine);
    /// icons and document thumbnails sit centered on a subtle backdrop.
    private var fillsCard: Bool {
        guard let type = entry.contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            card
            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
                .frame(width: Self.cardWidth, alignment: .leading)
        }
        .padding(8)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                               : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Self.cornerRadius + 4))
    }

    private var card: some View {
        ZStack {
            if let image = ThumbnailStore.shared.image(for: entry, side: 256),
               fillsCard {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quinary)
                Group {
                    if let image = ThumbnailStore.shared.image(for: entry,
                                                               side: 256) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(nsImage: NSWorkspace.shared
                            .icon(forFile: entry.url.path))
                            .resizable().scaledToFit()
                    }
                }
                .padding(14)
            }
        }
        .frame(width: Self.cardWidth, height: Self.imageHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(.quaternary),
                              lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .topLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if entry.isSymlink {
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .foregroundStyle(.secondary)
                    .background(.background, in: Circle())
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !entry.tags.isEmpty {
                TagDotsView(tags: entry.tags)
                    .padding(6)
            }
        }
    }
}

struct ThumbnailGridView: View {
    @Bindable var pane: PaneState
    var actions: FileActions
    var open: (Set<URL>) -> Void

    // Column min = card width + the cell's own 8pt padding on each side.
    private let columns = [
        GridItem(.adaptive(minimum: ThumbnailCell.cardWidth + 16), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
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
            .padding(16)
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
