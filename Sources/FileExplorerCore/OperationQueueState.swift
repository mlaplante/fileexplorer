import Foundation
import Observation

public struct QueuedOperation: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable, Equatable {
        case pending
        case running
        case succeeded
        case failed
        case cancelled
    }

    public struct Failure: Sendable, Equatable {
        public let source: URL
        public let message: String

        public init(source: URL, message: String) {
            self.source = source
            self.message = message
        }
    }

    public let id: UUID
    public var title: String
    public var plan: OperationConflictPlanner.Plan
    public var status: Status
    public var completedUnitCount: Int
    public var totalUnitCount: Int
    public var failures: [Failure]

    public init(id: UUID = UUID(), title: String,
                plan: OperationConflictPlanner.Plan,
                status: Status = .pending,
                completedUnitCount: Int = 0,
                totalUnitCount: Int? = nil,
                failures: [Failure] = []) {
        self.id = id
        self.title = title
        self.plan = plan
        self.status = status
        self.completedUnitCount = max(0, completedUnitCount)
        self.totalUnitCount = max(0, totalUnitCount ?? plan.items.count)
        self.failures = failures
    }

    public var fractionCompleted: Double {
        guard totalUnitCount > 0 else { return status == .succeeded ? 1 : 0 }
        return min(1, Double(completedUnitCount) / Double(totalUnitCount))
    }

    public var canRetry: Bool {
        status == .failed && !failures.isEmpty
    }
}

public struct OperationQueueState: Sendable, Equatable {
    public private(set) var operations: [QueuedOperation] = []

    public init() {}

    @discardableResult
    public mutating func enqueue(_ plan: OperationConflictPlanner.Plan,
                                 title: String,
                                 id: UUID = UUID()) -> UUID {
        operations.append(QueuedOperation(id: id, title: title, plan: plan))
        return id
    }

    @discardableResult
    public mutating func startNext() -> UUID? {
        guard let index = operations.firstIndex(where: { $0.status == .pending })
        else { return nil }
        operations[index].status = .running
        return operations[index].id
    }

    public mutating func updateProgress(id: UUID, completed: Int, total: Int? = nil) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].completedUnitCount = max(0, completed)
        if let total {
            operations[index].totalUnitCount = max(0, total)
        }
    }

    public mutating func succeed(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .succeeded
        operations[index].completedUnitCount = operations[index].totalUnitCount
        operations[index].failures = []
    }

    public mutating func fail(id: UUID, failures: [QueuedOperation.Failure]) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .failed
        operations[index].failures = failures
    }

    public mutating func cancel(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }),
              operations[index].status == .pending || operations[index].status == .running
        else { return }
        operations[index].status = .cancelled
    }

    @discardableResult
    public mutating func enqueueRetry(for id: UUID, retryID: UUID = UUID()) -> UUID? {
        guard let failed = operations.first(where: { $0.id == id && $0.canRetry })
        else { return nil }
        let retryPlan = OperationConflictPlanner.Plan(
            operation: failed.plan.operation,
            destination: failed.plan.destination,
            items: failed.failures.map {
                OperationConflictPlanner.Item(source: $0.source,
                                              action: .conflict(existing: failed.plan
                                                .destination
                                                .appendingPathComponent(
                                                    $0.source.lastPathComponent)))
            })
        return enqueue(retryPlan, title: "\(failed.title) Retry", id: retryID)
    }
}

@MainActor
@Observable
public final class OperationQueueModel {
    public private(set) var state = OperationQueueState()

    public init() {}

    public var operations: [QueuedOperation] {
        state.operations
    }

    public var visibleOperations: [QueuedOperation] {
        Array(state.operations.suffix(5).reversed())
    }

    @discardableResult
    public func enqueue(_ plan: OperationConflictPlanner.Plan,
                        title: String,
                        id: UUID = UUID()) -> UUID {
        state.enqueue(plan, title: title, id: id)
    }

    public func startNext() -> UUID? {
        state.startNext()
    }

    public func updateProgress(id: UUID, completed: Int, total: Int? = nil) {
        state.updateProgress(id: id, completed: completed, total: total)
    }

    public func succeed(id: UUID) {
        state.succeed(id: id)
    }

    public func fail(id: UUID, failures: [QueuedOperation.Failure]) {
        state.fail(id: id, failures: failures)
    }

    public func cancel(id: UUID) {
        state.cancel(id: id)
    }

    public func clearFinished() {
        state = OperationQueueState(
            operations: state.operations.filter {
                $0.status == .pending || $0.status == .running
            })
    }
}

public extension OperationQueueState {
    init(operations: [QueuedOperation]) {
        self.init()
        self.operations = operations
    }
}
