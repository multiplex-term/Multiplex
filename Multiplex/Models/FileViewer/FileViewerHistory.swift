import Foundation

/// Back/forward browse history for one file-viewer tab — the browser model:
/// a linear trail of the content screens the person navigated to, cut at the
/// point they branch from. Pure on purpose: the controller records visits
/// when content actually lands (a failed load never becomes a place to go
/// "back" to), and quiet watch swaps re-render the current entry, which
/// `visit`'s equality gate ignores.
struct FileViewerHistory: Equatable {
    /// A place the content screen can return to. Directory moves live in
    /// the tree, not here — history is about what the screen showed.
    enum Entry: Equatable {
        case document(path: String)
        case fileDiff(path: String)
        case repoDiff
    }

    /// Runaway bound, not a feature: nobody walks back through hundreds of
    /// files, but a long-lived tab must not grow without limit.
    static let capacity = 100

    private(set) var backStack: [Entry] = []
    private(set) var forwardStack: [Entry] = []
    private(set) var current: Entry?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// A navigation the person made (or a re-render of where they already
    /// are — the equality gate makes refresh and watch swaps free). A new
    /// destination drops the forward trail, the browser contract.
    mutating func visit(_ entry: Entry) {
        guard entry != current else { return }
        if let current { backStack.append(current) }
        if backStack.count > Self.capacity {
            backStack.removeFirst(backStack.count - Self.capacity)
        }
        forwardStack = []
        current = entry
    }

    /// Steps the trail and returns where to navigate; the caller performs
    /// the navigation, whose landing `visit` then no-ops against `current`.
    mutating func goBack() -> Entry? {
        guard let destination = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = destination
        return destination
    }

    mutating func goForward() -> Entry? {
        guard let destination = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = destination
        return destination
    }
}
