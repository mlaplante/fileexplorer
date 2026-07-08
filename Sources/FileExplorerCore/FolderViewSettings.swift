import Foundation

public struct FolderViewSettings: Codable, Equatable, Sendable {
    public var viewMode: String
    public var groupBy: Grouper.Axis
    public var showHidden: Bool
    public var sort: [SortToken]

    public init(viewMode: String = PaneState.ViewMode.list.rawValue,
                groupBy: Grouper.Axis = .none,
                showHidden: Bool = false,
                sort: [SortToken] = []) {
        self.viewMode = viewMode
        self.groupBy = groupBy
        self.showHidden = showHidden
        self.sort = sort
    }
}

