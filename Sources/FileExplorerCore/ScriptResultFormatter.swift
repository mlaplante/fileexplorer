import Foundation

public enum ScriptOutcome: Equatable, Sendable {
    case finished
    case stillRunning
}

public enum ScriptResultFormatter {
    public struct AlertContent: Equatable, Identifiable, Sendable {
        public let title: String
        public let message: String

        public var id: String { "\(title)\n\(message)" }

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    public static func bannerText(name: String, outcome: ScriptOutcome) -> String {
        switch outcome {
        case .finished:
            return "\(name) finished"
        case .stillRunning:
            return "\(name) still running…"
        }
    }

    public static func alert(name: String, exitCode: Int32,
                             stderr: String) -> AlertContent {
        let trimmed = stderr.trimmingTrailingCharacters(in: .whitespacesAndNewlines)
        return AlertContent(
            title: "\(name) failed (exit \(exitCode))",
            message: trimmed.isEmpty ? "(no error output)" : trimmed)
    }

    public static func truncatedStderr(_ data: Data) -> String {
        let limit = 4096
        if data.count <= limit {
            return String(decoding: data, as: UTF8.self)
        }
        return "…" + String(decoding: data.suffix(limit), as: UTF8.self)
    }

    public static func launchFailureAlert(name: String,
                                          error: any Error) -> AlertContent {
        AlertContent(title: "\(name) could not start",
                     message: String(describing: error))
    }
}

private extension String {
    func trimmingTrailingCharacters(in set: CharacterSet) -> String {
        var result = self
        while let scalar = result.unicodeScalars.last, set.contains(scalar) {
            result.removeLast()
        }
        return result
    }
}
