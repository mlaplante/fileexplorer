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
