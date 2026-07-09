import Foundation
import FileExplorerCore

@MainActor
func shortcutTests() async {
    await test("KeyChord displays macOS-style modifier glyph order") {
        let chord = KeyChord(key: "k", command: true, shift: true,
                             option: false, control: false)
        expectEqual(chord.display, "⇧⌘K", "shift-command-K")
        let full = KeyChord(key: "x", command: true, shift: true,
                            option: true, control: true)
        expectEqual(full.display, "⌃⌥⇧⌘X", "canonical glyph order")
    }

    await test("KeyChord round-trips through Codable") {
        let chord = KeyChord(key: "d", command: true, shift: false,
                             option: true, control: false)
        let data = try JSONEncoder().encode(chord)
        expectEqual(try JSONDecoder().decode(KeyChord.self, from: data), chord,
                    "round-trip")
    }

    await test("registry resolves defaults and overrides") {
        let defaults = ShortcutRegistry.defaultChord(for: .duplicate)
        expectEqual(defaults, KeyChord(key: "d", command: true, shift: false,
                                       option: false, control: false),
                    "⌘D default")
        let override = KeyChord(key: "j", command: true, shift: true,
                                option: false, control: false)
        let effective = ShortcutRegistry.effectiveChord(
            for: .duplicate, overrides: [ShortcutRegistry.Command.duplicate.rawValue: override])
        expectEqual(effective, override, "override wins")
        expectEqual(ShortcutRegistry.effectiveChord(for: .newFile, overrides: [:]),
                    ShortcutRegistry.defaultChord(for: .newFile), "no override → default")
        expectEqual(ShortcutRegistry.defaultChord(for: .previewPane),
                    KeyChord(key: "p", command: true, shift: false,
                             option: true, control: false),
                    "⌥⌘P default")
        expectEqual(ShortcutRegistry.defaultChord(for: .openInTerminal),
                    KeyChord(key: "t", command: true, shift: false,
                             option: false, control: true),
                    "⌃⌘T default")
        expectEqual(ShortcutRegistry.defaultChord(for: .openInEditor),
                    KeyChord(key: "e", command: true, shift: false,
                             option: false, control: true),
                    "⌃⌘E default")
        expectEqual(ShortcutRegistry.Command.openInTerminal.displayName,
                    "Open in Terminal",
                    "terminal command display name")
        expectEqual(ShortcutRegistry.Command.openInEditor.displayName,
                    "Open in Editor",
                    "editor command display name")
    }

    await test("conflict detection flags duplicate effective chords") {
        let clash = ShortcutRegistry.defaultChord(for: .newFile) // ⌥⌘N
        let overrides = [ShortcutRegistry.Command.duplicate.rawValue: clash]
        let conflicts = ShortcutRegistry.conflicts(overrides: overrides)
        expect(conflicts.contains { $0.contains(.duplicate) && $0.contains(.newFile) },
               "duplicate vs newFile clash detected")
        expect(ShortcutRegistry.conflicts(overrides: [:]).isEmpty,
               "defaults are conflict-free")
    }

    await test("AppSettings persists shortcut overrides forward-compatibly") {
        let old = #"{"jpegQuality":0.9}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        expect(decoded.shortcutOverrides.isEmpty, "missing key → empty")
        var settings = AppSettings()
        settings.shortcutOverrides = ["duplicate": KeyChord(
            key: "j", command: true, shift: false, option: false, control: false)]
        let data = try JSONEncoder().encode(settings)
        let round = try JSONDecoder().decode(AppSettings.self, from: data)
        expectEqual(round.shortcutOverrides, settings.shortcutOverrides, "round-trip")
    }
}
