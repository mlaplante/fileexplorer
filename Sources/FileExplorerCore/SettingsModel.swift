import Foundation
import Observation

/// Observable wrapper around `AppSettings` + its persister. UI mutations go
/// through setters so every change persists immediately (settings are tiny).
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var settings: AppSettings
    private let persister: SessionPersister

    public init(persister: SessionPersister) {
        self.persister = persister
        settings = persister.loadSettings()
    }

    public func setJPEGQuality(_ quality: Double) {
        settings.jpegQuality = AppSettings(jpegQuality: quality).jpegQuality
        persister.saveSettings(settings)
    }

    /// Saving under an existing name replaces that preset (name = identity).
    public func savePreset(name: String, filter: FilterState) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.filterPresets.removeAll { $0.name == trimmed }
        settings.filterPresets.append(FilterPreset(name: trimmed, filter: filter))
        persister.saveSettings(settings)
    }

    public func deletePreset(name: String) {
        settings.filterPresets.removeAll { $0.name == name }
        persister.saveSettings(settings)
    }

    public func setUpdateCheckEnabled(_ enabled: Bool) {
        settings.updateCheckEnabled = enabled
        persister.saveSettings(settings)
    }

    public func markUpdateCheck(at date: Date = Date()) {
        settings.lastUpdateCheckAt = date
        persister.saveSettings(settings)
    }

    public func setShortcutOverride(_ chord: KeyChord,
                                    for command: ShortcutRegistry.Command) {
        settings.shortcutOverrides[command.rawValue] = chord
        persister.saveSettings(settings)
    }

    public func clearShortcutOverride(for command: ShortcutRegistry.Command) {
        settings.shortcutOverrides.removeValue(forKey: command.rawValue)
        persister.saveSettings(settings)
    }

    public func resetAllShortcuts() {
        settings.shortcutOverrides = [:]
        persister.saveSettings(settings)
    }

    public func mergeKnownTags(_ tags: [String]) {
        let merged = AppSettings.normalizedTags(settings.knownTags + tags)
        guard merged != settings.knownTags else { return }
        settings.knownTags = merged
        persister.saveSettings(settings)
    }

    public func folderViewSettings(for url: URL) -> FolderViewSettings? {
        settings.folderViewSettings[url.standardizedFileURL.path]
    }

    public func setFolderViewSettings(_ viewSettings: FolderViewSettings,
                                      for url: URL) {
        let key = url.standardizedFileURL.path
        guard settings.folderViewSettings[key] != viewSettings else { return }
        settings.folderViewSettings[key] = viewSettings
        persister.saveSettings(settings)
    }

    public func saveWorkspaceProfile(name: String, snapshot: SessionSnapshot) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.workspaceProfiles.removeAll { $0.name == trimmed }
        settings.workspaceProfiles.append(WorkspaceProfile(name: trimmed,
                                                          snapshot: snapshot))
        settings.workspaceProfiles = AppSettings.normalizedProfiles(
            settings.workspaceProfiles)
        persister.saveSettings(settings)
    }

    public func deleteWorkspaceProfile(name: String) {
        settings.workspaceProfiles.removeAll { $0.name == name }
        persister.saveSettings(settings)
    }

    public func saveSmartFolder(name: String, root: URL, filter: FilterState) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, filter.isActive else { return }
        settings.smartFolders.removeAll { $0.name == trimmed }
        settings.smartFolders.append(SmartFolder(name: trimmed,
                                                root: root,
                                                filter: filter))
        settings.smartFolders = AppSettings.normalizedSmartFolders(
            settings.smartFolders)
        persister.saveSettings(settings)
    }

    public func deleteSmartFolder(name: String) {
        settings.smartFolders.removeAll { $0.name == name }
        persister.saveSettings(settings)
    }

    public func chord(for command: ShortcutRegistry.Command) -> KeyChord {
        ShortcutRegistry.effectiveChord(for: command,
                                        overrides: settings.shortcutOverrides)
    }
}
