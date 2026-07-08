import Foundation

public enum OperationFailureSummary {
    public static func message(_ failures: [String], limit: Int = 3) -> String? {
        guard !failures.isEmpty else { return nil }
        let details = failures.prefix(limit).joined(separator: " ")
        let remaining = failures.count - limit
        return remaining > 0 ? details + " (+\(remaining) more)" : details
    }
}
