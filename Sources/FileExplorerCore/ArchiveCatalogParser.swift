import Foundation

public struct ArchiveEntry: Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public init(path: String, name: String, isDirectory: Bool,
                size: Int64, modified: Date?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public struct ParsedCatalog: Equatable, Sendable {
    public let entries: [ArchiveEntry]
    public let hadSuspiciousPaths: Bool
    public let isPartial: Bool

    public init(entries: [ArchiveEntry], hadSuspiciousPaths: Bool,
                isPartial: Bool) {
        self.entries = entries
        self.hadSuspiciousPaths = hadSuspiciousPaths
        self.isPartial = isPartial
    }
}

public enum ArchiveCatalogParser {
    public static let entryCap = 100_000

    public static func parse(listing: String, cap: Int = entryCap,
                             referenceDate: Date = Date()) -> ParsedCatalog {
        var entries: [ArchiveEntry] = []
        var paths = Set<String>()
        var hadSuspiciousPaths = false
        var isPartial = false

        for line in listing.split(whereSeparator: \.isNewline) {
            guard entries.count < cap else {
                isPartial = true
                break
            }
            guard let parsed = parseLine(String(line), referenceDate: referenceDate) else {
                continue
            }
            if parsed.shouldSkipEntry {
                continue
            }
            switch normalize(parsed.path) {
            case .path(let normalized):
                if !paths.contains(normalized) {
                    entries.append(ArchiveEntry(
                        path: normalized,
                        name: lastComponent(normalized),
                        isDirectory: parsed.isDirectory,
                        size: parsed.isDirectory ? 0 : parsed.size,
                        modified: parsed.modified))
                    paths.insert(normalized)
                }
                addImplicitParents(for: normalized, entries: &entries,
                                   paths: &paths, cap: cap, isPartial: &isPartial)
                if isPartial {
                    break
                }
            case .skip:
                continue
            case .suspicious:
                hadSuspiciousPaths = true
                continue
            }
        }

        return ParsedCatalog(entries: entries,
                             hadSuspiciousPaths: hadSuspiciousPaths,
                             isPartial: isPartial)
    }

    private struct ParsedLine {
        var path: String
        var isDirectory: Bool
        var shouldSkipEntry: Bool
        var size: Int64
        var modified: Date?
    }

    private static func parseLine(_ line: String, referenceDate: Date) -> ParsedLine? {
        let pattern = #"^(\S+)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}:\d{2}|\d{4})\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 7 else {
            return nil
        }

        func group(_ index: Int) -> String {
            String(line[Range(match.range(at: index), in: line)!])
        }

        let mode = group(1)
        let rawPath = group(6)
        let directory = mode.first == "d" || rawPath.hasSuffix("/")
        let skipEntry = mode.first == "l" || mode.first == "h"
        return ParsedLine(path: rawPath,
                          isDirectory: directory,
                          shouldSkipEntry: skipEntry,
                          size: Int64(group(2)) ?? 0,
                          modified: parseDate(month: group(3), day: group(4),
                                              timeOrYear: group(5),
                                              referenceDate: referenceDate))
    }

    private static func parseDate(month: String, day: String, timeOrYear: String,
                                  referenceDate: Date) -> Date? {
        let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                      "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
        guard let monthNumber = months[month], let dayNumber = Int(day) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.timeZone = calendar.timeZone
        components.month = monthNumber
        components.day = dayNumber
        if timeOrYear.contains(":") {
            let referenceYear = calendar.component(.year, from: referenceDate)
            let parts = timeOrYear.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]) else {
                return nil
            }
            components.year = referenceYear
            components.hour = hour
            components.minute = minute
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            components.year = year
        }
        return calendar.date(from: components)
    }

    private enum NormalizedPath {
        case path(String)
        case skip
        case suspicious
    }

    private static func normalize(_ rawPath: String) -> NormalizedPath {
        var path = rawPath
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty || path == "." {
            return .skip
        }
        guard !path.hasPrefix("/") else { return .suspicious }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return .suspicious
        }
        return .path(path)
    }

    private static func addImplicitParents(for path: String,
                                           entries: inout [ArchiveEntry],
                                           paths: inout Set<String>,
                                           cap: Int,
                                           isPartial: inout Bool) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? component : current + "/" + component
            guard !paths.contains(current) else { continue }
            guard entries.count < cap else {
                isPartial = true
                return
            }
            entries.append(ArchiveEntry(path: current, name: component,
                                        isDirectory: true, size: 0,
                                        modified: nil))
            paths.insert(current)
        }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
