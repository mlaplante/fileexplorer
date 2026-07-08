import Foundation
import Observation

/// Backs the Get Info panel: re-gathers ItemInfos whenever the observed
/// selection changes. Gathering runs detached; a generation counter drops
/// stale results (same pattern as PaneState.reload).
@MainActor
@Observable
public final class GetInfoModel {
    public private(set) var infos: [ItemInfo] = []
    public private(set) var sha256: String?
    public private(set) var isHashing = false
    public var commentDraft = ""
    public private(set) var commentError: String?
    /// Sum of regular-file sizes across the selection (folders excluded).
    public var totalFileSize: Int64 {
        infos.compactMap(\.size).reduce(0, +)
    }

    private var generation = 0

    public init() {}

    public func update(for urls: [URL]) {
        generation += 1
        sha256 = nil
        isHashing = false
        commentDraft = ""
        commentError = nil
        let myGeneration = generation
        let targets = urls.sorted { $0.path < $1.path }
        Task {
            let gathered = await Task.detached(priority: .userInitiated) {
                targets.compactMap { InfoGatherer.info(for: $0) }
            }.value
            guard myGeneration == self.generation else { return }
            self.infos = gathered
            self.commentDraft = gathered.count == 1
                ? (gathered.first?.finderComment ?? "") : ""
        }
    }

    public func computeChecksum() {
        guard infos.count == 1, let info = infos.first, !info.isDirectory else { return }
        let url = info.url
        generation += 1
        let myGeneration = generation
        isHashing = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileHasher.sha256(of: url)
            }.value
            guard myGeneration == self.generation else { return }
            isHashing = false
            if case .success(let hash) = result { sha256 = hash }
        }
    }

    public func commitComment() {
        guard infos.count == 1, let info = infos.first else { return }
        switch CommentWriter.write(commentDraft, to: info.url) {
        case .success:
            commentError = nil
            infos[0] = InfoGatherer.info(for: info.url) ?? info
            commentDraft = infos[0].finderComment ?? ""
        case .failure(let error):
            commentError = error.message
        }
    }
}
