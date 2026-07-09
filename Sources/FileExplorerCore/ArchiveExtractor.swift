import Foundation

public enum ArchiveExtractor {
    public static let previewByteCap: Int64 = 512 * 1024 * 1024

    public static func extract(entries: [String], from archive: URL, into destination: URL)
        -> Result<Void, FileOperationService.FileOpError> {
        guard !entries.isEmpty else { return .success(()) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let staging = fm.temporaryDirectory
                .appendingPathComponent("fx-archive-extract-\(UUID().uuidString)",
                                        isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }

            let result = runTarExtract(entries: entries, archive: archive, destination: staging)
            if case .failure(let error) = result {
                return .failure(error)
            }
            let missing = entries.first {
                !fm.fileExists(atPath: staging.appendingPathComponent($0).path)
            }
            if let missing {
                return .failure(.init("Extraction failed: missing “\(missing)” in archive."))
            }
            try moveStagedTopLevelItems(for: entries, from: staging, into: destination)
            return .success(())
        } catch {
            return .failure(.init(error))
        }
    }

    public static func extractForPreview(entry: ArchiveEntry, from archive: URL,
                                         tempRoot: URL)
        -> Result<URL, FileOperationService.FileOpError> {
        guard !entry.isDirectory else {
            return .failure(.init("Folders can't be previewed from an archive."))
        }
        guard entry.size <= previewByteCap else {
            return .failure(.init(
                "“\(entry.name)” is over the 512 MB preview limit. Use Extract Selected instead."))
        }
        let fm = FileManager.default
        let session = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
        } catch {
            return .failure(.init(error))
        }
        let result = runTarExtract(entries: [entry.path], archive: archive, destination: session)
        if case .failure(let error) = result {
            try? fm.removeItem(at: session)
            return .failure(error)
        }
        let extracted = session.appendingPathComponent(entry.path)
        guard fm.fileExists(atPath: extracted.path) else {
            try? fm.removeItem(at: session)
            return .failure(.init("Extraction failed: missing “\(entry.path)” in archive."))
        }
        return .success(extracted)
    }

    private static func runTarExtract(entries: [String], archive: URL, destination: URL)
        -> Result<Void, FileOperationService.FileOpError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", destination.path]
            + entries.flatMap { ["--include", $0] }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.init(error))
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            return .failure(.init("Extraction failed: \(stderr.prefix(200))"))
        }
        return .success(())
    }

    private static func moveStagedTopLevelItems(for entries: [String], from staging: URL,
                                                into destination: URL) throws {
        let fm = FileManager.default
        var existing = Set((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
        var topLevels: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard let top = entry.split(separator: "/").first.map(String.init),
                  !seen.contains(top) else { continue }
            topLevels.append(top)
            seen.insert(top)
        }
        for top in topLevels {
            let source = staging.appendingPathComponent(top)
            guard fm.fileExists(atPath: source.path) else { continue }
            let targetName = CollisionNamer.sequentialName(base: top, existing: existing)
            let target = destination.appendingPathComponent(targetName)
            try fm.moveItem(at: source, to: target)
            existing.insert(targetName)
        }
    }
}
