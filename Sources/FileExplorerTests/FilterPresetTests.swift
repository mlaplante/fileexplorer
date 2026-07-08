import Foundation
import FileExplorerCore

@MainActor
func filterPresetTests() async {
    func makePersister() throws -> SessionPersister {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionPersister(directory: dir)
    }

    await test("AppSettings without filterPresets key still decodes") {
        let old = #"{"jpegQuality":0.9}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        expectEqual(decoded.jpegQuality, 0.9, "old field intact")
        expect(decoded.filterPresets.isEmpty, "missing key → empty list")
    }

    await test("filter presets round-trip through the persister") {
        let persister = try makePersister()
        defer { try? FileManager.default.removeItem(at: persister.directory) }
        var filter = FilterState()
        filter.preset = .images
        filter.tags = ["Work"]
        var settings = AppSettings()
        settings.filterPresets = [FilterPreset(name: "Work Images", filter: filter)]
        persister.saveSettings(settings)
        let loaded = persister.loadSettings()
        expectEqual(loaded.filterPresets, settings.filterPresets, "round-trip")
    }

    await test("SettingsModel saves, replaces, and deletes presets") {
        let persister = try makePersister()
        defer { try? FileManager.default.removeItem(at: persister.directory) }
        let model = SettingsModel(persister: persister)

        var imagesFilter = FilterState()
        imagesFilter.preset = .images
        model.savePreset(name: "Pics", filter: imagesFilter)
        expectEqual(model.settings.filterPresets.map(\.name), ["Pics"], "saved")

        var pdfFilter = FilterState()
        pdfFilter.preset = .pdfs
        model.savePreset(name: "Pics", filter: pdfFilter)
        expectEqual(model.settings.filterPresets.count, 1, "same name replaces")
        expectEqual(model.settings.filterPresets.first?.filter.preset, .pdfs,
                    "replacement took")

        // Persisted immediately (house rule: settings are tiny, save on write).
        let reloaded = SettingsModel(persister: persister)
        expectEqual(reloaded.settings.filterPresets.map(\.name), ["Pics"],
                    "persisted across model instances")

        model.deletePreset(name: "Pics")
        expect(model.settings.filterPresets.isEmpty, "deleted")
    }
}
