import Foundation

@MainActor
public final class SpringLoadModel {
    public var onSpring: (@MainActor (URL) -> Void)?

    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var currentFolder: URL?

    public init(delay: Duration = .milliseconds(700),
                onSpring: (@MainActor (URL) -> Void)? = nil) {
        self.delay = delay
        self.onSpring = onSpring
    }

    deinit {
        pending?.cancel()
    }

    public func beginHover(folder: URL) {
        let standardized = folder.standardizedFileURL
        guard currentFolder != standardized else { return }
        pending?.cancel()
        currentFolder = standardized
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, currentFolder == standardized else { return }
            onSpring?(standardized)
            endHover()
        }
    }

    public func endHover() {
        pending?.cancel()
        pending = nil
        currentFolder = nil
    }
}
