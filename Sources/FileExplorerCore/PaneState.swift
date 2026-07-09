import Foundation
import Observation
import AppKit

@MainActor
@Observable
public final class PaneState {
    public let id = UUID()
    /// Hover-preview state; owned here because view structs are re-inited on
    /// every parent render on this toolchain (M5 deferred hoisting).
    public let hoverPreview = HoverPreviewModel()
    public let columnsModel = ColumnsModel()
    public let springLoad = SpringLoadModel()
    public let gitStatus = GitStatusModel()
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
        didSet {
            recomputeVisible()
            persistFolderViewSettings()
        }
    }
    public var groupBy: Grouper.Axis = .none {
        didSet {
            recomputeVisible()
            persistFolderViewSettings()
        }
    }
    public var showHidden = false {
        didSet {
            persistFolderViewSettings()
            guard oldValue != showHidden, started else { return }
            Task { await reload() }
        }
    }

    public enum ViewMode: String, Sendable, Codable {
        case list
        case icons
        case columns
    }

    /// List vs thumbnail-grid presentation; per pane, remembered per tab.
    public var viewMode: ViewMode = .list {
        didSet {
            recomputeVisible()
            persistFolderViewSettings()
        }
    }
    public var errorMessage: String?
    public var availableSpaceText: String?
    public var pendingRenameURL: URL?
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

    // MARK: - List-view tree expansion
    // All tree keys are standardized PATH STRINGS (`treeKey(_:)`), never
    // URLs: directory URLs from contentsOfDirectory carry a trailing slash,
    // URLs built via appendingPathComponent don't, and Set<URL> membership
    // compares absolute strings — URL keys would silently never match.

    /// Folders disclosed in the list view. Collapsing a parent does NOT
    /// remove descendants — re-expanding the parent restores the subtree
    /// (Finder behavior); the flattener simply stops producing their rows.
    public private(set) var expandedFolders: Set<String> = []
    /// Raw loaded children per expanded folder (unfiltered/unsorted; the
    /// pane's filter+sort applies per level at flatten time).
    @ObservationIgnored private var childEntries: [String: [FileEntry]] = [:]
    /// One kqueue watcher per expanded folder so disclosed rows live-update.
    @ObservationIgnored private var childWatchers: [String: DirectoryWatcher] = [:]
    /// Depth per visible row URL (0 = top level), rebuilt with visibleEntries.
    public private(set) var rowDepths: [URL: Int] = [:]
    /// Top-level row count — the status bar's "N items" must not grow when
    /// folders are merely disclosed.
    public private(set) var rootVisibleCount = 0

    /// Canonical tree key: trailing-slash-insensitive standardized path.
    private static func treeKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

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
    @ObservationIgnored public weak var shareAnchor: NSView?
    /// Targets captured when "New Tag…" is chosen — the grid's context menu
    /// doesn't sync `selection` to the right-clicked item, so the popover
    /// must not re-read `selection` at Add-click time.
    public var newTagTargets: [URL] = []

    /// Transient save-preset popover state (no @State on this toolchain;
    /// deliberately NOT read by snapshot()).
    public var showsSavePresetPopover = false
    public var savePresetNameDraft = ""
    public var showsSaveSmartFolderPopover = false
    public var saveSmartFolderNameDraft = ""

    /// Transient rubber-band drag state for the icon grid (view-layer
    /// geometry; deliberately NOT read by snapshot()).
    @ObservationIgnored public var rubberBandFrames: [URL: CGRect] = [:]
    public var rubberBandRect: CGRect?
    @ObservationIgnored public var rubberBandBase = Set<URL>()
    @ObservationIgnored public var rubberBandUnion = false

    /// Filtered and sorted snapshot of `entries`. Stored rather than computed
    /// so SwiftUI body evaluations don't re-sort/re-filter large directories;
    /// refreshed when `entries`, `sortOrder`, or `filter` changes.
    public private(set) var visibleEntries: [FileEntry] = []
    public private(set) var groupedEntries: [FileGroup] = [
        FileGroup(title: nil, entries: [])
    ]

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
    @ObservationIgnored public var trashRegistry: TrashRegistryModel?
    @ObservationIgnored public var settingsModel: SettingsModel?
    @ObservationIgnored public var operationQueue: OperationQueueModel?

    public init(url: URL) {
        // Standardize so NavigationHistory's exact-URL-equality no-op check
        // works for equivalent paths (trailing slash, "." components).
        history = NavigationHistory(current: url.standardizedFileURL)
        gitStatus.onChange = { [weak self] in
            self?.recomputeVisible()
        }
    }

    /// Restore from a saved snapshot. Setting `filter` before
    /// `filterExtensionsText` matters: the text's `didSet` re-derives
    /// `filter.extensions`, making the draft field the source of truth.
    public convenience init(snapshot: SessionSnapshot.Pane, fallback: URL) {
        self.init(url: snapshot.resolvedURL(fallback: fallback))
        showHidden = snapshot.showHidden
        viewMode = ViewMode(rawValue: snapshot.viewMode) ?? .list
        groupBy = snapshot.groupBy
        filter = snapshot.filter
        filterExtensionsText = snapshot.filterExtensionsText
        sortOrder = SortTokenCoder.comparators(from: snapshot.sort)
        expandedFolders = Set(snapshot.expandedFolders.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
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
        applyStoredFolderViewSettings()
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
        gitStatus.refresh(for: url)
        do {
            let (loaded, spaceText) = try await Task.detached(priority: .userInitiated) {
                let entries = try DirectoryLoader.load(url, includeHidden: includeHidden)
                let spaceText = VolumeSpace.label(bytes: VolumeSpace.availableBytes(for: url))
                return (entries, spaceText)
            }.value
            guard myID == reloadID else { return }
            entries = loaded
            settingsModel?.mergeKnownTags(loaded.flatMap(\.tags))
            availableSpaceText = spaceText
            errorMessage = nil
            hasLoadedOnce = true
            await refreshExpandedChildren()
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
            availableSpaceText = nil
            errorMessage = Self.describe(error)
            hasLoadedOnce = true
        }
    }

    public func isExpanded(_ url: URL) -> Bool {
        expandedFolders.contains(Self.treeKey(url))
    }

    public func depth(of url: URL) -> Int { rowDepths[url] ?? 0 }

    public func gitState(for entry: FileEntry) -> GitFileState {
        gitStatus.index?.state(for: entry.url) ?? .clean
    }

    public func isGitIgnored(_ entry: FileEntry) -> Bool {
        gitStatus.index?.isIgnored(entry.url) ?? false
    }

    public func toggleExpansion(of url: URL, recursively: Bool = false) async {
        if isExpanded(url) {
            collapse(url)
        } else if recursively {
            await expandRecursively(url)
        } else {
            await expand(url)
        }
    }

    public func expand(_ url: URL) async {
        let key = Self.treeKey(url)
        guard !expandedFolders.contains(key) else { return }
        expandedFolders.insert(key)
        watchChildren(of: key)
        await loadChildren(of: key)
        recomputeVisible()
    }

    /// Opens the folder and every descendant folder, breadth-first, capped
    /// at 512 folders so a giant tree can't hang the pane.
    public func expandRecursively(_ url: URL) async {
        var queue = [Self.treeKey(url)]
        var visited = Set<String>()
        var opened = 0
        while !queue.isEmpty, opened < 512 {
            let key = queue.removeFirst()
            // Resolve symlinks so a link cycle can't re-enqueue forever.
            let resolved = URL(fileURLWithPath: key)
                .resolvingSymlinksInPath().path
            guard visited.insert(resolved).inserted else { continue }
            expandedFolders.insert(key)
            watchChildren(of: key)
            await loadChildren(of: key)
            opened += 1
            for child in childEntries[key] ?? [] where child.isDirectory {
                queue.append(Self.treeKey(child.url))
            }
        }
        recomputeVisible()
    }

    public func collapse(_ url: URL) {
        let key = Self.treeKey(url)
        guard expandedFolders.remove(key) != nil else { return }
        // An invisible selection must never feed file operations: fold any
        // selected rows hidden by this collapse into selecting the folder.
        // Insert the folder's ROW url (visibleEntries), not the caller's —
        // Table selection matches by URL equality, and the row URL may carry
        // a trailing slash the caller's doesn't.
        let prefix = key + "/"
        let hidden = selection.filter {
            Self.treeKey($0).hasPrefix(prefix)
        }
        if !hidden.isEmpty {
            selection.subtract(hidden)
            let rowURL = visibleEntries.first {
                Self.treeKey($0.url) == key
            }?.url ?? url
            selection.insert(rowURL)
        }
        recomputeVisible()
    }

    /// Loads (or reloads) one expanded folder's children off the main actor.
    /// Unreadable or vanished folders silently drop their expansion — the
    /// row itself disappears via the parent's reload, so no error surface.
    private func loadChildren(of key: String) async {
        let includeHidden = showHidden
        let folder = URL(fileURLWithPath: key, isDirectory: true)
        let loaded = try? await Task.detached(priority: .userInitiated) {
            try DirectoryLoader.load(folder, includeHidden: includeHidden)
        }.value
        guard expandedFolders.contains(key) else { return } // collapsed mid-flight
        if let loaded {
            childEntries[key] = loaded
            settingsModel?.mergeKnownTags(loaded.flatMap(\.tags))
        } else {
            expandedFolders.remove(key)
            childEntries.removeValue(forKey: key)
            childWatchers.removeValue(forKey: key)?.stop()
        }
    }

    private func watchChildren(of key: String) {
        guard childWatchers[key] == nil else { return }
        let watcher = DirectoryWatcher()
        watcher.watch(URL(fileURLWithPath: key, isDirectory: true)) { [weak self] in
            guard let self, self.expandedFolders.contains(key) else { return }
            Task {
                await self.loadChildren(of: key)
                self.recomputeVisible()
            }
        }
        childWatchers[key] = watcher
    }

    /// Re-reads every expanded folder after a pane reload; folders that
    /// vanished drop out inside loadChildren.
    private func refreshExpandedChildren() async {
        for key in expandedFolders {
            await loadChildren(of: key)
            watchChildren(of: key)
        }
        recomputeVisible()
    }

    private func clearTreeState() {
        expandedFolders.removeAll()
        childEntries.removeAll()
        for watcher in childWatchers.values { watcher.stop() }
        childWatchers.removeAll()
        rowDepths.removeAll()
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
        selection.removeAll()
        await trash(urls: urls)
    }

    public func trash(urls: [URL]) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.trash(urls)
        }.value
        await reload()
        finishOperation(results: results) { successes in
            for success in successes {
                trashRegistry?.record(original: success.source,
                                      trashed: success.destination)
            }
            guard let undoManager else { return }
            UndoRecorder.recordTrash(
                successes.map { (original: $0.source, trashed: $0.destination) },
                on: undoManager, pane: self)
        }
    }

    public func putBackSelected(_ urls: [URL]) async {
        guard let trashRegistry else {
            opErrorMessage = "No trash registry is available."
            return
        }
        var successes: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for trashed in urls {
            guard let original = trashRegistry.original(forTrashed: trashed) else {
                failures.append("No original location recorded for “\(trashed.lastPathComponent)”.")
                continue
            }
            switch FileOperationService.relocate(trashed, toExactly: original) {
            case .success:
                successes.append((from: trashed, to: original))
                trashRegistry.remove(trashed: trashed)
            case .failure(let error):
                failures.append(error.message)
            }
        }
        selection.removeAll()
        await reload()
        if let undoManager {
            UndoRecorder.recordMove(successes, actionName: "Put Back",
                                    on: undoManager, pane: self)
        }
        opErrorMessage = OperationFailureSummary.message(failures)
    }

    public func executeResolvedPlan(_ plan: OperationConflictPlanner.Plan,
                                    actionName: String) async {
        let queueID = operationQueue?.enqueue(plan, title: actionName)
        if queueID != nil {
            _ = operationQueue?.startNext()
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            FileOperationService.execute(plan)
        }.value
        await reload()
        if let undoManager {
            let needsGrouping = !outcome.written.isEmpty
                && !outcome.replacedTrash.isEmpty
            if needsGrouping { undoManager.beginUndoGrouping() }
            UndoRecorder.recordTrash(outcome.replacedTrash,
                                     actionName: actionName,
                                     on: undoManager, pane: self)
            switch plan.operation {
            case .copy, .sync:
                UndoRecorder.recordCreation(outcome.created,
                                            actionName: actionName,
                                            on: undoManager, pane: self)
            case .move:
                UndoRecorder.recordMove(
                    outcome.written.map { (from: $0.source, to: $0.destination) },
                    actionName: actionName,
                    on: undoManager, pane: self)
            }
            if needsGrouping { undoManager.endUndoGrouping() }
        }
        opErrorMessage = OperationFailureSummary.message(outcome.failures)
        if !outcome.created.isEmpty {
            selection = Set(outcome.created.map(\.standardizedFileURL))
        }
        if let queueID {
            operationQueue?.updateProgress(
                id: queueID,
                completed: outcome.written.count + outcome.skipped.count
                    + outcome.failures.count,
                total: plan.items.count)
            if outcome.failures.isEmpty {
                operationQueue?.succeed(id: queueID)
            } else {
                operationQueue?.fail(
                    id: queueID,
                    failures: outcome.failures.map {
                        QueuedOperation.Failure(source: plan.destination,
                                                message: $0)
                    })
            }
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

    public func newFolderWithSelection(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let destination = currentURL
        let outcome = await Task.detached(priority: .userInitiated) {
            let folderResult = FileOperationService.newFolder(in: destination)
            switch folderResult {
            case .success(let folder):
                let moveResults = FileOperationService.move(urls, into: folder)
                return (folderResult, moveResults)
            case .failure:
                return (folderResult, [])
            }
        }.value
        await reload()

        switch outcome.0 {
        case .success(let folder):
            let successes = outcome.1.compactMap { result -> OperationSuccess? in
                if case .success(let url) = result.outcome {
                    return OperationSuccess(source: result.source, destination: url)
                }
                return nil
            }
            let failures = outcome.1.compactMap { result -> String? in
                if case .failure(let error) = result.outcome { return error.message }
                return nil
            }
            if let undoManager {
                undoManager.beginUndoGrouping()
                UndoRecorder.recordCreation([folder], actionName: "New Folder with Selection",
                                            on: undoManager, pane: self)
                UndoRecorder.recordMove(
                    successes.map { (from: $0.source, to: $0.destination) },
                    actionName: "New Folder with Selection",
                    on: undoManager, pane: self)
                undoManager.endUndoGrouping()
            }
            opErrorMessage = OperationFailureSummary.message(failures)
            let standardizedFolder = folder.standardizedFileURL
            selection = [standardizedFolder]
            pendingRenameURL = standardizedFolder
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

    /// Creates Finder-style aliases (POSIX symlinks) next to each selected
    /// item, selects the aliases, one undo step (trash the aliases).
    public func makeAliasSelected(_ urls: [URL]) async {
        await makeAliasSelected(urls, kind: .symlink)
    }

    public func makeAliasSelected(_ urls: [URL],
                                  kind: FileOperationService.AliasKind) async {
        let results = await Task.detached(priority: .userInitiated) {
            FileOperationService.makeAlias(urls, kind: kind)
        }.value
        await reload()
        finishOperation(results: results) { successes in
            guard let undoManager else { return }
            UndoRecorder.recordCreation(successes.map(\.destination),
                                        actionName: "Make Alias",
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
            ? nil : OperationFailureSummary.message(outcome.failures)
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
        await finishCreatedOutputs(results, actionName: "Convert Image") { $0.outcome }
    }

    public func resizeSelected(_ urls: [URL], mode: ImageResizer.Mode,
                               jpegQuality: Double = 0.85) async {
        let quality = jpegQuality
        let results = await Task.detached(priority: .userInitiated) {
            ImageResizer.resize(urls, mode: mode, jpegQuality: quality)
        }.value
        await finishCreatedOutputs(results, actionName: "Resize Image") { $0.outcome }
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
        finishCreatedOutputsAfterReload(results, actionName: "Extract") { $0.result }
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

    private func finishCreatedOutputs<ResultItem>(
        _ results: [ResultItem],
        actionName: String,
        outcome: (ResultItem) -> Result<URL, FileOperationService.FileOpError>
    ) async {
        await reload()
        finishCreatedOutputsAfterReload(results, actionName: actionName,
                                        outcome: outcome)
    }

    private func finishCreatedOutputsAfterReload<ResultItem>(
        _ results: [ResultItem],
        actionName: String,
        outcome: (ResultItem) -> Result<URL, FileOperationService.FileOpError>
    ) {
        let created = results.compactMap { result -> URL? in
            if case .success(let url) = outcome(result) { return url }
            return nil
        }
        let failures = results.compactMap { result -> String? in
            if case .failure(let error) = outcome(result) { return error.message }
            return nil
        }
        if let undoManager, !created.isEmpty {
            UndoRecorder.recordCreation(created, actionName: actionName,
                                        on: undoManager, pane: self)
        }
        opErrorMessage = OperationFailureSummary.message(failures)
        if !created.isEmpty {
            selection = Set(created.map { $0.standardizedFileURL })
        }
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
            let messages = failures.compactMap { result -> String? in
                if case .failure(let error) = result.outcome { return error.message }
                return nil
            }
            opErrorMessage = OperationFailureSummary.message(messages)
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

    public func applySmartFolder(_ smartFolder: SmartFolder) async {
        await navigate(to: smartFolder.rootURL)
        applyFilter(smartFolder.filter)
    }

    public func applyFilter(_ newFilter: FilterState) {
        filter = newFilter
        filterExtensionsText = newFilter.extensions.sorted()
            .joined(separator: ", ")
    }

    private func applyStoredFolderViewSettings() {
        guard let settings = settingsModel?.folderViewSettings(for: currentURL) else {
            return
        }
        viewMode = ViewMode(rawValue: settings.viewMode) ?? viewMode
        groupBy = settings.groupBy
        sortOrder = SortTokenCoder.comparators(from: settings.sort)
        showHidden = settings.showHidden
    }

    private func persistFolderViewSettings() {
        guard started else { return }
        settingsModel?.setFolderViewSettings(folderViewSettings(), for: currentURL)
    }

    public func folderViewSettings() -> FolderViewSettings {
        FolderViewSettings(
            viewMode: viewMode.rawValue,
            groupBy: groupBy,
            showHidden: showHidden,
            sort: SortTokenCoder.tokens(from: sortOrder))
    }

    public func snapshot() -> SessionSnapshot.Pane {
        SessionSnapshot.Pane(
            path: currentURL.path,
            showHidden: showHidden,
            viewMode: viewMode.rawValue,
            groupBy: groupBy,
            filter: filter,
            filterExtensionsText: filterExtensionsText,
            sort: SortTokenCoder.tokens(from: sortOrder),
            expandedFolders: expandedFolders.sorted())
    }

    private func recomputeVisible() {
        let prepared = prepareEntries(entries)
        rootVisibleCount = prepared.count
        if viewMode == .list, groupBy == .none, !expandedFolders.isEmpty {
            let rows = TreeFlattener.flatten(
                roots: entries,
                children: childEntries,
                expanded: expandedFolders) { [filter, sortOrder, gitStatus] level in
                var filtered = FilterEngine.apply(filter, to: level)
                if filter.hideGitIgnored == true, let index = gitStatus.index {
                    filtered.removeAll { index.isIgnored($0.url) }
                }
                return FileSorter.sort(filtered, using: sortOrder)
            }
            visibleEntries = rows.map(\.entry)
            rowDepths = Dictionary(uniqueKeysWithValues: rows.map {
                ($0.entry.url, $0.depth)
            })
        } else {
            visibleEntries = prepared
            rowDepths = [:]
        }
        groupedEntries = Grouper.group(visibleEntries, by: groupBy, now: Date())
    }

    private func prepareEntries(_ source: [FileEntry]) -> [FileEntry] {
        var filtered = FilterEngine.apply(filter, to: source)
        if filter.hideGitIgnored == true, let index = gitStatus.index {
            filtered.removeAll { index.isIgnored($0.url) }
        }
        return FileSorter.sort(filtered, using: sortOrder)
    }

    private func afterNavigation() async {
        selection.removeAll()
        clearTreeState()
        opErrorMessage = nil
        folderSizes.removeAll()
        applyStoredFolderViewSettings()
        gitStatus.refresh(for: currentURL)
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
