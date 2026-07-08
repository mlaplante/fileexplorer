import Foundation
import FileExplorerCore

@MainActor
func settingsModelTests() async {
    await test("SettingsModel loads, updates, persists, and clamps quality") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)

        let model = SettingsModel(persister: persister)
        expectEqual(model.settings.jpegQuality, 0.85, "defaults on first launch")

        model.setJPEGQuality(0.6)
        expectEqual(model.settings.jpegQuality, 0.6, "update applies in memory")
        expectEqual(persister.loadSettings().jpegQuality, 0.6,
                    "update persists immediately")

        let reloaded = SettingsModel(persister: persister)
        expectEqual(reloaded.settings.jpegQuality, 0.6, "fresh model reads saved value")

        expectEqual(AppSettings(jpegQuality: 7).jpegQuality, 1.0,
                    "quality clamps to 1.0 max")
        expectEqual(AppSettings(jpegQuality: -1).jpegQuality, 0.1,
                    "quality clamps to 0.1 min")
    }

    await test("AppSettings without knownTags key still decodes") {
        let old = #"{"jpegQuality":0.9}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        expectEqual(decoded.jpegQuality, 0.9, "old field intact")
        expectEqual(decoded.knownTags, [], "missing knownTags defaults empty")
    }

    await test("SettingsModel persists known tags sorted and deduped") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let model = SettingsModel(persister: persister)

        model.mergeKnownTags(["projx", "Red", "projx", "Blue"])
        expectEqual(model.settings.knownTags, ["Blue", "projx", "Red"],
                    "tags sorted and deduped in memory")
        expectEqual(persister.loadSettings().knownTags, ["Blue", "projx", "Red"],
                    "tags persisted")
    }
}
