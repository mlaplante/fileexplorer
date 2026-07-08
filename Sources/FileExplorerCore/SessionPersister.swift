import Foundation

/// App-wide preferences persisted as `settings.json`. Every field decodes
/// with a default so files written by any version keep loading.
public struct AppSettings: Codable, Equatable, Sendable {
    public var jpegQuality: Double

    public init(jpegQuality: Double = 0.85) {
        self.jpegQuality = jpegQuality
    }

    enum CodingKeys: String, CodingKey { case jpegQuality }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jpegQuality = try container.decodeIfPresent(
            Double.self, forKey: .jpegQuality) ?? 0.85
    }
}

/// Atomic JSON persistence for the session and settings. Load failures of
/// any kind (missing, corrupt, wrong shape) degrade to nil/defaults — the
/// app must never fail to launch over a bad state file. Save failures are
/// logged and swallowed.
public struct SessionPersister: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("FileExplorer", isDirectory: true)
    }

    private var sessionFile: URL { directory.appendingPathComponent("session.json") }
    private var settingsFile: URL { directory.appendingPathComponent("settings.json") }

    public func loadSession() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func saveSession(_ snapshot: SessionSnapshot) {
        write(snapshot, to: sessionFile)
    }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFile),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func saveSettings(_ settings: AppSettings) {
        write(settings, to: settingsFile)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: file, options: .atomic)
        } catch {
            NSLog("FileExplorer: failed to save %@: %@",
                  file.lastPathComponent, String(describing: error))
        }
    }
}
