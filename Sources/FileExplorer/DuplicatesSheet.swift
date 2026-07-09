import SwiftUI
import FileExplorerCore

enum DuplicateMode: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case custom = "Custom"

    var id: String { rawValue }
}

@MainActor
@Observable
final class DuplicatesSheetModel {
    let finder = DuplicateFinder()
    var root: URL?
    var modes: [String: DuplicateMode] = [:]
    var customKeeps: [String: Set<URL>] = [:]
    @ObservationIgnored weak var pane: PaneState?

    var isPresented: Bool { root != nil }

    func present(root: URL, pane: PaneState) {
        let standardized = root.standardizedFileURL
        self.pane = pane
        self.root = standardized
        modes = [:]
        customKeeps = [:]
        finder.scan(root: standardized)
    }

    func dismiss() {
        finder.cancel()
        root = nil
        modes = [:]
        customKeeps = [:]
        pane = nil
    }

    func mode(for group: DuplicateGroup) -> DuplicateMode {
        modes[group.id] ?? .newest
    }

    func setMode(_ mode: DuplicateMode, for group: DuplicateGroup) {
        modes[group.id] = mode
        if mode == .custom, customKeeps[group.id] == nil {
            let keep = DuplicateKeepPlanner.trashPlan(group: group, strategy: .newest)
                .map { trashed in Set(group.members.map(\.url)).subtracting(trashed) }
                ?? Set(group.members.prefix(1).map(\.url))
            customKeeps[group.id] = keep
        }
    }

    func isKept(_ member: DuplicateMember, in group: DuplicateGroup) -> Bool {
        customKeeps[group.id, default: Set(group.members.map(\.url))]
            .contains(member.url)
    }

    func setKept(_ kept: Bool, member: DuplicateMember, in group: DuplicateGroup) {
        var set = customKeeps[group.id] ?? Set(group.members.map(\.url))
        if kept {
            set.insert(member.url)
        } else {
            set.remove(member.url)
        }
        customKeeps[group.id] = set
    }

    func strategy(for group: DuplicateGroup) -> KeepStrategy {
        switch mode(for: group) {
        case .newest:
            return .newest
        case .oldest:
            return .oldest
        case .custom:
            return .custom(keep: customKeeps[group.id] ?? [])
        }
    }

    var selectedTrashURLs: [URL] {
        DuplicateKeepPlanner.combinedPlan(finder.groups.map {
            ($0, strategy(for: $0))
        })
    }

    var hasInvalidCustomSelection: Bool {
        finder.groups.contains { group in
            if mode(for: group) != .custom { return false }
            return DuplicateKeepPlanner.trashPlan(group: group,
                                                 strategy: strategy(for: group)) == nil
        }
    }

    var selectedReclaimableBytes: Int64 {
        finder.groups.reduce(0) { total, group in
            let count = DuplicateKeepPlanner.trashPlan(group: group,
                                                       strategy: strategy(for: group))?.count ?? 0
            return total + group.size * Int64(count)
        }
    }

    func trashSelected() {
        guard let pane else { return }
        let urls = selectedTrashURLs
        guard !urls.isEmpty, !hasInvalidCustomSelection else { return }
        Task {
            await pane.trash(urls: urls)
            dismiss()
        }
    }
}

struct DuplicatesSheet: View {
    @Bindable var model: DuplicatesSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.finder.groups.isEmpty && !model.finder.isScanning {
                ContentUnavailableView("No Duplicates Found", systemImage: "doc.on.doc")
                    .frame(minHeight: 320)
            } else {
                List(model.finder.groups) { group in
                    duplicateGroup(group)
                }
                .frame(minHeight: 360)
            }
            footer
        }
        .padding(20)
        .frame(width: 760, height: 600)
        .onDisappear { model.finder.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Duplicates")
                    .font(.headline)
                if model.finder.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text("\(model.finder.scannedFileCount) files scanned")
                    .foregroundStyle(.secondary)
            }
            Text(model.root?.path ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footer: some View {
        HStack {
            if model.finder.isPartial {
                Label("Partial results", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(model.selectedReclaimableBytes, format: .byteCount(style: .file))
                .foregroundStyle(.secondary)
            Button("Move \(model.selectedTrashURLs.count) to Trash") {
                model.trashSelected()
            }
            .disabled(model.selectedTrashURLs.isEmpty || model.hasInvalidCustomSelection
                      || model.finder.isScanning)
            Button("Cancel") { model.dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
    }

    private func duplicateGroup(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.members.count) copies")
                    .font(.headline)
                Text(group.size, format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
                Text("wastes \(group.wastedBytes.formatted(.byteCount(style: .file)))")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Keep", selection: Binding(
                    get: { model.mode(for: group) },
                    set: { model.setMode($0, for: group) })) {
                    ForEach(DuplicateMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            ForEach(group.members, id: \.url) { member in
                duplicateMember(member, group: group)
            }
        }
        .padding(.vertical, 6)
    }

    private func duplicateMember(_ member: DuplicateMember,
                                 group: DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            if model.mode(for: group) == .custom {
                Toggle("", isOn: Binding(
                    get: { model.isKept(member, in: group) },
                    set: { model.setKept($0, member: member, in: group) }))
                    .labelsHidden()
                    .frame(width: 20)
            } else {
                if keptByStrategy(member, group: group) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(width: 20)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                        .frame(width: 20)
                }
            }
            Text(relativePath(member.url))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(member.modified,
                 format: .dateTime.year().month(.abbreviated).day().hour().minute())
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func keptByStrategy(_ member: DuplicateMember,
                                group: DuplicateGroup) -> Bool {
        let trashed = DuplicateKeepPlanner.trashPlan(group: group,
                                                     strategy: model.strategy(for: group)) ?? []
        return !trashed.contains(member.url)
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = model.root?.standardizedFileURL.path else {
            return url.path
        }
        let path = url.standardizedFileURL.path
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
