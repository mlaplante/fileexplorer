import Foundation
import UniformTypeIdentifiers

public enum TypePreset: String, CaseIterable, Sendable, Codable {
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
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp",
    ]
    private static let imageIdentifiers: Set<String> = [
        "public.jpeg", "public.png", "public.gif", "public.heic", "public.heif",
        "public.tiff", "com.microsoft.bmp",
    ]
    private static let pdfExtensions: Set<String> = ["pdf"]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm",
    ]
    private static let videoIdentifiers: Set<String> = [
        "com.apple.quicktime-movie", "public.mpeg-4", "public.movie", "public.video",
    ]
    private static let documentExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rtf", "pdf", "doc", "docx",
        "pages", "odt", "csv", "xls", "xlsx", "numbers", "ppt", "pptx", "key",
    ]
    private static let documentIdentifiers: Set<String> = [
        "public.text", "public.plain-text", "public.utf8-plain-text",
        "public.rtf", "public.html", "public.xml", "public.json",
        "public.yaml", "public.source-code", "public.comma-separated-values-text",
        "com.apple.property-list",
    ]

    public func matches(_ type: UTType?) -> Bool {
        guard let type else { return false }
        let extensions = Set(type.tags[.filenameExtension]?.map {
            $0.lowercased()
        } ?? [])
        switch self {
        case .images:
            return type.conforms(to: .image)
                || Self.imageIdentifiers.contains(type.identifier)
                || !extensions.isDisjoint(with: Self.imageExtensions)
        case .pdfs:
            return type.conforms(to: .pdf)
                || type.identifier == "com.adobe.pdf"
                || !extensions.isDisjoint(with: Self.pdfExtensions)
        case .videos:
            return type.conforms(to: .movie) || type.conforms(to: .video)
                || Self.videoIdentifiers.contains(type.identifier)
                || !extensions.isDisjoint(with: Self.videoExtensions)
        case .documents:
            return type.conforms(to: .text)
                || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet)
                || Self.wordProcessingIdentifiers.contains(type.identifier)
                || Self.documentIdentifiers.contains(type.identifier)
                || !extensions.isDisjoint(with: Self.documentExtensions)
        }
    }
}

public enum DatePreset: String, CaseIterable, Sendable, Codable {
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

public enum SizePreset: String, CaseIterable, Sendable, Codable {
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
