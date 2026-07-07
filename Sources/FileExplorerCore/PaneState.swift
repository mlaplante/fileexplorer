import Foundation
import Observation

@MainActor
@Observable
public final class PaneState {
    public private(set) var history: NavigationHistory
    public var entries: [FileEntry] = [] {
        didSet { recomputeVisible() }
    }
    /// Note: cleared on navigation, but a watcher-triggered reload keeps the
    /// existing selection even if some selected files no longer exist.
    public var selection = Set<URL>()
    public var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)
    ] {
        didSet { recomputeVisible() }
    }
    public var showHidden = false
    public var errorMessage: String?
    /// False until the first reload attempt finishes; lets the UI avoid
    /// flashing an "empty" state while the initial load is in flight.
    public private(set) var hasLoadedOnce = false

    public var filter = FilterState() {
        didSet { recomputeVisible() }
    }

    /// UI draft for the extension filter field; parsed into `filter.extensions`
    /// on every edit ("png, .JPG" → ["png", "jpg"]).
    public var filterExtensionsText = "" {
        didSet {
            filter.extensions = Set(
                filterExtensionsText.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                    .filter { !$0.isEmpty })
        }
    }

    /// Filtered and sorted snapshot of `entries`. Stored rather than computed
    /// so SwiftUI body evaluations don't re-sort/re-filter large directories;
    /// refreshed when `entries`, `sortOrder`, or `filter` changes.
    public private(set) var visibleEntries: [FileEntry] = []

    /// Count before filtering — the "M" in the status bar's "N of M items".
    public var totalCount: Int { entries.count }

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
            if hasLoadedOnce,
               !FileManager.default.fileExists(atPath: url.path),
               let fallback = url.ancestorChain.reversed().dropFirst()
                   .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                await navigate(to: fallback)
                return
            }
            entries = []
            errorMessage = Self.describe(error)
            hasLoadedOnce = true
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let underlyingPosix = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let isCocoaPermission = nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileReadNoPermissionError
        let isPosixPermission = underlyingPosix?.domain == NSPOSIXErrorDomain
            && (underlyingPosix?.code == Int(EACCES) || underlyingPosix?.code == Int(EPERM))
        guard isCocoaPermission || isPosixPermission else { return error.localizedDescription }
        return error.localizedDescription
            + " Grant Full Disk Access to FileExplorer in System Settings"
            + " → Privacy & Security → Full Disk Access."
    }

    public func clearFilters() {
        filterExtensionsText = ""
        filter = FilterState()
    }

    private func recomputeVisible() {
        visibleEntries = FileSorter.sort(
            FilterEngine.apply(filter, to: entries), using: sortOrder)
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
