import SwiftUI
import AppKit
import FileExplorerCore

@MainActor
@Observable
final class ArchiveBrowserSheetModel {
    var selection: Set<String> = []
    var isWorking = false
    var errorMessage: String?

    func reset() {
        selection = []
        isWorking = false
        errorMessage = nil
    }
}

struct ArchiveBrowserSheet: View {
    @Bindable var browser: ArchiveBrowserModel
    @Bindable var sheet: ArchiveBrowserSheetModel
    var extractAll: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 500)
        .onKeyPress(.space) {
            guard !sheet.isWorking else { return .handled }
            previewSelection()
            return .handled
        }
        .onKeyPress(.return) {
            guard !sheet.isWorking else { return .handled }
            openSelection()
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            guard !sheet.isWorking else { return .handled }
            guard press.modifiers.contains(.command) else { return .ignored }
            browser.navigateUp()
            sheet.selection = []
            return .handled
        }
        .onKeyPress("o", phases: .down) { press in
            guard !sheet.isWorking else { return .handled }
            guard press.modifiers.contains(.command) else { return .ignored }
            openSelection()
            return .handled
        }
        .alert("Archive Error", isPresented: Binding(
            get: { sheet.errorMessage != nil },
            set: { if !$0 { sheet.errorMessage = nil } })) {
            Button("OK") { sheet.errorMessage = nil }
        } message: {
            Text(sheet.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
            Text(browser.archiveURL?.lastPathComponent ?? "Archive")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Divider().frame(height: 18)
            breadcrumb
            Spacer()
            if browser.isLoading || sheet.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                browser.navigate(into: "")
                sheet.selection = []
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.borderless)
            .help("Archive Root")
            let parts = browser.currentPath.split(separator: "/").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(part) {
                    browser.navigate(into: parts.prefix(index + 1).joined(separator: "/"))
                    sheet.selection = []
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if browser.isLoading {
            ProgressView("Loading archive…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let catalog = browser.catalog {
            VStack(spacing: 0) {
                List(selection: $sheet.selection) {
                    ForEach(catalog.children(of: browser.currentPath), id: \.path) { entry in
                        ArchiveEntryRow(entry: entry)
                            .tag(entry.path)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                if entry.isDirectory {
                                    browser.navigate(into: entry.path)
                                    sheet.selection = []
                                } else {
                                    extractThenAct(entry) { url in
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                    }
                }
                footnotes(for: catalog)
            }
        } else {
            ContentUnavailableView("No Archive Loaded", systemImage: "archivebox")
        }
    }

    @ViewBuilder
    private func footnotes(for catalog: ArchiveCatalog) -> some View {
        if catalog.isPartial || catalog.hadSuspiciousPaths {
            HStack {
                if catalog.isPartial {
                    Label("Listing truncated", systemImage: "list.bullet.rectangle")
                }
                if catalog.hadSuspiciousPaths {
                    Label("Some entries hidden: unsafe paths",
                          systemImage: "exclamationmark.triangle")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack {
            Button("Extract Selected…") { extractSelected() }
                .disabled(sheet.selection.isEmpty || sheet.isWorking)
            Button("Extract All") {
                if let archive = browser.archiveURL {
                    extractAll(archive)
                    browser.close()
                    sheet.reset()
                }
            }
            .disabled(browser.archiveURL == nil || sheet.isWorking)
            Spacer()
            Button("Done") {
                browser.close()
                sheet.reset()
            }
            .disabled(sheet.isWorking)
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func selectedEntries() -> [ArchiveEntry] {
        guard let catalog = browser.catalog else { return [] }
        return sheet.selection.compactMap { catalog.entry(at: $0) }
    }

    private func previewSelection() {
        guard selectedEntries().count == 1,
              let entry = selectedEntries().first,
              !entry.isDirectory else { return }
        extractThenAct(entry) { url in
            QuickLookController.shared.preview(url: url)
        }
    }

    private func openSelection() {
        let entries = selectedEntries()
        if entries.count == 1, let entry = entries.first {
            if entry.isDirectory {
                browser.navigate(into: entry.path)
                sheet.selection = []
            } else {
                extractThenAct(entry) { url in
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func extractThenAct(_ entry: ArchiveEntry,
                                action: @escaping @MainActor (URL) -> Void) {
        guard let archive = browser.archiveURL else { return }
        sheet.isWorking = true
        let tempRoot = browser.previewTempRoot()
        let token = browser.presentationToken
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ArchiveExtractor.extractForPreview(entry: entry, from: archive,
                                                   tempRoot: tempRoot)
            }.value
            sheet.isWorking = false
            switch result {
            case .success(let url):
                guard browser.isCurrentPreviewContext(archive: archive, token: token) else {
                    browser.discardPreviewExtraction(at: url)
                    return
                }
                action(url)
            case .failure(let error):
                guard browser.isCurrentPreviewContext(archive: archive, token: token) else { return }
                sheet.errorMessage = error.message
            }
        }
    }

    private func extractSelected() {
        guard let archive = browser.archiveURL,
              let catalog = browser.catalog else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let paths = Array(Set(selectedEntries().flatMap { entry in
            if entry.isDirectory {
                return catalog.descendantFiles(of: entry.path).map(\.path)
            }
            return [entry.path]
        })).sorted()
        guard !paths.isEmpty else { return }
        sheet.isWorking = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ArchiveExtractor.extract(entries: paths, from: archive, into: destination)
            }.value
            sheet.isWorking = false
            if case .failure(let error) = result {
                sheet.errorMessage = error.message
            }
        }
    }
}

private struct ArchiveEntryRow: View {
    let entry: ArchiveEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if entry.isDirectory {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(width: 90, alignment: .trailing)
            } else {
                Text(entry.size, format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
            if let modified = entry.modified {
                Text(modified, format: .dateTime.year().month(.abbreviated).day())
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .font(.callout)
    }
}
