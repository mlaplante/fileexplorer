import Foundation
import FileExplorerCore

@MainActor
func duplicateKeepPlannerTests() async {
    await test("DuplicateKeepPlanner newest keeps latest modified member") {
        let group = plannerGroup([
            ("old.txt", 10),
            ("new.txt", 30),
            ("mid.txt", 20),
        ])

        let plan = DuplicateKeepPlanner.trashPlan(group: group, strategy: .newest)

        expectEqual(plan, [memberURL("mid.txt"), memberURL("old.txt")],
                    "newest keeps latest and trashes the rest in member order")
    }

    await test("DuplicateKeepPlanner oldest keeps earliest modified member") {
        let group = plannerGroup([
            ("old.txt", 10),
            ("new.txt", 30),
            ("mid.txt", 20),
        ])

        let plan = DuplicateKeepPlanner.trashPlan(group: group, strategy: .oldest)

        expectEqual(plan, [memberURL("new.txt"), memberURL("mid.txt")],
                    "oldest keeps earliest and trashes newer copies")
    }

    await test("DuplicateKeepPlanner breaks modified ties by path") {
        let group = DuplicateGroup(hash: "abc", size: 10, members: [
            DuplicateMember(url: memberURL("b.txt"), modified: Date(timeIntervalSince1970: 10)),
            DuplicateMember(url: memberURL("a.txt"), modified: Date(timeIntervalSince1970: 10)),
            DuplicateMember(url: memberURL("c.txt"), modified: Date(timeIntervalSince1970: 5)),
        ])

        let newest = DuplicateKeepPlanner.trashPlan(group: group, strategy: .newest)
        let oldest = DuplicateKeepPlanner.trashPlan(group: group, strategy: .oldest)

        expectEqual(newest, [memberURL("b.txt"), memberURL("c.txt")],
                    "newest tie keeps path-ascending member")
        expectEqual(oldest, [memberURL("a.txt"), memberURL("b.txt")],
                    "oldest keeps earliest date before tied newer members")
    }

    await test("DuplicateKeepPlanner custom keeps checked set") {
        let group = plannerGroup([
            ("one.txt", 1),
            ("two.txt", 2),
            ("three.txt", 3),
        ])

        let plan = DuplicateKeepPlanner.trashPlan(
            group: group,
            strategy: .custom(keep: [memberURL("one.txt"), memberURL("three.txt")]))

        expectEqual(plan, [memberURL("two.txt")], "custom trashes unchecked members")
    }

    await test("DuplicateKeepPlanner custom refuses empty keep set and allows keeping all") {
        let group = plannerGroup([
            ("one.txt", 1),
            ("two.txt", 2),
        ])

        let empty = DuplicateKeepPlanner.trashPlan(group: group, strategy: .custom(keep: []))
        let all = DuplicateKeepPlanner.trashPlan(
            group: group,
            strategy: .custom(keep: Set(group.members.map(\.url))))

        expect(empty == nil, "empty custom keep set refused")
        expectEqual(all, [], "keeping every member trashes nothing")
    }

    await test("DuplicateKeepPlanner combinedPlan concatenates and skips nil groups") {
        let first = plannerGroup([
            ("a.txt", 1),
            ("b.txt", 2),
        ], hash: "one")
        let second = plannerGroup([
            ("c.txt", 1),
            ("d.txt", 2),
        ], hash: "two")

        let plan = DuplicateKeepPlanner.combinedPlan([
            (first, .newest),
            (second, .custom(keep: [])),
        ])

        expectEqual(plan, [memberURL("a.txt")], "combined plan skips invalid custom group")
    }
}

private func plannerGroup(_ members: [(String, TimeInterval)],
                          hash: String = "hash") -> DuplicateGroup {
    DuplicateGroup(
        hash: hash,
        size: 10,
        members: members
            .map {
                DuplicateMember(url: memberURL($0.0),
                                modified: Date(timeIntervalSince1970: $0.1))
            }
            .sorted { lhs, rhs in
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.url.path < rhs.url.path
            })
}

private func memberURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/duplicates").appendingPathComponent(name)
}
