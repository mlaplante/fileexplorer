import Foundation

/// App-wide preferences persisted as `settings.json`. Every field decodes
/// with a default so files written by any version keep loading.
public struct AppSettings: Codable, Equatable, Sendable {
    public var jpegQuality: Double
    public var filterPresets: [FilterPreset]
    public var updateCheckEnabled: Bool
    public var lastUpdateCheckAt: Date?
    public var shortcutOverrides: [String: KeyChord]
    public var knownTags: [String]
    public var folderViewSettings: [String: FolderViewSettings]
    public var workspaceProfiles: [WorkspaceProfile]
    public var smartFolders: [SmartFolder]
    public var terminalAppPath: String?
    public var editorAppPath: String?

    public init(jpegQuality: Double = 0.85, filterPresets: [FilterPreset] = [],
                updateCheckEnabled: Bool = true, lastUpdateCheckAt: Date? = nil,
                shortcutOverrides: [String: KeyChord] = [:],
                knownTags: [String] = [],
                folderViewSettings: [String: FolderViewSettings] = [:],
                workspaceProfiles: [WorkspaceProfile] = [],
                smartFolders: [SmartFolder] = [],
                terminalAppPath: String? = nil,
                editorAppPath: String? = nil) {
        self.jpegQuality = min(max(jpegQuality, 0.1), 1.0)
        self.filterPresets = filterPresets
        self.updateCheckEnabled = updateCheckEnabled
        self.lastUpdateCheckAt = lastUpdateCheckAt
        self.shortcutOverrides = shortcutOverrides
        self.knownTags = Self.normalizedTags(knownTags)
        self.folderViewSettings = folderViewSettings
        self.workspaceProfiles = Self.normalizedProfiles(workspaceProfiles)
        self.smartFolders = Self.normalizedSmartFolders(smartFolders)
        self.terminalAppPath = terminalAppPath
        self.editorAppPath = editorAppPath
    }

    enum CodingKeys: String, CodingKey {
        case jpegQuality, filterPresets, updateCheckEnabled, lastUpdateCheckAt,
             shortcutOverrides, knownTags, folderViewSettings
        case workspaceProfiles, smartFolders, terminalAppPath, editorAppPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.85
        jpegQuality = min(max(raw, 0.1), 1.0)
        filterPresets = try container.decodeIfPresent(
            [FilterPreset].self, forKey: .filterPresets) ?? []
        updateCheckEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .updateCheckEnabled) ?? true
        lastUpdateCheckAt = try container.decodeIfPresent(
            Date.self, forKey: .lastUpdateCheckAt)
        shortcutOverrides = try container.decodeIfPresent(
            [String: KeyChord].self, forKey: .shortcutOverrides) ?? [:]
        knownTags = Self.normalizedTags(try container.decodeIfPresent(
            [String].self, forKey: .knownTags) ?? [])
        folderViewSettings = try container.decodeIfPresent(
            [String: FolderViewSettings].self,
            forKey: .folderViewSettings) ?? [:]
        workspaceProfiles = Self.normalizedProfiles(try container.decodeIfPresent(
            [WorkspaceProfile].self, forKey: .workspaceProfiles) ?? [])
        smartFolders = Self.normalizedSmartFolders(try container.decodeIfPresent(
            [SmartFolder].self, forKey: .smartFolders) ?? [])
        terminalAppPath = try container.decodeIfPresent(
            String.self, forKey: .terminalAppPath)
        editorAppPath = try container.decodeIfPresent(
            String.self, forKey: .editorAppPath)
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags)).sorted { lhs, rhs in
            let insensitive = lhs.localizedCaseInsensitiveCompare(rhs)
            if insensitive != .orderedSame { return insensitive == .orderedAscending }
            return lhs.localizedCompare(rhs) == .orderedAscending
        }
    }

    public static func normalizedProfiles(_ profiles: [WorkspaceProfile])
        -> [WorkspaceProfile] {
        var byName: [String: WorkspaceProfile] = [:]
        for profile in profiles {
            let trimmed = profile.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            byName[trimmed] = WorkspaceProfile(name: trimmed,
                                               snapshot: profile.snapshot)
        }
        return byName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func normalizedSmartFolders(_ folders: [SmartFolder])
        -> [SmartFolder] {
        var byName: [String: SmartFolder] = [:]
        for folder in folders {
            let trimmed = folder.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !folder.rootPath.isEmpty else { continue }
            byName[trimmed] = SmartFolder(name: trimmed,
                                          root: folder.rootURL,
                                          filter: folder.filter)
        }
        return byName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Atomic JSON persistence for the session and settings. Load failures of
/// any kind (missing, corrupt, wrong shape) degrade to nil/defaults — the
/// app must never fail to launch over a bad state file. Save failures are
/// logged and swallowed.
/// (Valid-but-empty JSON decodes to a non-nil, all-defaults snapshot; the
/// session restore inits absorb that shape safely downstream.)
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
