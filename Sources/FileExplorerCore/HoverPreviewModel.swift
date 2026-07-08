import Foundation
import Observation
import UniformTypeIdentifiers
import CoreGraphics

/// Debounced hover state for image/PDF/text row previews: present after `delay`
/// of continuous hover, cancel on exit, retarget on row change. Owns the
/// rendered image too — render state must NOT live on view structs, which
/// SwiftUI re-initializes on parent re-render (and `.task(id:)` would not
/// re-fire, freezing a spinner).
@MainActor
@Observable
public final class HoverPreviewModel {
    public private(set) var presented: FileEntry?
    public private(set) var presentedImage: CGImage?
    public private(set) var presentedText: String?

    public typealias Renderer = @Sendable (URL, _ type: UTType?) async -> PreviewContent?

    public enum PreviewContent: Sendable {
        case image(CGImage)
        case text(String)
    }

    private let delay: Duration
    private let renderer: Renderer
    private var pending: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(500),
                renderer: @escaping Renderer = HoverPreviewModel.defaultRenderer) {
        self.delay = delay
        self.renderer = renderer
    }

    /// Production renderer: PreviewRenderer off the main actor.
    public static let defaultRenderer: Renderer = { url, type in
        await Task.detached(priority: .userInitiated) {
            // 1920px ≈ the popover's 960pt ceiling at 2x, so previews stay
            // crisp on Retina displays.
            let isPDF = type?.conforms(to: .pdf) == true
            if let image = isPDF
                ? PreviewRenderer.pdfFirstPage(at: url, maxDimension: 1920)
                : PreviewRenderer.downsampledImage(at: url, maxDimension: 1920) {
                return .image(image)
            }
            return PreviewRenderer.textPreview(at: url, type: type).map(PreviewContent.text)
        }.value
    }

    public static func isPreviewable(_ entry: FileEntry) -> Bool {
        guard !entry.isDirectory, let type = entry.contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
            || ContentScanner.isTextLike(type, pathExtension: entry.url.pathExtension)
    }

    public func hoverBegan(_ entry: FileEntry) {
        pending?.cancel()
        guard Self.isPreviewable(entry) else {
            presented = nil
            presentedImage = nil
            presentedText = nil
            return
        }
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            presented = entry
            presentedImage = nil
            presentedText = nil
            let url = entry.url
            let rendered = await renderer(url, entry.contentType)
            guard !Task.isCancelled, presented?.url == url else { return }
            switch rendered {
            case .image(let image):
                presentedImage = image
            case .text(let text):
                presentedText = text
            case nil:
                break
            }
        }
    }

    public func hoverEnded() {
        pending?.cancel()
        pending = nil
        presented = nil
        presentedImage = nil
        presentedText = nil
    }
}
