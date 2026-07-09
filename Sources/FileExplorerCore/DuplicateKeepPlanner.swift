import Foundation

public struct DuplicateGroup: Equatable, Identifiable, Sendable {
    public let hash: String
    public let size: Int64
    public let members: [DuplicateMember]

    public var id: String { hash }
    public var wastedBytes: Int64 { size * Int64(max(0, members.count - 1)) }

    public init(hash: String, size: Int64, members: [DuplicateMember]) {
        self.hash = hash
        self.size = size
        self.members = members
    }
}

public struct DuplicateMember: Equatable, Sendable {
    public let url: URL
    public let modified: Date

    public init(url: URL, modified: Date) {
        self.url = url
        self.modified = modified
    }
}

public enum KeepStrategy: Equatable, Sendable {
    case newest
    case oldest
    case custom(keep: Set<URL>)
}

public enum DuplicateKeepPlanner {
    public static func trashPlan(group: DuplicateGroup,
                                 strategy: KeepStrategy) -> [URL]? {
        guard !group.members.isEmpty else { return [] }
        let keep: Set<URL>
        switch strategy {
        case .newest:
            keep = [chosenMember(in: group.members, newest: true).url]
        case .oldest:
            keep = [chosenMember(in: group.members, newest: false).url]
        case .custom(let urls):
            let memberURLs = Set(group.members.map(\.url))
            keep = urls.intersection(memberURLs)
            guard !keep.isEmpty else { return nil }
        }
        guard keep.count < group.members.count else { return [] }
        return sortedMembers(group.members).map(\.url).filter { !keep.contains($0) }
    }

    public static func combinedPlan(
        _ selections: [(DuplicateGroup, KeepStrategy)]
    ) -> [URL] {
        selections.flatMap { group, strategy in
            trashPlan(group: group, strategy: strategy) ?? []
        }
    }

    private static func chosenMember(in members: [DuplicateMember],
                                     newest: Bool) -> DuplicateMember {
        members.sorted { lhs, rhs in
            if lhs.modified != rhs.modified {
                return newest ? lhs.modified > rhs.modified : lhs.modified < rhs.modified
            }
            return lhs.url.path < rhs.url.path
        }[0]
    }

    private static func sortedMembers(_ members: [DuplicateMember]) -> [DuplicateMember] {
        members.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.path < rhs.url.path
        }
    }
}
