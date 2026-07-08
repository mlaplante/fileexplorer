import Foundation

/// One-shot NSMetadataQuery wrapper for content search, scoped to a folder.
/// NSMetadataQuery needs the main run loop, hence @MainActor. Starting a new
/// search cancels the previous one. Completion always runs on the main actor.
@MainActor
public final class SpotlightSearcher {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    public init() {}

    public func search(term: String, in folder: URL,
                       completion: @escaping @MainActor ([URL]) -> Void) {
        cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@",
                                      trimmed)
        query.searchScopes = [folder]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Read the query back through self: capturing the local
                // NSMetadataQuery (non-Sendable) in this @Sendable closure
                // trips Swift 6 region isolation; the @MainActor class is
                // Sendable, so hopping through it is legal and equivalent
                // (cancel() replaced/cleared it iff a newer search started,
                // in which case this stale gather must be dropped anyway).
                guard let self, let query = self.query else { return }
                query.disableUpdates()
                let urls = (0..<query.resultCount).compactMap { index -> URL? in
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(
                              forAttribute: NSMetadataItemPathKey) as? String
                    else { return nil }
                    return URL(fileURLWithPath: path)
                }
                self.cancel()
                completion(urls)
            }
        }
        self.query = query
        query.start()
    }

    public func cancel() {
        query?.stop()
        query = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
