import Foundation
import Observation

public struct TrashRecord: Codable, Equatable, Sendable {
    public var original: URL
    public var trashed: URL

    public init(original: URL, trashed: URL) {
        self.original = original.standardizedFileURL
        self.trashed = trashed.standardizedFileURL
    }
}

public struct TrashRegistry: Codable, Equatable, Sendable {
    public private(set) var records: [TrashRecord]

    public init(records: [TrashRecord] = []) {
        self.records = records
    }

    public var isEmpty: Bool { records.isEmpty }

    private static let filename = "trash-registry.json"

    public mutating func record(original: URL, trashed: URL) {
        let newRecord = TrashRecord(original: original, trashed: trashed)
        records.removeAll {
            $0.trashed.standardizedFileURL == newRecord.trashed
                || $0.original.standardizedFileURL == newRecord.original
        }
        records.append(newRecord)
    }

    public func original(forTrashed trashed: URL) -> URL? {
        let standardized = trashed.standardizedFileURL
        return records.first { $0.trashed.standardizedFileURL == standardized }?.original
    }

    public mutating func remove(trashed: URL) {
        let standardized = trashed.standardizedFileURL
        records.removeAll { $0.trashed.standardizedFileURL == standardized }
    }

    public mutating func prune(fileManager: FileManager = .default) {
        records.removeAll { !fileManager.fileExists(atPath: $0.trashed.path) }
    }

    public static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains {
            $0 == ".Trash" || $0 == "Trash"
        }
    }

    public static func load(from directory: URL) -> TrashRegistry {
        let file = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: file),
              let registry = try? JSONDecoder().decode(TrashRegistry.self, from: data)
        else { return TrashRegistry() }
        return registry
    }

    public func save(to directory: URL) {
        let file = directory.appendingPathComponent(Self.filename)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: file, options: .atomic)
        } catch {
            NSLog("FileExplorer: failed to save trash registry: %@",
                  String(describing: error))
        }
    }
}

@MainActor
@Observable
public final class TrashRegistryModel {
    public private(set) var registry: TrashRegistry
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        registry = TrashRegistry.load(from: directory)
    }

    public func record(original: URL, trashed: URL) {
        registry.record(original: original, trashed: trashed)
        registry.save(to: directory)
    }

    public func original(forTrashed trashed: URL) -> URL? {
        registry.original(forTrashed: trashed)
    }

    public func remove(trashed: URL) {
        registry.remove(trashed: trashed)
        registry.save(to: directory)
    }

    public func canPutBack(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy {
            TrashRegistry.isInTrash($0) && original(forTrashed: $0) != nil
        }
    }
}
