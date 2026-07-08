import SwiftUI
import AppKit
import FileExplorerCore

@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 1000
    }

    func icon(for entry: FileEntry) -> NSImage {
        let key = entry.url.standardizedFileURL.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct FileEntryLabel: View {
    let entry: FileEntry
    var showsTags = true
    var symlinkSymbol = "arrow.triangle.turn.up.right.circle"

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIconCache.shared.icon(for: entry))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
            if entry.isSymlink {
                Image(systemName: symlinkSymbol)
                    .foregroundStyle(.secondary)
                    .help("Symbolic link")
            }
            if showsTags, !entry.tags.isEmpty {
                TagDotsView(tags: entry.tags)
            }
        }
    }
}
