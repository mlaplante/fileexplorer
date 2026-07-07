import Foundation
import Observation

@MainActor
@Observable
public final class PaneState {
    public private(set) var history: NavigationHistory
    /// Invoked after every completed navigation (navigate/back/forward/up)
    /// with the new current URL; used by the session layer to record recents.
    public var onNavigated: (@MainActor (URL) -> Void)?
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

    public enum ViewMode: String, Sendable {
        case list
        case icons
    }

    /// List vs thumbnail-grid presentation; per pane, remembered per tab.
    public var viewMode: ViewMode = .list
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

    /// Window-level UndoManager, injected by the UI (or tests).
    @ObservationIgnored public weak var undoManager: UndoManager?

    public init(url: URL) {
        // Standardize so NavigationHistory's exact-URL-equality no-op check
        // works for equivalent paths (trailing slash, "." components).
        history = NavigationHistory(current: url.standardizedFileURL)
    }

    private var started = false

    /// Begin watching and load once; safe to call every time the pane's view
    /// appears — only the first call does anything.
    public func startIfNeeded() {
        guard !started else { return }
        started = true
        watchCurrent()
        Task { await reload() }
    }

    public func navigate(to url: URL) async {
        guard url.standardizedFileURL != currentURL else { return }
        history.navigate(to: url.standardizedFileURL)
        await afterNavigation()
    }

    public func goBack() async {
        guard canGoBack else { return }
        history.goBack()
        await afterNavigation()
    }

    public func goForward() async {
        guard canGoForward else { return }
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

    // NOTE: in each wrapper below, `reload()` runs BEFORE the error/undo
    // bookkeeping rather than after. `reload()` sets `errorMessage = nil` on
    // a successful directory load; running it last would clobber the
    // op-failure message these methods are responsible for surfacing.
    // `reload()` doesn't touch `selection`, so this reordering is safe.

    public func moveSelected(_ urls: [URL], into destination: URL) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.move(urls, into: destination)
        }.value
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordMove(
                successes.map { (from: $0.source, to: $0.destination) },
                on: undoManager, pane: self)
        }
    }

    public func copySelected(_ urls: [URL], into destination: URL) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.copy(urls, into: destination)
        }.value
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordCreation(successes.map(\.destination),
                                        actionName: "Copy",
                                        on: undoManager, pane: self)
        }
    }

    public func trashSelected(_ urls: [URL]) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.trash(urls)
        }.value
        selection.removeAll()
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordTrash(
                successes.map { (original: $0.source, trashed: $0.destination) },
                on: undoManager, pane: self)
        }
    }

    public func renameSelected(_ url: URL, to newName: String) async {
        let result = FileOperationService.rename(url, to: newName)
        await reload()
        switch result {
        case .success(let newURL):
            if let undoManager {
                UndoRecorder.recordMove([(from: url, to: newURL)],
                                        on: undoManager, pane: self)
                undoManager.setActionName("Rename")
            }
            errorMessage = nil
            selection = [newURL.standardizedFileURL]
        case .failure(let error):
            errorMessage = error.message
        }
    }

    public func createNewFolder() async {
        let result = FileOperationService.newFolder(in: currentURL)
        await reload()
        switch result {
        case .success(let url):
            if let undoManager {
                UndoRecorder.recordCreation([url], actionName: "New Folder",
                                            on: undoManager, pane: self)
            }
            errorMessage = nil
            selection = [url.standardizedFileURL]
        case .failure(let error):
            errorMessage = error.message
        }
    }

    private struct OperationSuccess {
        let source: URL
        let destination: URL
    }

    private func finishOperation(
        results: [FileOperationService.ItemResult],
        recordUndo: ([OperationSuccess]) -> Void
    ) {
        let successes = results.compactMap { result -> OperationSuccess? in
            if case .success(let url) = result.outcome {
                return OperationSuccess(source: result.source, destination: url)
            }
            return nil
        }
        let failures = results.filter {
            if case .failure = $0.outcome { return true }
            return false
        }
        if failures.isEmpty {
            errorMessage = nil
        } else {
            let details = failures.prefix(3).compactMap { result -> String? in
                if case .failure(let error) = result.outcome { return error.message }
                return nil
            }.joined(separator: " ")
            let suffix = failures.count > 3 ? " (+\(failures.count - 3) more)" : ""
            errorMessage = details + suffix
        }
        recordUndo(successes)
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
        onNavigated?(currentURL)
    }

    private func watchCurrent() {
        watcher.watch(currentURL) { [weak self] in
            Task { await self?.reload() }
        }
    }
}
