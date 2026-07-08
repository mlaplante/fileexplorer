import Foundation

/// A customizable key combination: one character key plus modifiers.
/// Special keys (Return, Delete, arrows) are deliberately out of scope —
/// fixed-key commands keep their hardcoded shortcuts.
public struct KeyChord: Codable, Equatable, Hashable, Sendable {
    public var key: String   // single lowercase character
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool, shift: Bool,
                option: Bool, control: Bool) {
        self.key = key.lowercased()
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// macOS HIG glyph order: ⌃ ⌥ ⇧ ⌘.
    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "")
            + (command ? "⌘" : "") + key.uppercased()
    }
}
