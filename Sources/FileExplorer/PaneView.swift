import SwiftUI
import FileExplorerCore

struct PaneView: View {
    @Bindable var pane: PaneState
    private let hoverModel = HoverPreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbView(pane: pane)
            Divider()
            FilterBarView(pane: pane)
            Divider()
            Group {
                if pane.viewMode == .icons {
                    ThumbnailGridView(pane: pane) { open($0) }
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
            Divider()
            statusBar
        }
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
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var table: some View {
        Table(pane.visibleEntries, selection: $pane.selection,
              sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(entry.name)
                        .lineLimit(1)
                }
                .onHover { hovering in
                    if hovering {
                        hoverModel.hoverBegan(entry)
                    } else {
                        hoverModel.hoverEnded()
                    }
                }
                .popover(isPresented: Binding(
                    get: { hoverModel.presented?.url == entry.url },
                    set: { if !$0 { hoverModel.hoverEnded() } }),
                    arrowEdge: .trailing) {
                    HoverPreviewView(model: hoverModel)
                }
            }
            TableColumn("Size", value: \.size) { entry in
                if entry.isDirectory {
                    Text("—").foregroundStyle(.tertiary)
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
        }
        .contextMenu(forSelectionType: URL.self) { _ in
            // Context menu items arrive in Milestone 6 (file operations).
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
}
