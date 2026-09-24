/// Framework-neutral scene presentation intents. SwiftUI and UIKit roots
/// install a value per scene, while feature code asks for a semantic result
/// without knowing which scene API performs it.
struct SceneWindowRouting {
    enum Intent: Equatable {
        /// The deck always carries its one stable route. Dispatching `.main`
        /// activates the existing deck when it is alive instead of creating
        /// another fleet wall.
        case openDeck(DeckWindowRoute)
        case openTerminal(TerminalWindowRoute)
        /// Close the scene that owns this routing value. This deliberately
        /// has no persisted route argument: a terminal binding can be newer
        /// than the scene system's last committed value.
        case closeCurrentScene
    }

    let supportsMultipleWindows: Bool
    private let performIntent: (Intent) -> Void

    init(
        supportsMultipleWindows: Bool,
        perform: @escaping (Intent) -> Void
    ) {
        self.supportsMultipleWindows = supportsMultipleWindows
        performIntent = perform
    }

    func openDeck() {
        performIntent(.openDeck(.main))
    }

    func openTerminal(_ route: TerminalWindowRoute) {
        performIntent(.openTerminal(route))
    }

    func closeCurrentScene() {
        performIntent(.closeCurrentScene)
    }
}
