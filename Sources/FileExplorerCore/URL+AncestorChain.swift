import Foundation

public extension URL {
    /// The standardized URL and all its ancestors, root first, e.g.
    /// [/, /Users, /Users/me] for /Users/me.
    ///
    /// Clamps explicitly at "/" — `deletingLastPathComponent()` is lexical and
    /// yields "/.." at the root, which once caused an unbounded loop here.
    var ancestorChain: [URL] {
        var urls: [URL] = []
        var url = standardizedFileURL
        while true {
            urls.append(url)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return urls.reversed()
    }
}
