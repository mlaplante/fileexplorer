import Foundation
import Observation

public struct PaletteItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String

    public init(id: String, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// State for the ⌘G/⌘P/⇧⌘A palette overlay: one mode at a time, fuzzy-ranked
/// results, keyboard selection. Async providers must pass the `presentToken`
/// they captured so results for a closed/reopened palette are dropped.
@MainActor
@Observable
public final class PaletteModel {
    public enum Mode: String, Sendable {
        case folders = "Go to Folder"
        case files = "Find File"
        case commands = "Commands"
    }

    public static let maxResults = 50

    public private(set) var mode: Mode = .folders
    public private(set) var isPresented = false
    public private(set) var presentToken = 0
    /// The pane the palette was opened for; folder/file confirms must target
    /// this pane even if the active pane changes while the palette is open.
    /// Weak: a pane can be closed (tab close / dual-pane collapse) mid-flight.
    public weak var targetPane: PaneState?
    public private(set) var isLoading = false
    public var query = "" {
        didSet { rerank() }
    }
    public private(set) var results: [PaletteItem] = []
    public var selectedIndex = 0

    private var allItems: [PaletteItem] = []
    private var prepared: [FuzzyCandidate] = []

    public init() {}

    public func present(mode: Mode) {
        self.mode = mode
        presentToken += 1
        query = ""
        allItems = []
        results = []
        selectedIndex = 0
        isLoading = true
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
        isLoading = false
        targetPane = nil
    }

    /// Providers pass the token captured at present time; without it (UI
    /// setting synchronous items) the current token is assumed.
    public func setItems(_ items: [PaletteItem], token: Int? = nil) {
        if let token, token != presentToken { return }
        allItems = items
        prepared = items.map { FuzzyCandidate($0.title) }
        isLoading = false
        rerank()
    }

    public func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    public var selection: PaletteItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    private func rerank() {
        guard !query.isEmpty else {
            results = Array(allItems.prefix(Self.maxResults))
            selectedIndex = 0
            return
        }
        let q = Array(query.lowercased())
        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(allItems.count)
        for index in allItems.indices {
            if let score = FuzzyMatcher.score(queryLowercased: q,
                                              candidate: prepared[index]) {
                scored.append((index, score))
            }
        }
        scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        results = scored.prefix(Self.maxResults).map { allItems[$0.index] }
        selectedIndex = 0
    }
}
