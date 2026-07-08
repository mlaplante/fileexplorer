import SwiftUI
import FileExplorerCore

/// Content of the Get Info window: follows the active pane's selection.
/// No @State on this toolchain — all state lives on GetInfoModel.
struct GetInfoView: View {
    let session: SessionState
    let model: GetInfoModel

    var body: some View {
        Group {
            if model.infos.isEmpty {
                Text("No Selection")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.infos.count == 1, let info = model.infos.first {
                singleItem(info)
            } else {
                multiItem
            }
        }
        .padding()
        .frame(minWidth: 300, idealWidth: 320, minHeight: 340)
        .onAppear { model.update(for: Array(session.activePane.selection)) }
        .onChange(of: session.activePane.selection) { _, newValue in
            model.update(for: Array(newValue))
        }
    }

    @ViewBuilder
    private func singleItem(_ info: ItemInfo) -> some View {
        Form {
            LabeledContent("Name", value: info.name)
            LabeledContent("Kind", value: info.kind)
            if let size = info.size {
                LabeledContent("Size", value: size.formatted(.byteCount(style: .file)))
            } else {
                LabeledContent("Size", value: "— (use Calculate Size)")
            }
            if let created = info.created {
                LabeledContent("Created",
                               value: created.formatted(date: .abbreviated,
                                                        time: .shortened))
            }
            if let modified = info.modified {
                LabeledContent("Modified",
                               value: modified.formatted(date: .abbreviated,
                                                         time: .shortened))
            }
            LabeledContent("Permissions",
                           value: "\(info.permissions)  \(info.owner):\(info.group)")
            if let target = info.symlinkTarget {
                LabeledContent("Links To", value: target)
            }
            if !info.whereFroms.isEmpty {
                LabeledContent("Where From",
                               value: info.whereFroms.joined(separator: "\n"))
            }
            LabeledContent("Location", value: info.url.deletingLastPathComponent()
                .path(percentEncoded: false))
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    private var multiItem: some View {
        VStack(spacing: 12) {
            Text("\(model.infos.count) Items")
                .font(.title2)
            Text("Files: \(model.totalFileSize.formatted(.byteCount(style: .file)))"
                 + " (folders not counted)")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
