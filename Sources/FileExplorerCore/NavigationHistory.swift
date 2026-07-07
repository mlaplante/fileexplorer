import Foundation

public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    public init(current: URL) {
        self.current = current
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public mutating func navigate(to url: URL) {
        guard url != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = url
    }

    public mutating func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    public mutating func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }
}
