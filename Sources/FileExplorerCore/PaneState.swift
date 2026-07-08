import Foundation
import Observation

@MainActor
@Observable
public final class PaneState {
    /// Hover-preview state; owned here because view structs are re-inited on
    /// every parent render on this toolchain (M5 deferred hoisting).
    public let hoverPreview = HoverPreviewModel()
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
    /// Last plain-clicked item in the icon grid; anchors ⇧-click ranges.
    /// Transient (not persisted); the resolver degrades to plain-click when
    /// the anchor is no longer in visibleEntries.
    @ObservationIgnored public var selectionAnchor: URL?
    /// Selection as of the last non-shift click; shift-ranges recompute from
    /// this pivot so they can shrink as well as grow (Finder behavior).
    @ObservationIgnored public var selectionPivot = Set<URL>()
    public var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)
    ] {
        didSet { recomputeVisible() }
    }
    public var showHidden = false {
        didSet {
            guard oldValue != showHidden, started else { return }
            Task { await reload() }
        }
    }

    public enum ViewMode: String, Sendable, Codable {
        case list
        case icons
    }

    /// List vs thumbnail-grid presentation; per pane, remembered per tab.
    public var viewMode: ViewMode = .list
    public var errorMessage: String?
    /// Failure summary from the most recent file OPERATION (move/copy/trash/
    /// rename/new folder) — distinct from `errorMessage`, which reports
    /// folder-LOAD failures and drives the full-pane overlay. Cleared on the
    /// next successful operation and on navigation.
    public private(set) var opErrorMessage: String?

    /// Lets `UndoRecorder` surface a failure discovered while performing an
    /// undo/redo restore, through the same channel forward operations use.
    /// (Chosen over widening `opErrorMessage`'s setter access because the
    /// write is conceptually an action PaneState performs on itself, just
    /// triggered from UndoRecorder's callback.)
    func reportOpFailure(_ message: String) {
        opErrorMessage = message
    }

    /// Same channel, callable from the app layer's tag submenu (tag writes
    /// happen outside PaneState's own operation wrappers).
    public func reportTagFailure(_ message: String) {
        opErrorMessage = message
    }

    /// False until the first reload attempt finishes; lets the UI avoid
    /// flashing an "empty" state while the initial load is in flight.
    public private(set) var hasLoadedOnce = false

    /// On-demand recursive folder sizes (context menu → Calculate Size),
    /// keyed by standardized URL; cleared on navigation.
    public private(set) var folderSizes: [URL: Int64] = [:]

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

    /// Transient popover visibility for the filter bar's custom-range editors
    /// (no @State on this toolchain; deliberately NOT read by snapshot()).
    public var showsCustomDatePopover = false
    public var showsCustomSizePopover = false

    /// Transient new-tag popover state (context submenu → free-text entry;
    /// deliberately NOT read by snapshot()).
    public var showsNewTagPopover = false
    public var newTagDraft = ""
    /// Targets captured when "New Tag…" is chosen — the grid's context menu
    /// doesn't sync `selection` to the right-clicked item, so the popover
    /// must not re-read `selection` at Add-click time.
    public var newTagTargets: [URL] = []

    /// Transient save-preset popover state (no @State on this toolchain;
    /// deliberately NOT read by snapshot()).
    public var showsSavePresetPopover = false
    public var savePresetNameDraft = ""

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

    /// Restore from a saved snapshot. Setting `filter` before
    /// `filterExtensionsText` matters: the text's `didSet` re-derives
    /// `filter.extensions`, making the draft field the source of truth.
    public convenience init(snapshot: SessionSnapshot.Pane, fallback: URL) {
        self.init(url: snapshot.resolvedURL(fallback: fallback))
        showHidden = snapshot.showHidden
        viewMode = ViewMode(rawValue: snapshot.viewMode) ?? .list
        filter = snapshot.filter
        filterExtensionsText = snapshot.filterExtensionsText
        sortOrder = SortTokenCoder.comparators(from: snapshot.sort)
    }

    // A window-scoped UndoManager outlives closed tabs' panes, and
    // registerUndo does NOT retain its target — without this, an undo/redo
    // invoked after a pane is deallocated would crash on a dangling target.
    isolated deinit {
        undoManager?.removeAllActions(withTarget: self)
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
    // bookkeeping rather than after. `reload()` itself only touches
    // `errorMessage` (the folder-LOAD-failure channel), not `opErrorMessage`
    // — but if the current directory has vanished, `reload()`'s fallback
    // path calls `navigate(to:)` → `afterNavigation()`, which clears
    // `opErrorMessage`. Running `reload()` first ensures the bookkeeping
    // below — which sets `opErrorMessage` for this operation — has the
    // last word. `reload()` doesn't touch `selection`, so this reordering
    // is safe.

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
                                        actionName: "Rename",
                                        on: undoManager, pane: self)
            }
            opErrorMessage = nil
            selection = [newURL.standardizedFileURL]
        case .failure(let error):
            opErrorMessage = error.message
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
            opErrorMessage = nil
            selection = [url.standardizedFileURL]
        case .failure(let error):
            opErrorMessage = error.message
        }
    }

    public func createNewFile() async {
        let result = FileOperationService.newFile(in: currentURL)
        await reload()
        switch result {
        case .success(let url):
            if let undoManager {
                UndoRecorder.recordCreation([url], actionName: "New File",
                                            on: undoManager, pane: self)
            }
            opErrorMessage = nil
            selection = [url.standardizedFileURL]
        case .failure(let error):
            opErrorMessage = error.message
        }
    }

    /// Duplicates each item next to itself ("name copy.ext"), selects the
    /// duplicates, one undo step (trash the copies).
    public func duplicateSelected(_ urls: [URL]) async {
        let results = await Task.detached(priority: .userInitiated) {
            urls.flatMap { url in
                FileOperationService.copyAvoidingCollisions(
                    [url], into: url.deletingLastPathComponent())
            }
        }.value
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordCreation(successes.map(\.destination),
                                        actionName: "Duplicate",
                                        on: undoManager, pane: self)
        }
        let created = results.compactMap { result -> URL? in
            if case .success(let url) = result.outcome { return url }
            return nil
        }
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }

    /// Paste-as-copy into the current folder: collisions auto-rename
    /// (Finder ⌘V). Paste-as-move (⌥⌘V) reuses `moveSelected`, whose
    /// fail-loudly collision policy matches Finder's move-paste prompt.
    public func pasteCopy(_ urls: [URL]) async {
        let destination = currentURL
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.copyAvoidingCollisions(urls, into: destination)
        }.value
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordCreation(successes.map(\.destination),
                                        actionName: "Paste",
                                        on: undoManager, pane: self)
        }
        let created = results.compactMap { result -> URL? in
            if case .success(let url) = result.outcome { return url }
            return nil
        }
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }

    /// Applies the plan's clean items; conflicted items are skipped and
    /// reported, `.unchanged` items are skipped silently. One undo step.
    public func batchRename(_ urls: [URL], rules: RenameRules,
                            metadata: [URL: RenameTokenMetadata] = [:]) async {
        let existing = Set(entries.map(\.name))
        let plan = RenamePlan.plan(urls: urls, rules: rules,
                                   existingNames: existing, metadata: metadata)
        let outcome = RenameExecutor.execute(plan)
        if let undoManager, !outcome.pairs.isEmpty {
            UndoRecorder.recordMove(outcome.pairs, actionName: "Batch Rename",
                                    on: undoManager, pane: self)
        }
        await reload()
        opErrorMessage = outcome.failures.isEmpty
            ? nil
            : outcome.failures.prefix(3).joined(separator: " ")
                + (outcome.failures.count > 3 ? " (+\(outcome.failures.count - 3) more)" : "")
        if !outcome.pairs.isEmpty {
            selection = Set(outcome.pairs.map { $0.to.standardizedFileURL })
        }
    }

    public func convertSelected(_ urls: [URL], to format: ImageConverter.Format,
                                jpegQuality: Double = 0.85) async {
        let quality = jpegQuality
        let results = await Task.detached(priority: .userInitiated) {
            ImageConverter.convert(urls, to: format, jpegQuality: quality)
        }.value
        let created = results.compactMap { result -> URL? in
            if case .success(let url) = result.outcome { return url }
            return nil
        }
        let failures = results.compactMap { result -> String? in
            if case .failure(let error) = result.outcome { return error.message }
            return nil
        }
        if let undoManager, !created.isEmpty {
            UndoRecorder.recordCreation(created, actionName: "Convert Image",
                                        on: undoManager, pane: self)
        }
        await reload()
        opErrorMessage = failures.isEmpty
            ? nil
            : failures.prefix(3).joined(separator: " ")
                + (failures.count > 3 ? " (+\(failures.count - 3) more)" : "")
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }

    public func compressSelected(_ urls: [URL]) async {
        let destination = currentURL
        let result = await Task.detached(priority: .userInitiated) {
            Zipper.compress(urls, in: destination)
        }.value
        await reload()
        switch result {
        case .success(let archive):
            if let undoManager {
                UndoRecorder.recordCreation([archive], actionName: "Compress",
                                            on: undoManager, pane: self)
            }
            opErrorMessage = nil
            selection = [archive.standardizedFileURL]
        case .failure(let error):
            opErrorMessage = error.message
        }
    }

    public func extractSelected(_ urls: [URL]) async {
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { (source: $0, result: Unarchiver.extract($0)) }
        }.value
        await reload()
        let created = results.compactMap { item -> URL? in
            if case .success(let url) = item.result { return url }
            return nil
        }
        let failures = results.compactMap { item -> String? in
            if case .failure(let error) = item.result { return error.message }
            return nil
        }
        if let undoManager, !created.isEmpty {
            UndoRecorder.recordCreation(created, actionName: "Extract",
                                        on: undoManager, pane: self)
        }
        opErrorMessage = failures.isEmpty
            ? nil
            : failures.prefix(3).joined(separator: " ")
                + (failures.count > 3 ? " (+\(failures.count - 3) more)" : "")
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
    }

    /// Icon-grid click handling: Finder-style plain/⌘/⇧ semantics plus
    /// anchor+pivot bookkeeping. A ⇧-click whose anchor is missing or stale
    /// degrades to a plain click AND establishes the anchor, so a range can
    /// start from a shift-click.
    public func clickSelect(_ url: URL, commandDown: Bool, shiftDown: Bool) {
        let ordered = visibleEntries.map(\.url)
        let anchorUsable = shiftDown && !commandDown
            && selectionAnchor.map(ordered.contains) == true
        selection = SelectionResolver.resolve(
            clicked: url, in: ordered, current: selection,
            baseline: selectionPivot, anchor: selectionAnchor,
            commandDown: commandDown, shiftDown: shiftDown)
        if !anchorUsable {
            selectionAnchor = url
            selectionPivot = selection
        }
    }

    /// Menu/keyboard "Open": a single selected folder navigates; anything
    /// else opens with the default application.
    public func openSelection(_ openExternally: (URL) -> Void) async {
        let targets = Array(selection)
        if targets.count == 1, let url = targets.first,
           entries.first(where: {
               $0.url.standardizedFileURL.path == url.standardizedFileURL.path
           })?.isDirectory == true {
            await navigate(to: url)
        } else {
            for url in targets { openExternally(url) }
        }
    }

    public func calculateFolderSizes(_ urls: [URL]) async {
        let targets = urls.map(\.standardizedFileURL)
        let sizes = await Task.detached(priority: .userInitiated) {
            targets.map { ($0, FolderSizer.size(of: $0)) }
        }.value
        for (url, size) in sizes {
            folderSizes[url] = size
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
            opErrorMessage = nil
        } else {
            let details = failures.prefix(3).compactMap { result -> String? in
                if case .failure(let error) = result.outcome { return error.message }
                return nil
            }.joined(separator: " ")
            let suffix = failures.count > 3 ? " (+\(failures.count - 3) more)" : ""
            opErrorMessage = details + suffix
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

    public func snapshot() -> SessionSnapshot.Pane {
        SessionSnapshot.Pane(
            path: currentURL.path,
            showHidden: showHidden,
            viewMode: viewMode.rawValue,
            filter: filter,
            filterExtensionsText: filterExtensionsText,
            sort: SortTokenCoder.tokens(from: sortOrder))
    }

    private func recomputeVisible() {
        visibleEntries = FileSorter.sort(
            FilterEngine.apply(filter, to: entries), using: sortOrder)
    }

    private func afterNavigation() async {
        selection.removeAll()
        opErrorMessage = nil
        folderSizes.removeAll()
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
