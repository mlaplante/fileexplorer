import Foundation
import Observation

@MainActor
@Observable
public final class ArchiveBrowserModel {
    public typealias ListingRunner =
        @Sendable (URL) async -> Result<String, FileOperationService.FileOpError>

    public private(set) var archiveURL: URL?
    public private(set) var catalog: ArchiveCatalog?
    public private(set) var currentPath = ""
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var isPresented = false

    @ObservationIgnored private let runner: ListingRunner
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tempRootURL: URL?

    public init(runner: @escaping ListingRunner = ArchiveBrowserModel.defaultRunner) {
        self.runner = runner
    }

    public func open(archive: URL) {
        generation += 1
        let myGeneration = generation
        pending?.cancel()
        cleanupTempRoot()
        archiveURL = archive
        catalog = nil
        currentPath = ""
        errorMessage = nil
        isPresented = false
        isLoading = true

        pending = Task { [runner, archive] in
            let result = await runner(archive)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let listing):
                let parsed = ArchiveCatalogParser.parse(listing: listing,
                                                        referenceDate: Date())
                let loaded = ArchiveCatalog(parsed: parsed)
                guard myGeneration == generation else { return }
                catalog = loaded
                isLoading = false
                isPresented = true
            case .failure(let error):
                guard myGeneration == generation else { return }
                catalog = nil
                errorMessage = error.message
                isLoading = false
                isPresented = false
            }
        }
    }

    public func navigate(into path: String) {
        if path.isEmpty {
            currentPath = ""
            return
        }
        guard catalog?.entry(at: path)?.isDirectory == true else { return }
        currentPath = path
    }

    public func navigateUp() {
        guard !currentPath.isEmpty else { return }
        if let slash = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[..<slash])
        } else {
            currentPath = ""
        }
    }

    public func close() {
        generation += 1
        pending?.cancel()
        pending = nil
        cleanupTempRoot()
        archiveURL = nil
        catalog = nil
        currentPath = ""
        isLoading = false
        errorMessage = nil
        isPresented = false
    }

    public func clearError() {
        errorMessage = nil
    }

    public func previewTempRoot() -> URL {
        if let tempRootURL { return tempRootURL }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FileExplorer-ArchivePreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRootURL = root
        return root
    }

    private func cleanupTempRoot() {
        if let tempRootURL {
            try? FileManager.default.removeItem(at: tempRootURL)
        }
        tempRootURL = nil
    }

    public static let defaultRunner: ListingRunner = { archive in
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-tvf", archive.path]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: errorData, encoding: .utf8) ?? ""
                    return .failure(.init("Archive listing failed: \(text.prefix(200))"))
                }
                let listing = String(data: output, encoding: .utf8) ?? ""
                return .success(listing)
            } catch {
                return .failure(.init(error))
            }
        }.value
    }
}
