import Foundation
import CryptoKit

/// Streaming SHA-256 (1 MiB chunks) so multi-GB files never load into
/// memory. Blocking — call off the main actor.
public enum FileHasher {
    public static func sha256(of url: URL)
        -> Result<String, FileOperationService.FileOpError> {
        sha256(of: url, firstBytes: .max)
    }

    /// Hash of at most the first `limit` bytes. The duplicate scanner uses a
    /// small prefix as a cheap prefilter before committing to full hashes.
    public static func sha256(of url: URL, firstBytes limit: Int)
        -> Result<String, FileOperationService.FileOpError> {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.init("Can't read “\(url.lastPathComponent)”."))
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit
        while remaining > 0 {
            // Explicit do/catch: a thrown read is an error, while a nil or
            // empty chunk is EOF — `try?` would collapse the two.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(remaining, 1_048_576))
            } catch {
                return .failure(.init("Read failed for “\(url.lastPathComponent)”."))
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
