import SwiftUI
import FileExplorerCore

@MainActor
@Observable
final class ConflictResolutionModel {
    var plan: OperationConflictPlanner.Plan?
    var title = "Resolve Conflicts"
    @ObservationIgnored weak var pane: PaneState?

    var isPresented: Bool { plan != nil }

    var conflicts: [OperationConflictPlanner.Item] {
        guard let plan else { return [] }
        return plan.items.filter {
            if case .conflict = $0.action { return true }
            return false
        }
    }

    func present(plan: OperationConflictPlanner.Plan, title: String,
                 pane: PaneState) {
        self.plan = plan
        self.title = title
        self.pane = pane
    }

    func dismiss() {
        plan = nil
        pane = nil
        title = "Resolve Conflicts"
    }

    func apply(_ policy: OperationConflictPlanner.ConflictPolicy) {
        guard let plan, let pane else { return }
        let resolved = OperationConflictPlanner.resolving(plan, policy: policy)
        let action = actionName(for: plan.operation)
        dismiss()
        Task { await pane.executeResolvedPlan(resolved, actionName: action) }
    }

    private func actionName(for operation: OperationConflictPlanner.Operation) -> String {
        switch operation {
        case .copy: "Copy"
        case .move: "Move"
        case .sync: "Sync"
        }
    }
}

struct ConflictResolutionSheet: View {
    @Bindable var model: ConflictResolutionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title)
                .font(.headline)
            Text("\(model.conflicts.count) item\(model.conflicts.count == 1 ? "" : "s") already exist in the destination.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.conflicts, id: \.source) { item in
                        conflictRow(item)
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Button("Skip") { model.apply(.skip) }
                Button("Keep Both") { model.apply(.keepBoth) }
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace") { model.apply(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func conflictRow(_ item: OperationConflictPlanner.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.lastPathComponent)
                    .font(.callout)
                if case .conflict(let existing) = item.action {
                    Text(existing.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
    }
}

