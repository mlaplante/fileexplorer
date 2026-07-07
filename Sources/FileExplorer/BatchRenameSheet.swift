import SwiftUI
import FileExplorerCore

@MainActor
@Observable
final class BatchRenameModel {
    var targets: [URL] = []
    var rules = RenameRules()
    var existingNames: Set<String> = []

    var isPresented: Bool { !targets.isEmpty }

    var preview: [RenamePlan.Item] {
        RenamePlan.plan(urls: targets, rules: rules, existingNames: existingNames)
    }

    var applicableCount: Int {
        preview.filter { $0.conflict == nil }.count
    }

    func present(targets: [URL], existingNames: Set<String>) {
        rules = RenameRules()
        self.existingNames = existingNames
        self.targets = targets
    }

    func dismiss() {
        targets = []
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
                    Toggle("Number sequentially", isOn: $model.rules.numbering)
                        .gridCellColumns(2)
                    Stepper("Start: \(model.rules.numberStart)",
                            value: $model.rules.numberStart, in: 0...9999)
                    Stepper("Digits: \(model.rules.numberPadding)",
                            value: $model.rules.numberPadding, in: 1...6)
                }
            }
            .textFieldStyle(.roundedBorder)

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
                    model.dismiss()
                    onConfirm(targets, rules)
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
        case .unchanged: return "unchanged"
        }
    }
}
