import SwiftUI
import AppKit
import FileExplorerCore

struct ColumnBrowserView: View {
    @Bindable var pane: PaneState
    var actions: FileActions
    var open: (Set<URL>) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(pane.columnsModel.columns.indices, id: \.self) { index in
                    if index == pane.columnsModel.columns.count - 1 {
                        currentColumn
                    } else {
                        ancestorColumn(
                            pane.columnsModel.columns[index],
                            nextURL: pane.columnsModel.columns[index + 1].url)
                    }
                }
            }
        }
        .task(id: pane.currentURL) {
            await pane.columnsModel.refresh(for: pane.currentURL,
                                            showHidden: pane.showHidden)
        }
        .onChange(of: pane.showHidden) { _, _ in
            Task {
                await pane.columnsModel.refresh(for: pane.currentURL,
                                                showHidden: pane.showHidden)
            }
        }
        .onKeyPress(.leftArrow) {
            Task { await pane.goUp() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard pane.selection.count == 1,
                  let url = pane.selection.first,
                  pane.entries.first(where: { $0.url == url })?.isDirectory == true
            else { return .ignored }
            Task { await pane.navigate(to: url) }
            return .handled
        }
    }

    private func ancestorColumn(_ column: ColumnsModel.Column,
                                nextURL: URL) -> some View {
        List(column.entries) { entry in
            if entry.isDirectory {
                Button {
                    Task { await pane.navigate(to: entry.url) }
                } label: {
                    entryLabel(entry)
                        .fontWeight(entry.url.path == nextURL.path ? .semibold : .regular)
                }
                .buttonStyle(.plain)
            } else {
                entryLabel(entry)
                    .fontWeight(entry.url.path == nextURL.path ? .semibold : .regular)
            }
        }
        .frame(width: 220)
    }

    private var currentColumn: some View {
        List(selection: $pane.selection) {
            ForEach(pane.visibleEntries) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(entry.name)
                        .lineLimit(1)
                    if entry.isSymlink {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                            .foregroundStyle(.secondary)
                            .help("Symbolic link")
                    }
                    if !entry.tags.isEmpty {
                        TagDotsView(tags: entry.tags)
                    }
                }
                .tag(entry.url)
            }
        }
        .frame(width: 220)
        .contextMenu(forSelectionType: URL.self) { urls in
            actions.menu(for: urls)
        } primaryAction: { urls in
            open(urls)
        }
    }

    private func entryLabel(_ entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
        }
    }
}
