import Foundation

/// Finder-parity drop semantics: ⌥ forces copy; otherwise a same-volume
/// drop moves and a cross-volume drop copies. Unknown volume identity
/// degrades to `false` → copy, the non-destructive default.
public enum DropDecision: Equatable, Sendable {
    case move
    case copy

    public static func decide(optionDown: Bool, sameVolume: Bool) -> DropDecision {
        if optionDown { return .copy }
        return sameVolume ? .move : .copy
    }

    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let idA = try? a.resourceValues(forKeys: [.volumeIdentifierKey])
                  .volumeIdentifier,
              let idB = try? b.resourceValues(forKeys: [.volumeIdentifierKey])
                  .volumeIdentifier else { return false }
        return idA.isEqual(idB)
    }
}
