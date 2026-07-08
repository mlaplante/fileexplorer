import Foundation
import Observation
import CoreGraphics
import UniformTypeIdentifiers

/// Metadata and render state for Finder-style preview pane content.
/// Owned by TabState so SwiftUI view structs do not own async render state.
@MainActor
@Observable
public final class PreviewPaneModel {
    public private(set) var selectionCount = 0
    public private(set) var info: ItemInfo?
    public private(set) var previewImage: CGImage?
    public private(set) var isLoading = false

    private var generation = 0

    public init() {}

    public func update(selection: Set<URL>, entries: [FileEntry]) {
        generation += 1
        selectionCount = selection.count
        info = nil
        previewImage = nil
        isLoading = selection.count == 1
        let myGeneration = generation

        guard selection.count == 1, let url = selection.first else {
            isLoading = false
            return
        }

        let entry = entries.first { $0.url.standardizedFileURL == url.standardizedFileURL }
        Task {
            let gathered = await Task.detached(priority: .userInitiated) {
                let isPDF = entry?.contentType?.conforms(to: .pdf) == true
                let image = isPDF
                    ? PreviewRenderer.pdfFirstPage(at: url, maxDimension: 512)
                    : PreviewRenderer.downsampledImage(at: url, maxDimension: 512)
                return (InfoGatherer.info(for: url), image)
            }.value
            guard myGeneration == self.generation else { return }
            info = gathered.0
            previewImage = gathered.1
            isLoading = false
        }
    }
}
