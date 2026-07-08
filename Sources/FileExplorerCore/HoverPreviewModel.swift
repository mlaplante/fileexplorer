import Foundation
import Observation
import UniformTypeIdentifiers
import CoreGraphics

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

    public typealias Renderer = @Sendable (URL, _ isPDF: Bool) async -> CGImage?

    private let delay: Duration
    private let renderer: Renderer
    private var pending: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(500),
                renderer: @escaping Renderer = HoverPreviewModel.defaultRenderer) {
        self.delay = delay
        self.renderer = renderer
    }

    /// Production renderer: PreviewRenderer off the main actor.
    public static let defaultRenderer: Renderer = { url, isPDF in
        await Task.detached(priority: .userInitiated) {
            // 1920px ≈ the popover's 960pt ceiling at 2x, so previews stay
            // crisp on Retina displays.
            isPDF
                ? PreviewRenderer.pdfFirstPage(at: url, maxDimension: 1920)
                : PreviewRenderer.downsampledImage(at: url, maxDimension: 1920)
        }.value
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
            presentedImage = nil
            let url = entry.url
            let isPDF = entry.contentType?.conforms(to: .pdf) == true
            let rendered = await renderer(url, isPDF)
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
