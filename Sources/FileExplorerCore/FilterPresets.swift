import Foundation
import UniformTypeIdentifiers

public enum TypePreset: String, CaseIterable, Sendable {
    case images = "Images"
    case pdfs = "PDFs"
    case videos = "Videos"
    case documents = "Documents"

    /// Word-processing formats that don't conform to `.text` because they are
    /// zipped/package formats.
    private static let wordProcessingIdentifiers: Set<String> = [
        "com.microsoft.word.doc",
        "org.openxmlformats.wordprocessingml.document",
        "com.apple.iwork.pages.sffpages",
        "org.oasis-open.opendocument.text",
    ]

    public func matches(_ type: UTType?) -> Bool {
        guard let type else { return false }
        switch self {
        case .images:
            return type.conforms(to: .image)
        case .pdfs:
            return type.conforms(to: .pdf)
        case .videos:
            return type.conforms(to: .movie) || type.conforms(to: .video)
        case .documents:
            return type.conforms(to: .text)
                || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet)
                || Self.wordProcessingIdentifiers.contains(type.identifier)
        }
    }
}

public enum DatePreset: String, CaseIterable, Sendable {
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case thisYear = "This Year"

    /// Computed at apply time so "Today" stays correct across reloads.
    public func range(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)...now
        case .last7Days:
            return calendar.date(byAdding: .day, value: -7, to: now)!...now
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: now)!...now
        case .thisYear:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now))!
            return start...now
        }
    }
}

public enum SizePreset: String, CaseIterable, Sendable {
    case under1MB = "Under 1 MB"
    case oneTo100MB = "1–100 MB"
    case over100MB = "Over 100 MB"

    public var range: ClosedRange<Int64> {
        let mb: Int64 = 1_048_576
        switch self {
        case .under1MB: return 0...(mb - 1)
        case .oneTo100MB: return mb...(100 * mb)
        case .over100MB: return (100 * mb + 1)...Int64.max
        }
    }
}
