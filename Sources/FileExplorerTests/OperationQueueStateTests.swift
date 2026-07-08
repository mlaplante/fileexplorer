import Foundation
import FileExplorerCore

@MainActor
func operationQueueStateTests() async {
    await test("operation queue starts pending jobs in order") {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let plan = sampleOperationPlan(name: "a.txt")
        var queue = OperationQueueState()

        queue.enqueue(plan, title: "Copy A", id: firstID)
        queue.enqueue(sampleOperationPlan(name: "b.txt"), title: "Copy B", id: secondID)

        expectEqual(queue.startNext(), firstID, "first pending job starts")
        expectEqual(queue.operations.map(\.status), [.running, .pending],
                    "only first job is running")
        expectEqual(queue.startNext(), secondID, "second pending job starts next")
    }

    await test("operation queue tracks progress and success") {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        var queue = OperationQueueState()
        queue.enqueue(sampleOperationPlan(name: "a.txt", count: 4),
                      title: "Copy Batch", id: id)
        _ = queue.startNext()
        queue.updateProgress(id: id, completed: 2)

        expectEqual(queue.operations.first?.fractionCompleted, 0.5,
                    "fraction reflects completed units")
        queue.succeed(id: id)
        expectEqual(queue.operations.first?.status, .succeeded, "job succeeded")
        expectEqual(queue.operations.first?.fractionCompleted, 1,
                    "success completes progress")
    }

    await test("operation queue records failures and creates retry jobs") {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let retryID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let source = URL(fileURLWithPath: "/tmp/source/a.txt")
        var queue = OperationQueueState()
        queue.enqueue(sampleOperationPlan(name: "a.txt"), title: "Copy A", id: id)
        _ = queue.startNext()
        queue.fail(id: id, failures: [
            .init(source: source, message: "Permission denied")
        ])

        expectEqual(queue.operations.first?.status, .failed, "job failed")
        expect(queue.operations.first?.canRetry == true, "failed item can retry")
        expectEqual(queue.enqueueRetry(for: id, retryID: retryID), retryID,
                    "retry job is enqueued")
        expectEqual(queue.operations.last?.title, "Copy A Retry", "retry title")
        expectEqual(queue.operations.last?.plan.items.map(\.source), [source],
                    "retry includes only failed sources")
    }

    await test("operation queue cancellation only affects pending or running jobs") {
        let runningID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let doneID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        var queue = OperationQueueState()
        queue.enqueue(sampleOperationPlan(name: "a.txt"), title: "Copy A", id: runningID)
        queue.enqueue(sampleOperationPlan(name: "b.txt"), title: "Copy B", id: doneID)
        _ = queue.startNext()
        queue.succeed(id: doneID)

        queue.cancel(id: runningID)
        queue.cancel(id: doneID)

        expectEqual(queue.operations.first?.status, .cancelled,
                    "running job can cancel")
        expectEqual(queue.operations.last?.status, .succeeded,
                    "succeeded job is not cancelled")
    }
}

private func sampleOperationPlan(name: String, count: Int = 1)
    -> OperationConflictPlanner.Plan {
    let destination = URL(fileURLWithPath: "/tmp/dest")
    let items = (0..<count).map { index in
        let filename = count == 1 ? name : "\(index)-\(name)"
        let source = URL(fileURLWithPath: "/tmp/source")
            .appendingPathComponent(filename)
        return OperationConflictPlanner.Item(
            source: source,
            action: .write(to: destination.appendingPathComponent(filename)))
    }
    return OperationConflictPlanner.Plan(operation: .copy, destination: destination,
                                         items: items)
}

