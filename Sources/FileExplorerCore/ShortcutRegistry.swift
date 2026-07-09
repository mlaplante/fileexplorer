import Foundation

/// The customizable command set and its default chords. Effective chord =
/// override if present, else default. Pure.
public enum ShortcutRegistry {
    public enum Command: String, CaseIterable, Sendable {
        case newFile, duplicate, newFolder, comparePanes, dualPane,
             toggleHidden, goHome, gotoFolder, findFile, contentSearch,
             commandPalette, quickLook, getInfo, previewPane,
             openInTerminal, openInEditor

        public var displayName: String {
            switch self {
            case .newFile: "New File"
            case .duplicate: "Duplicate"
            case .newFolder: "New Folder"
            case .comparePanes: "Compare Panes"
            case .dualPane: "Toggle Dual Pane"
            case .toggleHidden: "Toggle Hidden Files"
            case .goHome: "Go Home"
            case .gotoFolder: "Go to Folder…"
            case .findFile: "Find File…"
            case .contentSearch: "Search File Contents…"
            case .commandPalette: "Command Palette…"
            case .quickLook: "Quick Look"
            case .getInfo: "Get Info"
            case .previewPane: "Preview Pane"
            case .openInTerminal: "Open in Terminal"
            case .openInEditor: "Open in Editor"
            }
        }
    }

    private static let defaults: [Command: KeyChord] = [
        .newFile: KeyChord(key: "n", command: true, shift: false, option: true, control: false),
        .duplicate: KeyChord(key: "d", command: true, shift: false, option: false, control: false),
        .newFolder: KeyChord(key: "n", command: true, shift: true, option: false, control: false),
        .comparePanes: KeyChord(key: "k", command: true, shift: true, option: false, control: false),
        .dualPane: KeyChord(key: "d", command: true, shift: true, option: false, control: false),
        .toggleHidden: KeyChord(key: ".", command: true, shift: true, option: false, control: false),
        .goHome: KeyChord(key: "h", command: true, shift: true, option: false, control: false),
        .gotoFolder: KeyChord(key: "g", command: true, shift: false, option: false, control: false),
        .findFile: KeyChord(key: "p", command: true, shift: false, option: false, control: false),
        .contentSearch: KeyChord(key: "f", command: true, shift: true, option: false, control: false),
        .commandPalette: KeyChord(key: "a", command: true, shift: true, option: false, control: false),
        .quickLook: KeyChord(key: "y", command: true, shift: false, option: false, control: false),
        .getInfo: KeyChord(key: "i", command: true, shift: false, option: false, control: false),
        .previewPane: KeyChord(key: "p", command: true, shift: false, option: true, control: false),
        .openInTerminal: KeyChord(key: "t", command: true, shift: false, option: false, control: true),
        .openInEditor: KeyChord(key: "e", command: true, shift: false, option: false, control: true),
    ]

    public static func defaultChord(for command: Command) -> KeyChord {
        defaults[command]!
    }

    public static func effectiveChord(for command: Command,
                                      overrides: [String: KeyChord]) -> KeyChord {
        overrides[command.rawValue] ?? defaultChord(for: command)
    }

    /// Groups of commands whose EFFECTIVE chords collide.
    public static func conflicts(overrides: [String: KeyChord]) -> [[Command]] {
        var byChord: [KeyChord: [Command]] = [:]
        for command in Command.allCases {
            byChord[effectiveChord(for: command, overrides: overrides),
                    default: []].append(command)
        }
        return byChord.values.filter { $0.count > 1 }.map { $0 }
    }
}
