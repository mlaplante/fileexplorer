import Foundation
import Observation

/// Backs the Get Info panel: re-gathers ItemInfos whenever the observed
/// selection changes. Gathering runs detached; a generation counter drops
/// stale results (same pattern as PaneState.reload).
@MainActor
@Observable
public final class GetInfoModel {
    public private(set) var infos: [ItemInfo] = []
    /// Sum of regular-file sizes across the selection (folders excluded).
    public var totalFileSize: Int64 {
        infos.compactMap(\.size).reduce(0, +)
    }

    private var generation = 0

    public init() {}

    public func update(for urls: [URL]) {
        generation += 1
        let myGeneration = generation
        let targets = urls.sorted { $0.path < $1.path }
        Task {
            let gathered = await Task.detached(priority: .userInitiated) {
                targets.compactMap { InfoGatherer.info(for: $0) }
            }.value
            guard myGeneration == self.generation else { return }
            self.infos = gathered
        }
    }
}
