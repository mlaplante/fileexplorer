import Foundation
import Observation

@MainActor
@Observable
public final class PaneState {
    public private(set) var history: NavigationHistory
    public var entries: [FileEntry] = [] {
        didSet { applySort() }
    }
    /// Note: cleared on navigation, but a watcher-triggered reload keeps the
    /// existing selection even if some selected files no longer exist.
    public var selection = Set<URL>()
    public var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)
    ] {
        didSet { applySort() }
    }
    public var showHidden = false
    public var errorMessage: String?
    /// False until the first reload attempt finishes; lets the UI avoid
    /// flashing an "empty" state while the initial load is in flight.
    public private(set) var hasLoadedOnce = false

    /// Sorted snapshot of `entries`. Stored rather than computed so SwiftUI
    /// body evaluations don't re-sort large directories; refreshed only when
    /// `entries` or `sortOrder` changes.
    public private(set) var visibleEntries: [FileEntry] = []

    private let watcher = DirectoryWatcher()
    private var reloadID = 0

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
        guard url.standardizedFileURL != currentURL else { return }
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
        reloadID += 1
        let myID = reloadID
        let url = currentURL
        let includeHidden = showHidden
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try DirectoryLoader.load(url, includeHidden: includeHidden)
            }.value
            guard myID == reloadID else { return }
            entries = loaded
            errorMessage = nil
            hasLoadedOnce = true
        } catch {
            guard myID == reloadID else { return }
            entries = []
            errorMessage = error.localizedDescription
            hasLoadedOnce = true
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
