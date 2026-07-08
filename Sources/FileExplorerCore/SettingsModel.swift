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
}
