import SwiftUI
import FileExplorerCore

@MainActor
@Observable
final class UsageSheetModel {
    let scanner = UsageScanner()
    var root: URL?
    var breadcrumbs: [URL] = []
    var errorMessage: String?
    @ObservationIgnored weak var pane: PaneState?

    var isPresented: Bool { root != nil }

    func present(root: URL, pane: PaneState) {
        let standardized = root.standardizedFileURL
        self.pane = pane
        self.root = standardized
        breadcrumbs = [standardized]
        errorMessage = nil
        scanner.scan(root: standardized)
    }

    func dismiss() {
        scanner.cancel()
        root = nil
        breadcrumbs = []
        errorMessage = nil
        pane = nil
    }

    func drillDown(to url: URL) {
        let standardized = url.standardizedFileURL
        errorMessage = nil
        root = standardized
        breadcrumbs.append(standardized)
        scanner.scan(root: standardized)
    }

    func jump(to url: URL) {
        let standardized = url.standardizedFileURL
        errorMessage = nil
        if let index = breadcrumbs.firstIndex(of: standardized) {
            breadcrumbs = Array(breadcrumbs.prefix(index + 1))
        } else {
            breadcrumbs.append(standardized)
        }
        root = standardized
        scanner.scan(root: standardized)
    }

    func reveal(_ row: UsageRow) {
        guard let pane else { return }
        let parent = row.url.deletingLastPathComponent()
        Task {
            await pane.navigate(to: parent)
            pane.selection = [row.url.standardizedFileURL]
        }
        dismiss()
    }

    func trash(_ row: UsageRow) {
        guard let pane else { return }
        Task {
            let successes = await pane.trash(urls: [row.url])
            if successes.contains(where: { $0.standardizedFileURL == row.url.standardizedFileURL }) {
                scanner.remove(url: row.url, bytes: row.bytes)
            }
            errorMessage = pane.opErrorMessage
        }
    }
}

struct UsageSheet: View {
    var model: UsageSheetModel

    private let barWidth: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            breadcrumb
            List(model.scanner.rows) { row in
                usageRow(row)
                    .contextMenu {
                        Button("Reveal in Pane") { model.reveal(row) }
                        Button("Move to Trash") { model.trash(row) }
                    }
            }
            .frame(minHeight: 360)
            footer
            HStack {
                Spacer()
                Button("Close") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 560)
        .onDisappear { model.scanner.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Disk Usage")
                    .font(.headline)
                if model.scanner.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text(model.scanner.totalBytes, format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
            }
            Text(model.root?.path ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var breadcrumb: some View {
        let breadcrumbs = model.breadcrumbs
        return ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(breadcrumbs, id: \.self) { (url: URL) in
                    let index = breadcrumbs.firstIndex(of: url) ?? 0
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent) {
                        model.jump(to: url)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(index == breadcrumbs.count - 1
                                     ? Color.primary : Color.accentColor)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.scanner.isPartial {
                Label("Partial results", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(model.scanner.rows.count) item\(model.scanner.rows.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func usageRow(_ row: UsageRow) -> some View {
        HStack(spacing: 10) {
            if row.isDirectory {
                Image(systemName: "folder")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Button {
                if row.isDirectory { model.drillDown(to: row.url) }
            } label: {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .disabled(!row.isDirectory)
            Spacer(minLength: 12)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)
                Rectangle()
                    .fill(.tint)
                    .frame(width: barWidth * row.proportion)
            }
            .frame(width: barWidth, height: 8)
            Text(row.bytes, format: .byteCount(style: .file))
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
            Text("\(row.itemCount)")
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            Button {
                model.reveal(row)
            } label: {
                Image(systemName: "arrow.right.square")
            }
            .help("Reveal in Pane")
            Button(role: .destructive) {
                model.trash(row)
            } label: {
                Image(systemName: "trash")
            }
            .help("Move to Trash")
        }
        .font(.callout)
    }
}
