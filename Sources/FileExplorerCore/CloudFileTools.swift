import Foundation

public enum CloudFileState: Equatable, Sendable {
    case notCloud
    case downloaded
    case evicted
    case downloading
    case conflicted
    case unknown
}

public struct CloudFileResourceValues: Equatable, Sendable {
    public var isUbiquitous: Bool
    public var isDownloaded: Bool?
    public var isDownloading: Bool?
    public var hasUnresolvedConflicts: Bool

    public init(isUbiquitous: Bool, isDownloaded: Bool? = nil,
                isDownloading: Bool? = nil,
                hasUnresolvedConflicts: Bool = false) {
        self.isUbiquitous = isUbiquitous
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
    }
}

public enum CloudFileTools {
    public static func state(from values: CloudFileResourceValues) -> CloudFileState {
        guard values.isUbiquitous else { return .notCloud }
        if values.hasUnresolvedConflicts { return .conflicted }
        if values.isDownloading == true { return .downloading }
        if values.isDownloaded == true { return .downloaded }
        if values.isDownloaded == false { return .evicted }
        return .unknown
    }

    public static func state(for url: URL) -> CloudFileState {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return .notCloud }
        let downloaded = values.ubiquitousItemDownloadingStatus == .current
            || values.ubiquitousItemDownloadingStatus == .downloaded
        return state(from: CloudFileResourceValues(
            isUbiquitous: true,
            isDownloaded: downloaded,
            isDownloading: values.ubiquitousItemIsDownloading,
            hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts ?? false))
    }

    public static func startDownload(_ url: URL) -> Result<Void, FileOperationService.FileOpError> {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            return .success(())
        } catch {
            return .failure(.init(error))
        }
    }

    public static func evictLocalCopy(_ url: URL) -> Result<Void, FileOperationService.FileOpError> {
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
            return .success(())
        } catch {
            return .failure(.init(error))
        }
    }
}
