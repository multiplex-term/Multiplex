import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class ExternalActionUIKitCoordinatorTests: XCTestCase {
    func testClassicPresentationRaisesDeckBeforeShowingFailure() {
        var intents: [SceneWindowRouting.Intent] = []
        let harness = makeHarness(
            destination: .window,
            sceneWindows: SceneWindowRouting(
                supportsMultipleWindows: true,
                perform: { intents.append($0) }
            )
        )
        harness.window.makeKeyAndVisible()

        harness.coordinator.receiveFailure(ExternalActionFailure(
            hostName: "devbox",
            message: "Offline"
        ))

        XCTAssertEqual(intents, [.openDeck(.main)])
    }

    func testShellPresentationNeverRaisesAnotherScene() async {
        var intents: [SceneWindowRouting.Intent] = []
        let harness = makeHarness(
            destination: .shell,
            sceneWindows: SceneWindowRouting(
                supportsMultipleWindows: true,
                perform: { intents.append($0) }
            )
        )
        harness.window.makeKeyAndVisible()

        harness.coordinator.receiveFailure(ExternalActionFailure(
            hostName: "devbox",
            message: "Offline"
        ))
        await presentationTurn()

        XCTAssertTrue(intents.isEmpty)
    }

    func testAttachAndDetachOwnExactlyOneRouterContext() {
        let harness = makeHarness(destination: .shell)
        XCTAssertFalse(harness.router.hasContext)

        harness.coordinator.attach()
        XCTAssertTrue(harness.router.hasContext)
        harness.coordinator.attach()
        XCTAssertTrue(harness.router.hasContext)

        harness.coordinator.detach()
        XCTAssertFalse(harness.router.hasContext)
    }

    private struct Harness {
        let window: UIWindow
        let presenter: UIViewController
        let router: ExternalActionRouter
        let coordinator: ExternalActionUIKitCoordinator
    }

    private func makeHarness(
        destination: TerminalRouteOpener.Destination,
        sceneWindows: SceneWindowRouting = SceneWindowRouting(
            supportsMultipleWindows: false,
            perform: { _ in }
        )
    ) -> Harness {
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        window.rootViewController = presenter
        presenter.loadViewIfNeeded()
        let router = ExternalActionRouter()
        let coordinator = ExternalActionUIKitCoordinator(
            presenter: presenter,
            store: HostStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            ),
            hub: ConnectionHub(),
            workspace: TerminalWorkspace(),
            router: router,
            themes: ThemeStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            ),
            terminalOpener: TerminalRouteOpener(
                destination: destination,
                action: { _ in }
            ),
            sceneWindows: sceneWindows
        )
        return Harness(
            window: window,
            presenter: presenter,
            router: router,
            coordinator: coordinator
        )
    }

    private func presentationTurn() async {
        await Task.yield()
        await Task.yield()
    }
}
