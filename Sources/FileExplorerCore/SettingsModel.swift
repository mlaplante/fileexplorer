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
}
