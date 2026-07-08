import SwiftUI
import FileExplorerCore

@MainActor
@Observable
final class BatchRenameModel {
    var targets: [URL] = []
    var rules = RenameRules()
    var existingNames: Set<String> = []
    var metadata: [URL: RenameTokenMetadata] = [:]
    @ObservationIgnored weak var pane: PaneState?

    var isPresented: Bool { !targets.isEmpty }

    var preview: [RenamePlan.Item] {
        RenamePlan.plan(urls: targets, rules: rules,
                        existingNames: existingNames, metadata: metadata)
    }

    var applicableCount: Int {
        preview.filter { $0.conflict == nil }.count
    }

    func present(targets: [URL], existingNames: Set<String>, in pane: PaneState) {
        self.pane = pane
        rules = RenameRules()
        self.existingNames = existingNames
        self.targets = targets
        let gatherTargets = targets
        metadata = [:]
        Task {
            let gathered = await Task.detached(priority: .userInitiated) {
                var map: [URL: RenameTokenMetadata] = [:]
                for url in gatherTargets {
                    let modified = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    map[url] = RenameTokenMetadata(
                        modified: modified,
                        exifDate: ExifDateReader.captureDate(of: url))
                }
                return map
            }.value
            guard self.targets == gatherTargets else { return }
            self.metadata = gathered
        }
    }

    func dismiss() {
        targets = []
        pane = nil
    }
}

struct BatchRenameSheet: View {
    @Bindable var model: BatchRenameModel
    var onConfirm: ([URL], RenameRules) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Batch Rename \(model.targets.count) Items")
                .font(.headline)

            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("Find:")
                    TextField("", text: $model.rules.find)
                    Text("Replace:")
                    TextField("", text: $model.rules.replace)
                }
                GridRow {
                    Text("Prefix:")
                    TextField("", text: $model.rules.prefix)
                    Text("Suffix:")
                    TextField("", text: $model.rules.suffix)
                }
                GridRow {
                    Toggle("Regex", isOn: $model.rules.useRegex)
                    Picker("Case", selection: Binding(
                        get: { model.rules.caseTransform },
                        set: { model.rules.caseTransform = $0 })) {
                        Text("Unchanged").tag(RenameTokens.CaseTransform?.none)
                        ForEach(RenameTokens.CaseTransform.allCases, id: \.self) { transform in
                            Text(transform.rawValue)
                                .tag(RenameTokens.CaseTransform?.some(transform))
                        }
                    }
                    .gridCellColumns(3)
                }
                GridRow {
                    Toggle("Number sequentially", isOn: $model.rules.numbering)
                        .gridCellColumns(2)
                    Stepper("Start: \(model.rules.numberStart)",
                            value: $model.rules.numberStart, in: 0...9999)
                    Stepper("Digits: \(model.rules.numberPadding)",
                            value: $model.rules.numberPadding, in: 1...6)
                }
            }
            .textFieldStyle(.roundedBorder)

            Text("Tokens: {modified:yyyy-MM-dd} and {exif:yyyy-MM-dd} work in Find, Replace, Prefix, and Suffix. Regex replace supports $1 captures.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.preview, id: \.source) { item in
                        HStack {
                            Text(item.source.lastPathComponent)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(item.newName)
                            Spacer()
                            if let conflict = item.conflict, conflict != .unchanged {
                                Text(label(for: conflict))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if item.conflict == .unchanged {
                                Text("unchanged")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename \(model.applicableCount)") {
                    let targets = model.targets
                    let rules = model.rules
                    onConfirm(targets, rules)
                    model.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.applicableCount == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func label(for conflict: RenamePlan.Conflict) -> String {
        switch conflict {
        case .duplicateTarget: return "duplicate"
        case .existingFile: return "exists"
        case .invalidName: return "invalid"
        case .invalidPattern: return "bad regex"
        case .unchanged: return "unchanged"
        }
    }
}
