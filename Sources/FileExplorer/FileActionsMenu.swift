import SwiftUI
import AppKit
import FileExplorerCore

/// Context-menu actions for a set of selected URLs in a pane. Used by both
/// the table (contextMenu forSelectionType) and the grid.
@MainActor
struct FileActions {
    let pane: PaneState
    let session: SessionState
    let otherPane: PaneState?
    let renameModel: RenameSheetModel
    let batchRenameModel: BatchRenameModel
    let settings: SettingsModel
    let trashRegistry: TrashRegistryModel?
    let conflictResolution: ConflictResolutionModel?
    let share: (@MainActor ([URL]) -> Void)?

    @ViewBuilder
    func menu(for urls: Set<URL>) -> some View {
        let targets = Array(urls)
        openSection(targets: targets)
        favoriteSection(targets: targets)
        clipboardSection(targets: targets)
        tagsSection(targets: targets)
        Divider()
        renameSection(targets: targets)
        newItemsSection(targets: targets)
        paneTransferSection(targets: targets)
        Divider()
        imageToolsSection(targets: targets)
        archiveSection(targets: targets)
        diskImageSection(targets: targets)
        sizeSection(targets: targets)
        advancedSystemSection(targets: targets)
        Divider()
        trashSection(targets: targets)
    }

    @ViewBuilder
    private func openSection(targets: [URL]) -> some View {
        Button("Open") {
            for url in targets { NSWorkspace.shared.open(url) }
        }
        .disabled(targets.isEmpty)
        if targets.count == 1, let target = targets.first,
           PackageInspector.isPackage(target) {
            Button("Show Package Contents") {
                Task { await pane.navigate(to: target) }
            }
        }
        Menu("Open With") {
            // Candidate apps come from the FIRST item's type (spec decision);
            // the chosen app opens the whole selection.
            if let url = targets.first {
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
                    .sorted {
                        appDisplayName($0).localizedCaseInsensitiveCompare(
                            appDisplayName($1)) == .orderedAscending
                    }
                if let defaultApp {
                    Button("\(appDisplayName(defaultApp)) (default)") {
                        openWith(targets, app: defaultApp)
                    }
                    Divider()
                }
                ForEach(apps.filter { $0 != defaultApp }, id: \.self) { app in
                    Button(appDisplayName(app)) { openWith(targets, app: app) }
                }
                if apps.isEmpty && defaultApp == nil {
                    Text("No Available Applications")
                }
            }
        }
        .disabled(targets.isEmpty)
        Button("Share…") {
            share?(targets)
        }
        .disabled(targets.isEmpty || share == nil)
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
        .disabled(targets.isEmpty)
    }

    @ViewBuilder
    private func favoriteSection(targets: [URL]) -> some View {
        let folders = targets.filter { isFolder($0) }
        if folders.count == 1, let folder = folders.first {
            Button(session.isFavoriteFolder(folder) ? "Unfavorite" : "Favorite") {
                session.toggleFavoriteFolder(folder)
            }
        } else if !folders.isEmpty {
            Button("Favorite") {
                for folder in folders {
                    _ = session.addFavoriteFolder(folder)
                }
            }
        }
    }

    @ViewBuilder
    private func clipboardSection(targets: [URL]) -> some View {
        Button("Copy") {
            PasteboardOps.copyToPasteboard(targets)
        }
        .disabled(targets.isEmpty)
        Button("Duplicate") {
            Task { await pane.duplicateSelected(targets) }
        }
        .disabled(targets.isEmpty)
        Menu("Make Alias") {
            Button("Symbolic Link Alias") {
                Task { await pane.makeAliasSelected(targets, kind: .symlink) }
            }
            Button("Finder Alias File") {
                Task { await pane.makeAliasSelected(targets, kind: .bookmarkFile) }
            }
        }
        .disabled(targets.isEmpty)
        Menu("Copy Path") {
            Button("POSIX Path") {
                PasteboardOps.copyString(
                    targets.map(\.path).joined(separator: "\n"))
            }
            Button("Abbreviated (~) Path") {
                PasteboardOps.copyString(
                    targets.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        .joined(separator: "\n"))
            }
        }
        .disabled(targets.isEmpty)
        Button("Copy SHA-256") {
            guard let url = targets.first else { return }
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    FileHasher.sha256(of: url)
                }.value
                switch result {
                case .success(let hash):
                    PasteboardOps.copyString(hash)
                case .failure(let error):
                    pane.reportTagFailure(error.message)
                }
            }
        }
        .disabled(targets.count != 1 || targets.first.map { url in
            pane.entries.first { $0.url == url }?.isDirectory == true
        } == true)
    }

    @ViewBuilder
    private func tagsSection(targets: [URL]) -> some View {
        Menu("Tags") {
            let selectedEntries = pane.entries.filter { targets.contains($0.url) }
            let visibleTags = Set(pane.entries.flatMap(\.tags))
            let standardLabels = NSWorkspace.shared.fileLabels
                .filter { $0 != "None" }
            let allTags = Array(Set(standardLabels).union(visibleTags)).sorted()
            ForEach(allTags, id: \.self) { tag in
                let allHave = !selectedEntries.isEmpty
                    && selectedEntries.allSatisfy { $0.tags.contains(tag) }
                Toggle(isOn: Binding(
                    get: { allHave },
                    set: { _ in
                        Task { await applyTagToggle(tag, removing: allHave,
                                                    entries: selectedEntries) }
                    })) {
                    Label(tag, systemImage: "circle.fill")
                }
            }
            Divider()
            Button("New Tag…") {
                pane.newTagDraft = ""
                pane.newTagTargets = targets
                pane.showsNewTagPopover = true
            }
        }
        .disabled(targets.isEmpty)
    }

    @ViewBuilder
    private func renameSection(targets: [URL]) -> some View {
        Button("Rename…") {
            if let url = targets.first { renameModel.present(for: url, in: pane) }
        }
        .disabled(targets.count != 1)
        Button("Batch Rename…") {
            batchRenameModel.present(
                targets: targets.sorted { $0.lastPathComponent < $1.lastPathComponent },
                existingNames: Set(pane.entries.map(\.name)),
                in: pane)
        }
        .disabled(targets.count < 2)
    }

    @ViewBuilder
    private func newItemsSection(targets: [URL]) -> some View {
        Button("New Folder") {
            Task { await pane.createNewFolder() }
        }
        if !targets.isEmpty {
            Button("New Folder with Selection (\(targets.count) Item\(targets.count == 1 ? "" : "s"))") {
                Task { await pane.newFolderWithSelection(targets) }
            }
        }
        Button("New File") {
            Task { await pane.createNewFile() }
        }
    }

    @ViewBuilder
    private func paneTransferSection(targets: [URL]) -> some View {
        if let otherPane {
            Divider()
            Button("Move to Other Pane") {
                transfer(targets, to: otherPane, operation: .move, title: "Move")
            }
            .disabled(targets.isEmpty)
            Button("Copy to Other Pane") {
                transfer(targets, to: otherPane, operation: .copy, title: "Copy")
            }
            .disabled(targets.isEmpty)
        }
    }

    @ViewBuilder
    private func imageToolsSection(targets: [URL]) -> some View {
        Menu("Convert Image To") {
            Button("JPG") {
                Task { await pane.convertSelected(
                    targets, to: .jpeg,
                    jpegQuality: settings.settings.jpegQuality) }
            }
            Button("PNG") {
                Task { await pane.convertSelected(targets, to: .png) }
            }
            Divider()
            Menu("JPG Quality") {
                ForEach([0.6, 0.8, 0.9, 1.0], id: \.self) { quality in
                    Toggle("\(Int((quality * 100).rounded()))", isOn: Binding(
                        get: { settings.settings.jpegQuality == quality },
                        set: { if $0 { settings.setJPEGQuality(quality) } }))
                }
            }
        }
        .disabled(targets.isEmpty)
        Menu("Resize Image") {
            Button("25%") {
                Task { await pane.resizeSelected(targets, mode: .percent(25),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
            Button("50%") {
                Task { await pane.resizeSelected(targets, mode: .percent(50),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
            Divider()
            Button("Max 1024 px") {
                Task { await pane.resizeSelected(targets, mode: .maxEdge(1024),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
            Button("Max 2048 px") {
                Task { await pane.resizeSelected(targets, mode: .maxEdge(2048),
                                                 jpegQuality: settings.settings.jpegQuality) }
            }
        }
        .disabled(targets.isEmpty)
    }

    @ViewBuilder
    private func archiveSection(targets: [URL]) -> some View {
        Button("Compress") {
            Task { await pane.compressSelected(targets) }
        }
        .disabled(targets.isEmpty)
        Button("Extract") {
            let archives = targets.filter {
                ArchiveKind.detect($0.lastPathComponent) != nil
            }
            Task { await pane.extractSelected(archives) }
        }
        .disabled(!targets.contains {
            ArchiveKind.detect($0.lastPathComponent) != nil
        })
    }

    @ViewBuilder
    private func diskImageSection(targets: [URL]) -> some View {
        let folders = targets.filter { isFolder($0) }
        let images = targets.filter { $0.pathExtension.lowercased() == "dmg" }
        Menu("Disk Image") {
            Button("Create Disk Image") {
                for folder in folders {
                    runDiskImageCommand(DiskImagePlanner.createCommand(
                        sourceFolder: folder))
                }
            }
            .disabled(folders.isEmpty)
            Button("Mount") {
                for image in images {
                    runDiskImageCommand(DiskImagePlanner.attachCommand(image: image))
                }
            }
            .disabled(images.isEmpty)
            Button("Verify") {
                for image in images {
                    runDiskImageCommand(DiskImagePlanner.verifyCommand(image: image))
                }
            }
            .disabled(images.isEmpty)
        }
        .disabled(targets.isEmpty)
    }

    @ViewBuilder
    private func sizeSection(targets: [URL]) -> some View {
        Button("Calculate Size") {
            Task { await pane.calculateFolderSizes(targets) }
        }
        .disabled(!targets.contains { url in
            pane.entries.first(where: { $0.url == url })?.isDirectory == true
        })
    }

    @ViewBuilder
    private func advancedSystemSection(targets: [URL]) -> some View {
        Menu("Advanced") {
            Button("Lock") {
                setLocked(true, targets: targets)
            }
            .disabled(targets.isEmpty)
            Button("Unlock") {
                setLocked(false, targets: targets)
            }
            .disabled(targets.isEmpty)
            Button("Clear Quarantine") {
                clearQuarantine(targets: targets)
            }
            .disabled(targets.isEmpty)
            let cloudTargets = targets.filter {
                CloudFileTools.state(for: $0) != .notCloud
            }
            Divider()
            Button("Download from iCloud") {
                runCloudAction(targets: cloudTargets,
                               action: CloudFileTools.startDownload)
            }
            .disabled(cloudTargets.isEmpty)
            Button("Remove Local Download") {
                runCloudAction(targets: cloudTargets,
                               action: CloudFileTools.evictLocalCopy)
            }
            .disabled(cloudTargets.isEmpty)
        }
        .disabled(targets.isEmpty)
    }

    @ViewBuilder
    private func trashSection(targets: [URL]) -> some View {
        if trashRegistry?.canPutBack(targets) == true {
            Button("Put Back") {
                Task { await pane.putBackSelected(targets) }
            }
        }
        Button("Move to Trash") {
            Task { await pane.trashSelected(targets) }
        }
        .disabled(targets.isEmpty)
    }

    private func appDisplayName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path)
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path,
                                              isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func openWith(_ urls: [URL], app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func transfer(_ targets: [URL], to destinationPane: PaneState,
                          operation: OperationConflictPlanner.Operation,
                          title: String) {
        let plan = OperationConflictPlanner.plan(
            operation: operation,
            sources: targets,
            into: destinationPane.currentURL)
        if plan.hasConflicts, let conflictResolution {
            conflictResolution.present(plan: plan, title: title, pane: pane)
        } else {
            Task { await pane.executeResolvedPlan(plan, actionName: title) }
        }
    }

    private func runDiskImageCommand(_ command: DiskImageCommand) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    await MainActor.run {
                        pane.reportTagFailure("Disk image command failed.")
                    }
                } else {
                    await pane.reload()
                }
            } catch {
                await MainActor.run {
                    pane.reportTagFailure(error.localizedDescription)
                }
            }
        }
    }

    private func setLocked(_ locked: Bool, targets: [URL]) {
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for target in targets {
                do {
                    try PermissionTools.setLocked(locked, for: target)
                } catch {
                    failures.append("\(target.lastPathComponent): \(error.localizedDescription)")
                }
            }
            await pane.reload()
            if let message = OperationFailureSummary.message(failures) {
                await MainActor.run { pane.reportTagFailure(message) }
            }
        }
    }

    private func clearQuarantine(targets: [URL]) {
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for target in targets {
                do {
                    try PermissionTools.clearQuarantine(target)
                } catch {
                    failures.append("\(target.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if let message = OperationFailureSummary.message(failures) {
                await MainActor.run { pane.reportTagFailure(message) }
            }
        }
    }

    private func runCloudAction(
        targets: [URL],
        action: @escaping @Sendable (URL) -> Result<Void, FileOperationService.FileOpError>
    ) {
        Task.detached(priority: .userInitiated) {
            let failures = targets.compactMap { target -> String? in
                if case .failure(let error) = action(target) {
                    return "\(target.lastPathComponent): \(error.message)"
                }
                return nil
            }
            if let message = OperationFailureSummary.message(failures) {
                await MainActor.run { pane.reportTagFailure(message) }
            }
        }
    }

    private func applyTagToggle(_ tag: String, removing: Bool,
                                entries: [FileEntry]) async {
        var failures: [String] = []
        for entry in entries {
            let newTags = TagWriter.toggledTags(current: entry.tags, tag: tag,
                                                removing: removing)
            if case .failure(let error) = TagWriter.setTags(newTags, on: entry.url) {
                failures.append(error.message)
            }
        }
        await pane.reload()
        if let message = OperationFailureSummary.message(failures) {
            pane.reportTagFailure(message)
        }
    }
}
