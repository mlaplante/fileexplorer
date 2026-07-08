import Foundation
import FileExplorerCore

@MainActor
func operationConflictPlannerTests() async {
    await test("operation planner writes when destination has no collision") {
        let root = URL(fileURLWithPath: "/tmp/fx-plan")
        let source = root.appendingPathComponent("source/a.txt")
        let destination = root.appendingPathComponent("dest")

        let plan = OperationConflictPlanner.plan(
            operation: .copy,
            sources: [source],
            into: destination,
            existingNames: [])

        expectEqual(plan.items, [
            .init(source: source.standardizedFileURL,
                  action: .write(to: destination.standardizedFileURL
                    .appendingPathComponent("a.txt")))
        ], "plain copy writes to same name")
        expect(!plan.hasConflicts, "no conflicts")
        expect(!plan.hasFailures, "no failures")
    }

    await test("operation planner asks on collision by default") {
        let root = URL(fileURLWithPath: "/tmp/fx-plan")
        let source = root.appendingPathComponent("source/a.txt")
        let destination = root.appendingPathComponent("dest")

        let plan = OperationConflictPlanner.plan(
            operation: .move,
            sources: [source],
            into: destination,
            existingNames: ["a.txt"])

        expectEqual(plan.items.first?.action,
                    .conflict(existing: destination.standardizedFileURL
                        .appendingPathComponent("a.txt")),
                    "default policy surfaces a conflict")
        expect(plan.hasConflicts, "conflict flag is set")
    }

    await test("operation planner applies replace skip and keep-both policies") {
        let root = URL(fileURLWithPath: "/tmp/fx-plan")
        let source = root.appendingPathComponent("source/report.txt")
        let destination = root.appendingPathComponent("dest")

        let replace = OperationConflictPlanner.plan(
            operation: .copy,
            sources: [source],
            into: destination,
            existingNames: ["report.txt"],
            policy: .replace)
        expectEqual(replace.items.first?.action,
                    .replace(existing: destination.standardizedFileURL
                        .appendingPathComponent("report.txt")),
                    "replace targets the existing file")

        let skip = OperationConflictPlanner.plan(
            operation: .copy,
            sources: [source],
            into: destination,
            existingNames: ["report.txt"],
            policy: .skip)
        expectEqual(skip.items.first?.action, .skip, "skip omits the item")

        let keepBoth = OperationConflictPlanner.plan(
            operation: .copy,
            sources: [source],
            into: destination,
            existingNames: ["report.txt"],
            policy: .keepBoth)
        expectEqual(keepBoth.items.first?.action,
                    .write(to: destination.standardizedFileURL
                        .appendingPathComponent("report copy.txt")),
                    "keep both uses Finder-style copy naming")
    }

    await test("operation planner keeps generated names unique in one batch") {
        let root = URL(fileURLWithPath: "/tmp/fx-plan")
        let left = root.appendingPathComponent("left/same.txt")
        let right = root.appendingPathComponent("right/same.txt")
        let destination = root.appendingPathComponent("dest")

        let plan = OperationConflictPlanner.plan(
            operation: .copy,
            sources: [left, right],
            into: destination,
            existingNames: ["same.txt"],
            policy: .keepBoth)

        let names = plan.items.compactMap { item -> String? in
            if case .write(let url) = item.action { return url.lastPathComponent }
            return nil
        }
        expectEqual(names, ["same copy.txt", "same copy 2.txt"],
                    "batch keep-both names do not collide with each other")
    }

    await test("operation planner rejects putting a folder inside itself") {
        let root = URL(fileURLWithPath: "/tmp/fx-plan")
        let folder = root.appendingPathComponent("folder")
        let child = folder.appendingPathComponent("child")

        let plan = OperationConflictPlanner.plan(
            operation: .move,
            sources: [folder],
            into: child,
            existingNames: [])

        if case .fail(let message) = plan.items.first?.action {
            expect(message.contains("inside itself"),
                   "failure explains the self-nesting guard")
        } else {
            expect(false, "self-nesting must fail")
        }
        expect(plan.hasFailures, "failure flag is set")
    }

    await test("operation planner resolves existing conflicts with a chosen policy") {
        let root = URL(fileURLWithPath: "/tmp/fx-plan")
        let destination = root.appendingPathComponent("dest")
        let source = root.appendingPathComponent("source/report.txt")
        let existing = destination.appendingPathComponent("report.txt")
        let conflictPlan = OperationConflictPlanner.Plan(
            operation: .copy,
            destination: destination,
            items: [.init(source: source, action: .conflict(existing: existing))])

        let replace = OperationConflictPlanner.resolving(conflictPlan,
                                                         policy: .replace)
        expectEqual(replace.items.first?.action, .replace(existing: existing),
                    "replace policy turns conflict into replace")

        let skip = OperationConflictPlanner.resolving(conflictPlan, policy: .skip)
        expectEqual(skip.items.first?.action, .skip,
                    "skip policy turns conflict into skip")

        let keepBoth = OperationConflictPlanner.resolving(conflictPlan,
                                                          policy: .keepBoth)
        expectEqual(keepBoth.items.first?.action,
                    .write(to: destination.appendingPathComponent("report copy.txt")),
                    "keep-both policy writes to copy name")
    }

    await test("operation planner keep-both resolution avoids names already in plan") {
        let root = URL(fileURLWithPath: "/tmp/fx-plan")
        let destination = root.appendingPathComponent("dest")
        let conflictSource = root.appendingPathComponent("source/report.txt")
        let existing = destination.appendingPathComponent("report.txt")
        let plannedCopy = destination.appendingPathComponent("report copy.txt")
        let conflictPlan = OperationConflictPlanner.Plan(
            operation: .copy,
            destination: destination,
            items: [
                .init(source: root.appendingPathComponent("source/other.txt"),
                      action: .write(to: plannedCopy)),
                .init(source: conflictSource, action: .conflict(existing: existing)),
            ])

        let resolved = OperationConflictPlanner.resolving(conflictPlan,
                                                          policy: .keepBoth)
        expectEqual(resolved.items.last?.action,
                    .write(to: destination.appendingPathComponent("report copy 2.txt")),
                    "keep-both skips names already assigned by clean items")
    }
}
