import Foundation

public struct WorkspaceProfile: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var snapshot: SessionSnapshot

    public var id: String { name }

    public init(name: String, snapshot: SessionSnapshot) {
        self.name = name
        self.snapshot = snapshot
    }
}

