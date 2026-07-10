import Foundation

@MainActor
public final class SpringLoadModel {
    public var onSpring: (@MainActor (URL) -> Void)?

    private let delay: Duration
    private let sleeper: @MainActor (Duration) async -> Void
    private var pending: Task<Void, Never>?
    private var currentFolder: URL?

    /// `sleeper` exists so tests can control the timer deterministically
    /// instead of racing the wall clock.
    public init(delay: Duration = .milliseconds(700),
                onSpring: (@MainActor (URL) -> Void)? = nil,
                sleeper: @escaping @MainActor (Duration) async -> Void
                    = { try? await Task.sleep(for: $0) }) {
        self.delay = delay
        self.onSpring = onSpring
        self.sleeper = sleeper
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
            await sleeper(delay)
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
