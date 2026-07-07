import Foundation
import Observation

@MainActor
@Observable
public final class PaneState {
    public private(set) var history: NavigationHistory
    public var entries: [FileEntry] = [] {
        didSet { applySort() }
    }
    public var selection = Set<URL>()
    public var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)
    ] {
        didSet { applySort() }
    }
    public var showHidden = false
    public var errorMessage: String?

    /// Sorted snapshot of `entries`. Stored rather than computed so SwiftUI
    /// body evaluations don't re-sort large directories; refreshed only when
    /// `entries` or `sortOrder` changes.
    public private(set) var visibleEntries: [FileEntry] = []

    private let watcher = DirectoryWatcher()

    public var currentURL: URL { history.current }
    public var canGoBack: Bool { history.canGoBack }
    public var canGoForward: Bool { history.canGoForward }
    public var canGoUp: Bool { currentURL.path != "/" }

    public init(url: URL) {
        // Standardize so NavigationHistory's exact-URL-equality no-op check
        // works for equivalent paths (trailing slash, "." components).
        history = NavigationHistory(current: url.standardizedFileURL)
    }

    /// Call once from the UI to begin watching; tests skip this.
    public func start() {
        watchCurrent()
    }

    public func navigate(to url: URL) async {
        history.navigate(to: url.standardizedFileURL)
        await afterNavigation()
    }

    public func goBack() async {
        history.goBack()
        await afterNavigation()
    }

    public func goForward() async {
        history.goForward()
        await afterNavigation()
    }

    public func goUp() async {
        guard canGoUp else { return }
        await navigate(to: currentURL.deletingLastPathComponent())
    }

    public func reload() async {
        let url = currentURL
        let includeHidden = showHidden
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try DirectoryLoader.load(url, includeHidden: includeHidden)
            }.value
            entries = loaded
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func applySort() {
        visibleEntries = FileSorter.sort(entries, using: sortOrder)
    }

    private func afterNavigation() async {
        selection.removeAll()
        watchCurrent()
        await reload()
    }

    private func watchCurrent() {
        watcher.watch(currentURL) { [weak self] in
            Task { await self?.reload() }
        }
    }
}
