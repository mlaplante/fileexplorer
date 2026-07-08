import SwiftUI
import AppKit
import FileExplorerCore

/// Finder-style trailing preview pane. All mutable state is owned by
/// PreviewPaneModel on TabState.
struct PreviewPaneView: View {
    @Bindable var pane: PaneState
    @Bindable var model: PreviewPaneModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(.regularMaterial)
        .onAppear { model.update(selection: pane.selection, entries: pane.entries) }
        .onChange(of: pane.selection) { _, selection in
            model.update(selection: selection, entries: pane.entries)
        }
        .onChange(of: pane.entries) { _, entries in
            model.update(selection: pane.selection, entries: entries)
        }
    }

    @ViewBuilder
    private var content: some View {
        if pane.selection.isEmpty {
            empty("No Selection")
        } else if model.selectionCount > 1 {
            empty("\(model.selectionCount) items selected")
        } else if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let info = model.info {
            single(info)
        } else {
            empty("No Preview")
        }
    }

    private func empty(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func single(_ info: ItemInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            preview(for: info)
                .frame(maxWidth: .infinity)
            Text(info.name)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                metadata("Kind", info.kind)
                if let size = info.size {
                    metadata("Size", size.formatted(.byteCount(style: .file)))
                }
                if let created = info.created {
                    metadata("Created", created.formatted(date: .abbreviated,
                                                          time: .shortened))
                }
                if let modified = info.modified {
                    metadata("Modified", modified.formatted(date: .abbreviated,
                                                            time: .shortened))
                }
                if let entry = pane.entries.first(where: {
                    $0.url.standardizedFileURL == info.url.standardizedFileURL
                }), !entry.tags.isEmpty {
                    LabeledContent("Tags") {
                        HStack(spacing: 6) {
                            TagDotsView(tags: entry.tags)
                            Text(entry.tags.joined(separator: ", "))
                                .lineLimit(2)
                        }
                    }
                }
            }
            .font(.caption)
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func preview(for info: ItemInfo) -> some View {
        if let image = model.previewImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 190)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let text = model.previewText {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(.background.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: info.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.vertical, 28)
        }
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(2)
        }
    }
}
