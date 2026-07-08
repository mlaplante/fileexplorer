import SwiftUI
import FileExplorerCore

struct OperationQueueOverlay: View {
    @Bindable var model: OperationQueueModel

    var body: some View {
        if !model.visibleOperations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Operations")
                        .font(.headline)
                    Spacer()
                    Button("Clear") { model.clearFinished() }
                        .font(.caption)
                }
                ForEach(model.visibleOperations) { operation in
                    row(operation)
                }
            }
            .padding(10)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 8, y: 2)
            .padding(12)
        }
    }

    private func row(_ operation: QueuedOperation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: operation.status))
                    .foregroundStyle(color(for: operation.status))
                Text(operation.title)
                    .lineLimit(1)
                Spacer()
                Text(label(for: operation.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: operation.fractionCompleted)
                .progressViewStyle(.linear)
            if let failure = operation.failures.first {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .font(.callout)
    }

    private func icon(for status: QueuedOperation.Status) -> String {
        switch status {
        case .pending: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private func color(for status: QueuedOperation.Status) -> Color {
        switch status {
        case .pending, .running: .accentColor
        case .succeeded: .green
        case .failed: .orange
        case .cancelled: .secondary
        }
    }

    private func label(for status: QueuedOperation.Status) -> String {
        switch status {
        case .pending: "Pending"
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
