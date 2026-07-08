import Foundation

public enum OperationConflictPlanner {
    public enum Operation: String, Sendable, Codable, Equatable {
        case copy
        case move
        case sync
    }

    public enum ConflictPolicy: String, Sendable, Codable, Equatable {
        case ask
        case replace
        case keepBoth
        case skip
    }

    public enum ItemAction: Sendable, Equatable {
        case write(to: URL)
        case replace(existing: URL)
        case skip
        case conflict(existing: URL)
        case fail(String)
    }

    public struct Item: Sendable, Equatable {
        public let source: URL
        public let action: ItemAction

        public init(source: URL, action: ItemAction) {
            self.source = source
            self.action = action
        }
    }

    public struct Plan: Sendable, Equatable {
        public let operation: Operation
        public let destination: URL
        public let items: [Item]

        public init(operation: Operation, destination: URL, items: [Item]) {
            self.operation = operation
            self.destination = destination
            self.items = items
        }

        public var hasConflicts: Bool {
            items.contains {
                if case .conflict = $0.action { return true }
                return false
            }
        }

        public var hasFailures: Bool {
            items.contains {
                if case .fail = $0.action { return true }
                return false
            }
        }
    }

    public static func plan(
        operation: Operation,
        sources: [URL],
        into destination: URL,
        existingNames: Set<String>,
        policy: ConflictPolicy = .ask
    ) -> Plan {
        let destination = destination.standardizedFileURL
        var virtualExisting = existingNames
        let items = sources.map { source in
            planItem(source: source.standardizedFileURL,
                     destination: destination,
                     existingNames: &virtualExisting,
                     policy: policy)
        }
        return Plan(operation: operation, destination: destination, items: items)
    }

    public static func plan(
        operation: Operation,
        sources: [URL],
        into destination: URL,
        policy: ConflictPolicy = .ask
    ) -> Plan {
        let existing = Set((try? FileManager.default.contentsOfDirectory(
            atPath: destination.path)) ?? [])
        return plan(operation: operation, sources: sources, into: destination,
                    existingNames: existing, policy: policy)
    }

    public static func resolving(_ plan: Plan, policy: ConflictPolicy) -> Plan {
        guard policy != .ask else { return plan }
        var existingNames = Set<String>()
        for item in plan.items {
            switch item.action {
            case .write(let target):
                existingNames.insert(target.lastPathComponent)
            case .replace(let existing), .conflict(let existing):
                existingNames.insert(existing.lastPathComponent)
            case .skip, .fail:
                break
            }
        }
        let items = plan.items.map { item -> Item in
            guard case .conflict(let existing) = item.action else { return item }
            switch policy {
            case .ask:
                return item
            case .replace:
                return Item(source: item.source, action: .replace(existing: existing))
            case .skip:
                return Item(source: item.source, action: .skip)
            case .keepBoth:
                let name = CollisionNamer.copyName(
                    for: existing.lastPathComponent,
                    existing: existingNames)
                existingNames.insert(name)
                return Item(source: item.source,
                            action: .write(to: plan.destination
                                .appendingPathComponent(name)))
            }
        }
        return Plan(operation: plan.operation, destination: plan.destination,
                    items: items)
    }

    private static func planItem(
        source: URL,
        destination: URL,
        existingNames: inout Set<String>,
        policy: ConflictPolicy
    ) -> Item {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            return Item(source: source, action: .fail(
                "Can't put “\(source.lastPathComponent)” inside itself."))
        }

        let name = source.lastPathComponent
        let target = destination.appendingPathComponent(name)
        guard existingNames.contains(name) else {
            existingNames.insert(name)
            return Item(source: source, action: .write(to: target))
        }

        switch policy {
        case .ask:
            return Item(source: source, action: .conflict(existing: target))
        case .replace:
            return Item(source: source, action: .replace(existing: target))
        case .skip:
            return Item(source: source, action: .skip)
        case .keepBoth:
            let keepBothName = CollisionNamer.copyName(for: name,
                                                       existing: existingNames)
            existingNames.insert(keepBothName)
            return Item(source: source,
                        action: .write(to: destination.appendingPathComponent(
                            keepBothName)))
        }
    }
}
