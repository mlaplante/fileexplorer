import Foundation

public enum SortMenu {
    public enum Axis: String, CaseIterable, Sendable {
        case name
        case size
        case kind
        case dateModified

        public var title: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            case .kind: "Kind"
            case .dateModified: "Date Modified"
            }
        }
    }

    public struct State: Equatable, Sendable {
        public var axis: Axis
        public var ascending: Bool
    }

    public static func axis(of comparators: [KeyPathComparator<FileEntry>]) -> Axis {
        state(of: comparators).axis
    }

    public static func state(of comparators: [KeyPathComparator<FileEntry>]) -> State {
        guard let token = SortTokenCoder.tokens(from: comparators).first else {
            return State(axis: .name, ascending: true)
        }
        return State(axis: axis(for: token.field), ascending: token.ascending)
    }

    public static func comparators(for axis: Axis,
                                   ascending: Bool) -> [KeyPathComparator<FileEntry>] {
        SortTokenCoder.comparators(from: [
            SortToken(field: field(for: axis), ascending: ascending),
        ])
    }

    public static func toggledOrder(
        current: [KeyPathComparator<FileEntry>],
        selecting axis: Axis
    ) -> [KeyPathComparator<FileEntry>] {
        let currentState = state(of: current)
        let ascending = currentState.axis == axis ? !currentState.ascending : true
        return comparators(for: axis, ascending: ascending)
    }

    private static func field(for axis: Axis) -> SortToken.Field {
        switch axis {
        case .name: .name
        case .size: .size
        case .kind: .kind
        case .dateModified: .modified
        }
    }

    private static func axis(for field: SortToken.Field) -> Axis {
        switch field {
        case .name: .name
        case .size: .size
        case .kind: .kind
        case .modified: .dateModified
        }
    }
}
