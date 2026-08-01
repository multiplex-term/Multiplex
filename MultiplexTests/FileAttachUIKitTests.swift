import PhotosUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Multiplex

@MainActor
final class FileAttachUIKitTests: XCTestCase {
    func testEligibilityRequiresSSHTmuxSession() {
        let sshTmux = makeController(useMosh: false, mode: .attach(sessionName: "main"))
        let moshTmux = makeController(useMosh: true, mode: .attach(sessionName: "main"))
        let plainShell = makeController(useMosh: false, mode: .shell)

        XCTAssertTrue(FileAttachAvailability.canOffer(for: sshTmux))
        XCTAssertFalse(FileAttachAvailability.canOffer(for: moshTmux))
        XCTAssertFalse(FileAttachAvailability.canOffer(for: plainShell))
        XCTAssertFalse(FileAttachAvailability.canOffer(for: nil))
    }

    func testNativeBadgePreservesTallyGeometryAndAccessibility() {
        let button = FileAttachBadgeButton()

        XCTAssertEqual(button.accessibilityLabel, "Send a file to this session")
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertEqual(button.layer.borderWidth, 1)
        XCTAssertEqual(FileAttachBadgeButton.horizontalInset, 9)
        XCTAssertEqual(FileAttachBadgeButton.verticalInset, 5)
        XCTAssertEqual(FileAttachBadgeButton.contentSpacing, 5)
        XCTAssertGreaterThan(
            button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width,
            0
        )
        XCTAssertEqual(
            button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize),
            button.intrinsicContentSize
        )
        XCTAssertLessThan(button.intrinsicContentSize.height, 34)
    }

    func testNativeDirectMenuIsVisibleButDisabledUntilSessionIsLive() {
        let terminal = makeController(useMosh: false, mode: .attach(sessionName: "main"))
        let controller = FileAttachMenuViewController(controller: terminal)
        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.attachButton.isHidden)
        XCTAssertFalse(controller.attachButton.isEnabled)
        let titles = menuTitles(controller.attachButton.menu)
        #if !os(visionOS)
        XCTAssertEqual(titles, ["Camera…", "Photo Library…", "Files…"])
        #else
        XCTAssertEqual(titles, ["Photo Library…", "Files…"])
        #endif

        controller.update(controller: makeController(useMosh: true, mode: .attach(sessionName: "main")))
        XCTAssertTrue(controller.attachButton.isHidden)
        XCTAssertNil(controller.attachButton.menu)
    }

    func testMovingBadgeDoesNotMovePresenterRootOutOfContainment() throws {
        let terminal = makeController(useMosh: false, mode: .attach(sessionName: "main"))
        let parent = UIViewController()
        let controller = FileAttachMenuViewController(controller: terminal)
        parent.loadViewIfNeeded()
        parent.addChild(controller)
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)

        let presenterRoot = try XCTUnwrap(controller.view)
        let badge = controller.takeAttachButton()
        let navigationChrome = UIView()
        navigationChrome.addSubview(badge)

        XCTAssertTrue(controller.parent === parent)
        XCTAssertTrue(controller.view === presenterRoot)
        XCTAssertTrue(presenterRoot.superview === parent.view)
        XCTAssertTrue(badge.superview === navigationChrome)

        controller.parkAttachButton()
        XCTAssertTrue(badge.superview === presenterRoot)
        XCTAssertTrue(controller.parent === parent)
    }

    func testPresenterBuildsMultipleFileAndOrderedPhotoPickers() {
        let controller = FileAttachPickerPresenterViewController()

        let files = controller.makePicker(for: .files) as? UIDocumentPickerViewController
        XCTAssertTrue(files?.allowsMultipleSelection == true)

        let photos = controller.makePicker(for: .photoLibrary) as? PHPickerViewController
        XCTAssertEqual(photos?.configuration.selectionLimit, 0)
        XCTAssertEqual(photos?.configuration.selection, .ordered)
    }

    func testExternalRequestLatchQueuesOnlyOnceUntilBindingClears() {
        let terminal = makeController(useMosh: false, mode: .attach(sessionName: "main"))
        let controller = FileAttachPickerPresenterViewController()

        controller.consumeExternalRequest(.files, target: terminal)
        XCTAssertEqual(controller.queuedPicker, .files)
        XCTAssertTrue(controller.queuedTarget === terminal)

        controller.consumeExternalRequest(.photoLibrary, target: terminal)
        XCTAssertEqual(controller.queuedPicker, .files)

        controller.consumeExternalRequest(nil, target: terminal)
        controller.consumeExternalRequest(.photoLibrary, target: terminal)
        XCTAssertEqual(controller.queuedPicker, .photoLibrary)
    }

    private func makeController(
        useMosh: Bool,
        mode: TerminalRoute.Mode
    ) -> TerminalSessionController {
        var host = Host(
            name: "devbox",
            hostname: "127.0.0.1",
            username: "dev"
        )
        host.useMosh = useMosh
        return TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: mode),
            host: host
        )
    }

    private func menuTitles(_ menu: UIMenu?) -> [String] {
        menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }
}
