import XCTest
import UIKit
@testable import Multiplex

@MainActor
final class TerminalConfirmationUIKitTests: XCTestCase {
    func testLinkSheetEditsRetainTitleEditorAndActionControlIdentity() throws {
        let initial = try XCTUnwrap(TerminalLink.resolve("https://example.com/docs"))
        let controller = TerminalLinkSheetViewController(
            link: initial,
            viewportOffer: { link in
                link.openableURL.map {
                    ViewportOffer(url: $0, reach: .internet, viaHostName: nil)
                }
            },
            onOpen: { _ in },
            onCopy: { _ in },
            onOpenViewport: { _ in }
        )
        controller.loadViewIfNeeded()

        let editor = try XCTUnwrap(
            descendants(of: UITextView.self, in: controller.view).first
        )
        let viewport = try XCTUnwrap(chip(label: "⌗ Viewport", in: controller.view))
        let open = try XCTUnwrap(chip(label: "Open", in: controller.view))
        let copy = try XCTUnwrap(chip(label: "Copy", in: controller.view))
        #if os(visionOS)
        let titleView = try XCTUnwrap(controller.navigationItem.titleView)
        #endif

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.title, "Cancel")
        XCTAssertTrue(viewport.isProminent)
        XCTAssertFalse(open.isProminent)
        XCTAssertFalse(copy.isProminent)

        controller.setEditedText("not an address")
        XCTAssertEqual(controller.title, "Can't open link")
        XCTAssertTrue(open.isHidden)
        XCTAssertTrue(viewport.isHidden)
        XCTAssertFalse(copy.isHidden)

        controller.setEditedText("https://docs.example/new")
        XCTAssertEqual(controller.title, "Open link")
        XCTAssertTrue(
            descendants(of: UITextView.self, in: controller.view).first === editor
        )
        XCTAssertTrue(chip(label: "⌗ Viewport", in: controller.view) === viewport)
        XCTAssertTrue(chip(label: "Open", in: controller.view) === open)
        XCTAssertTrue(chip(label: "Copy", in: controller.view) === copy)
        XCTAssertFalse(open.isProminent)
        #if os(visionOS)
        XCTAssertTrue(controller.navigationItem.titleView === titleView)
        #endif
    }

    func testHyphenatedTargetExpandsBeforeItsFirstPresentation() throws {
        let raw = "https://example-with-a-very-long-hyphenated-host-name.example.com/"
            + "some-long-hyphenated-path-that-keeps-going-until-it-wraps"
        let initial = try XCTUnwrap(TerminalLink.resolve(raw))
        let controller = TerminalLinkSheetViewController(
            link: initial,
            onOpen: { _ in },
            onCopy: { _ in }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let editor = try XCTUnwrap(
            descendants(of: UIKitTerminalEditableValueBox.self, in: controller.view).first
        )
        let textView = editor.textView
        let lineHeight = ceil(try XCTUnwrap(textView.font).lineHeight)
        let requiredHeight = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height

        XCTAssertEqual(textView.text, raw, "Layout must never mutate the parsed target")
        XCTAssertGreaterThan(requiredHeight, lineHeight * 2)
        XCTAssertGreaterThan(
            textView.bounds.height,
            lineHeight * 2,
            "The TARGET field must expose the lines UIKit wraps after hyphens"
        )
        XCTAssertEqual(textView.bounds.height, ceil(requiredHeight), accuracy: 1)
        XCTAssertFalse(textView.isScrollEnabled, "A target under five lines must not clip or scroll")
    }

    func testLinkSheetRevalidatesEditedTargetBeforeOpen() throws {
        let initial = try XCTUnwrap(TerminalLink.resolve("https://example.com/old"))
        var opened: TerminalLink?
        var dismissCount = 0
        let controller = TerminalLinkSheetViewController(
            link: initial,
            onOpen: { opened = $0 },
            onCopy: { _ in }
        )
        controller.onDismiss = { dismissCount += 1 }
        controller.loadViewIfNeeded()

        controller.setEditedText("https://docs.example.com/new")
        let open = try XCTUnwrap(chip(label: "Open", in: controller.view))
        XCTAssertFalse(open.isHidden)
        XCTAssertTrue(open.accessibilityActivate())
        XCTAssertEqual(opened?.raw, "https://docs.example.com/new")
        XCTAssertEqual(dismissCount, 1)

        controller.setEditedText("not an address")
        XCTAssertTrue(open.isHidden)
        XCTAssertNil(controller.editedLink)
    }

    func testLinkSheetKeepsBlockedTargetsCopyableButNotOpenable() throws {
        let initial = try XCTUnwrap(TerminalLink.resolve("file:///etc/shadow"))
        var copied: String?
        var opened = false
        let controller = TerminalLinkSheetViewController(
            link: initial,
            onOpen: { _ in opened = true },
            onCopy: { copied = $0 }
        )
        controller.onDismiss = {}
        controller.loadViewIfNeeded()

        let open = try XCTUnwrap(chip(label: "Open", in: controller.view))
        let copy = try XCTUnwrap(chip(label: "Copy", in: controller.view))
        XCTAssertTrue(open.isHidden)
        XCTAssertTrue(copy.accessibilityActivate())
        XCTAssertEqual(copied, "file:///etc/shadow")
        XCTAssertFalse(opened)
    }

    func testLinkSheetOffersViewportForCurrentEditedAddress() throws {
        let initial = try XCTUnwrap(TerminalLink.resolve("https://example.com"))
        var openedViewport: ViewportOffer?
        let controller = TerminalLinkSheetViewController(
            link: initial,
            viewportOffer: { link in
                guard let url = link.openableURL else { return nil }
                return ViewportOffer(url: url, reach: .internet, viaHostName: nil)
            },
            onOpen: { _ in },
            onCopy: { _ in },
            onOpenViewport: { openedViewport = $0 }
        )
        controller.onDismiss = {}
        controller.loadViewIfNeeded()

        controller.setEditedText("https://multiplexterm.dev/docs")
        let viewport = try XCTUnwrap(chip(label: "⌗ Viewport", in: controller.view))
        XCTAssertFalse(viewport.isHidden)
        XCTAssertTrue(viewport.accessibilityActivate())
        XCTAssertEqual(openedViewport?.url.absoluteString, "https://multiplexterm.dev/docs")
    }

    func testPathSheetPreservesLineAndViewsEditedTarget() throws {
        let initial = try XCTUnwrap(TerminalPathTarget.resolve("Sources/App.swift:42"))
        var viewed: TerminalPathTarget?
        var dismissCount = 0
        let controller = TerminalFilePathSheetViewController(
            target: initial,
            hostName: "devbox",
            onView: { viewed = $0 },
            onCopy: { _ in }
        )
        controller.onDismiss = { dismissCount += 1 }
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.editedText, "Sources/App.swift:42")
        controller.setEditedText("Sources/Scene.swift:7")
        let view = try XCTUnwrap(chip(label: "View", in: controller.view))
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(view.accessibilityActivate())
        XCTAssertEqual(viewed?.path, "Sources/Scene.swift")
        XCTAssertEqual(viewed?.line, 7)
        XCTAssertEqual(dismissCount, 1)
    }

    func testPathSheetSemanticUpdatesRetainEditorSectionAndActions() throws {
        let initial = try XCTUnwrap(TerminalPathTarget.resolve("Sources/App.swift:42"))
        let controller = TerminalFilePathSheetViewController(
            target: initial,
            hostName: "devbox",
            onView: { _ in },
            onCopy: { _ in }
        )
        controller.loadViewIfNeeded()
        let editor = controller.editor
        let section = controller.sectionView
        let actionStack = controller.actionStack
        let actions = actionStack.arrangedSubviews

        controller.setEditedText("Sources/Edited.swift:9")
        controller.updateSource(target: initial, hostName: "devbox")

        XCTAssertEqual(controller.editedText, "Sources/Edited.swift:9")
        XCTAssertTrue(controller.editor === editor)
        XCTAssertTrue(controller.sectionView === section)
        XCTAssertTrue(controller.actionStack === actionStack)
        for (updated, original) in zip(controller.actionStack.arrangedSubviews, actions) {
            XCTAssertTrue(updated === original)
        }

        controller.updateSource(target: initial, hostName: "prod")
        XCTAssertEqual(controller.editedText, "Sources/Edited.swift:9")
        XCTAssertTrue(descendants(of: UILabel.self, in: controller.view).contains {
            $0.text == "prod"
        })
    }

    func testPathSheetHidesViewForInvalidEditButCopiesExactText() throws {
        let initial = try XCTUnwrap(TerminalPathTarget.resolve("Sources/App.swift"))
        var copied: String?
        let controller = TerminalFilePathSheetViewController(
            target: initial,
            hostName: "devbox",
            onView: { _ in XCTFail("Invalid path must not open") },
            onCopy: { copied = $0 }
        )
        controller.onDismiss = {}
        controller.loadViewIfNeeded()

        controller.setEditedText("not a path")
        let view = try XCTUnwrap(chip(label: "View", in: controller.view))
        let copy = try XCTUnwrap(chip(label: "Copy", in: controller.view))
        XCTAssertTrue(view.isHidden)
        XCTAssertTrue(copy.accessibilityActivate())
        XCTAssertEqual(copied, "not a path")
    }

    private func chip(label: String, in root: UIView) -> UIKitChassisChip? {
        if let chip = root as? UIKitChassisChip,
           chip.accessibilityLabel == label {
            return chip
        }
        for child in root.subviews {
            if let match = chip(label: label, in: child) { return match }
        }
        return nil
    }

    private func descendants<View: UIView>(of type: View.Type, in root: UIView) -> [View] {
        var result: [View] = []
        if let view = root as? View { result.append(view) }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}
