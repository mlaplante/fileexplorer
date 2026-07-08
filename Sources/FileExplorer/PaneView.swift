import SwiftUI
import FileExplorerCore
import AppKit

struct PaneView: View {
    @Bindable var pane: PaneState
    @Bindable var session: SessionState
    var otherPane: PaneState?
    var renameModel: RenameSheetModel
    var batchRenameModel: BatchRenameModel
    var settings: SettingsModel
    var trashRegistry: TrashRegistryModel?
    /// Compare-mode context: this pane's side and the shared result, valid
    /// only while the pane is still at the compared root.
    var compareSide: FolderComparator.Side? = nil
    var compareResult: FolderComparator.Result? = nil
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbView(pane: pane)
            Divider()
            FilterBarView(pane: pane, settings: settings)
            Divider()
            paneTitle
            Group {
                if pane.viewMode == .icons {
                    ThumbnailGridView(
                        pane: pane,
                        actions: FileActions(pane: pane, session: session,
                                             otherPane: otherPane,
                                             renameModel: renameModel,
                                             batchRenameModel: batchRenameModel,
                                             settings: settings,
                                             trashRegistry: trashRegistry,
                                             share: share)) { open($0) }
                } else if pane.viewMode == .columns {
                    ColumnBrowserView(
                        pane: pane,
                        actions: FileActions(pane: pane, session: session,
                                             otherPane: otherPane,
                                             renameModel: renameModel,
                                             batchRenameModel: batchRenameModel,
                                             settings: settings,
                                             trashRegistry: trashRegistry,
                                             share: share)) { open($0) }
                } else {
                    table
                }
            }
            .onChange(of: pane.selection) { _, _ in
                if QuickLookController.shared.isVisible {
                    QuickLookController.shared.refresh(from: pane)
                }
            }
            .onKeyPress(.space) {
                QuickLookController.shared.toggle(for: pane)
                return .handled
            }
            .onKeyPress(.init("\u{7F}"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                let targets = Array(pane.selection)
                guard !targets.isEmpty else { return .ignored }
                Task { await pane.trashSelected(targets) }
                return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                guard press.modifiers.contains(.command),
                      !pane.selection.isEmpty else { return .ignored }
                Task {
                    await pane.openSelection { NSWorkspace.shared.open($0) }
                }
                return .handled
            }
            .popover(isPresented: Binding(
                get: { pane.showsNewTagPopover },
                set: { pane.showsNewTagPopover = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("New tag name", text: Binding(
                        get: { pane.newTagDraft },
                        set: { pane.newTagDraft = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button("Add Tag to Selection") {
                        let tag = pane.newTagDraft
                            .trimmingCharacters(in: .whitespaces)
                        let targets = pane.entries.filter {
                            pane.newTagTargets.contains($0.url)
                        }
                        pane.showsNewTagPopover = false
                        guard !tag.isEmpty, !targets.isEmpty else { return }
                        Task {
                            for entry in targets {
                                _ = TagWriter.setTags(
                                    TagWriter.toggledTags(current: entry.tags,
                                                          tag: tag, removing: false),
                                    on: entry.url)
                            }
                            await pane.reload()
                        }
                    }
                    .disabled(pane.newTagDraft
                        .trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let outside = urls.filter {
                    $0.deletingLastPathComponent().standardizedFileURL != pane.currentURL
                }
                guard !outside.isEmpty else { return false }
                let optionDown = NSEvent.modifierFlags.contains(.option)
                let sameVolume = outside.allSatisfy {
                    DropDecision.sameVolume($0, pane.currentURL)
                }
                Task {
                    switch DropDecision.decide(optionDown: optionDown,
                                               sameVolume: sameVolume) {
                    case .move:
                        await pane.moveSelected(outside, into: pane.currentURL)
                    case .copy:
                        await pane.copySelected(outside, into: pane.currentURL)
                    }
                }
                return true
            }
            Divider()
            statusBar
        }
        .onAppear {
            pane.undoManager = undoManager
            pane.trashRegistry = trashRegistry
            pane.settingsModel = settings
        }
        .onChange(of: pane.currentURL) { _, _ in
            pane.undoManager = undoManager
            pane.trashRegistry = trashRegistry
            pane.settingsModel = settings
        }
        .onChange(of: pane.pendingRenameURL) { _, url in
            guard let url else { return }
            renameModel.present(for: url, in: pane)
            pane.pendingRenameURL = nil
        }
        .background(ShareAnchor { view in
            pane.shareAnchor = view
        }.frame(width: 0, height: 0))
    }

    private func share(_ targets: [URL]) {
        guard let anchor = pane.shareAnchor else { return }
        ShareBridge.shared.present(urls: targets, from: anchor)
    }

    /// Prominent folder heading over the content area (the breadcrumb stays
    /// the navigation surface; this is the "you are here" anchor).
    private var paneTitle: some View {
        HStack {
            Text(pane.currentURL.path == "/" ? "Macintosh HD"
                 : pane.currentURL.lastPathComponent)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var statusBar: some View {
        HStack {
            if pane.filter.isActive {
                Text("\(pane.visibleEntries.count) of \(pane.totalCount) items")
            } else {
                Text("\(pane.visibleEntries.count) items")
            }
            if !pane.selection.isEmpty {
                Text("· \(pane.selection.count) selected")
            }
            Spacer()
            if let opError = pane.opErrorMessage {
                Text(opError)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(opError)
            }
            if let availableSpaceText = pane.availableSpaceText {
                Text(availableSpaceText)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var table: some View {
        // Dragging lives on the ROW (itemProvider), not on cell content:
        // a .draggable on the Name cell swallowed mouse-downs, so clicking
        // the icon or name never reached row selection — only the plain
        // Size/Kind/Date cells selected.
        Table(of: FileEntry.self, selection: $pane.selection,
              sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    FileEntryLabel(entry: entry)
                    if let compareResult, let compareSide,
                       let badge = FolderComparator.badge(
                           for: entry.url.standardizedFileURL.path.replacingOccurrences(
                               of: pane.currentURL.standardizedFileURL.path + "/",
                               with: ""),
                           isDirectory: entry.isDirectory,
                           side: compareSide, in: compareResult) {
                        Image(systemName: badgeSymbol(badge))
                            .foregroundStyle(badgeColor(badge))
                            .help(badgeHelp(badge))
                    }
                }
                .onHover { hovering in
                    if hovering {
                        pane.hoverPreview.hoverBegan(entry)
                    } else {
                        pane.hoverPreview.hoverEnded()
                    }
                }
                .popover(isPresented: Binding(
                    get: { pane.hoverPreview.presented?.url == entry.url },
                    set: { if !$0 { pane.hoverPreview.hoverEnded() } }),
                    arrowEdge: .trailing) {
                    HoverPreviewView(model: pane.hoverPreview)
                }
            }
            TableColumn("Size", value: \.size) { entry in
                if entry.isDirectory {
                    if let size = pane.folderSizes[entry.url.standardizedFileURL] {
                        Text(size, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                } else {
                    Text(entry.size, format: .byteCount(style: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { entry in
                Text(entry.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Date Modified", value: \.modified) { entry in
                Text(entry.modified,
                     format: .dateTime.year().month(.abbreviated).day()
                        .hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
        } rows: {
            if pane.groupBy == .none {
                ForEach(pane.visibleEntries) { entry in
                    TableRow(entry)
                        .itemProvider { NSItemProvider(object: entry.url as NSURL) }
                }
            } else {
                ForEach(Array(pane.groupedEntries.enumerated()), id: \.offset) { _, group in
                    Section(group.title ?? "") {
                        ForEach(group.entries) { entry in
                            TableRow(entry)
                                .itemProvider { NSItemProvider(object: entry.url as NSURL) }
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            FileActions(pane: pane, session: session,
                        otherPane: otherPane,
                        renameModel: renameModel,
                        batchRenameModel: batchRenameModel,
                        settings: settings,
                        trashRegistry: trashRegistry,
                        share: share).menu(for: urls)
        } primaryAction: { urls in
            open(urls)
        }
        .overlay {
            if let message = pane.errorMessage {
                ContentUnavailableView(
                    "Can't Read Folder",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message))
            } else if pane.hasLoadedOnce && pane.visibleEntries.isEmpty {
                if pane.filter.isActive {
                    ContentUnavailableView(
                        "No Matches", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No items match the current filters."))
                } else {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                }
            }
        }
    }

    private func open(_ urls: Set<URL>) {
        // Double-clicking exactly one folder navigates into it;
        // anything else opens with the default app.
        if urls.count == 1, let url = urls.first,
           pane.entries.first(where: { $0.url == url })?.isDirectory == true {
            Task { await pane.navigate(to: url) }
        } else {
            for url in urls { NSWorkspace.shared.open(url) }
        }
    }

    private func badgeSymbol(_ badge: FolderComparator.Badge) -> String {
        switch badge {
        case .onlyHere: "plus.circle.fill"
        case .differs: "arrow.triangle.2.circlepath.circle.fill"
        case .containsChanges: "ellipsis.circle"
        }
    }

    private func badgeColor(_ badge: FolderComparator.Badge) -> Color {
        switch badge {
        case .onlyHere: .green
        case .differs: .orange
        case .containsChanges: .secondary
        }
    }

    private func badgeHelp(_ badge: FolderComparator.Badge) -> String {
        switch badge {
        case .onlyHere: "Only in this pane"
        case .differs: "Differs from the other pane"
        case .containsChanges: "Contains differences"
        }
    }
}
