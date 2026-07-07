import Foundation

/// Watches one directory via a kqueue DispatchSource and invokes the callback
/// on the main actor after a 200 ms debounce. Re-calling `watch` replaces the
/// previous watch.
/// Watching a path that can't be opened is a silent no-op by design —
/// the caller's reload path surfaces unreadable directories to the user.
@MainActor
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init() {}

    public func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main)

        // The source is bound to the main queue, so the handler really does run
        // on the main actor even though DispatchSource can't express that.
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending?.cancel()
                let work = DispatchWorkItem {
                    MainActor.assumeIsolated { onChange() }
                }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    isolated deinit {
        stop()
    }
}
