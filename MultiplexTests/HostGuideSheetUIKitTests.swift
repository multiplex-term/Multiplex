import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class HostGuideSheetUIKitTests: XCTestCase {
    func testTmuxControllerPreservesNavigationLayoutCopyAndAccessibility() {
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let controller = TmuxInstallViewController(host: host)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.title, "Install tmux")
        XCTAssertEqual(controller.navigationItem.largeTitleDisplayMode, .never)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, "Done")
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.style, .plain)
        XCTAssertNil(controller.navigationItem.rightBarButtonItem?.customView)
        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItem?.accessibilityLabel,
            "Done"
        )
        XCTAssertEqual(
            controller.contentStack.spacing,
            UIKitHostGuideSheetViewController.sectionSpacing
        )
        XCTAssertEqual(UIKitHostGuideSheetViewController.outerInset, 18)
        XCTAssertEqual(UIKitHostGuideSheetViewController.contentMaximumWidth, 560)
        XCTAssertTrue(hasContentMaximumWidthConstraint(in: controller.view))

        let rendered = renderedText(in: controller.view)
        XCTAssertTrue(rendered.contains("THE DECK RUNS ON TMUX"))
        XCTAssertTrue(rendered.contains(controller.intro))
        XCTAssertTrue(rendered.contains(
            "The deck re-probes every few seconds — session tiles light up as soon as "
                + "tmux is on the host. Homebrew and /usr/local installs are already "
                + "on the probe's PATH."
        ))
        XCTAssertEqual(
            descendants(of: UITextView.self, in: controller.view).map(\.text),
            HostGuide.tmuxInstall.map(\.command)
        )

        let headers = descendants(of: UIKitChassisLabel.self, in: controller.view)
            .filter { $0.accessibilityTraits.contains(.header) }
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers.first?.accessibilityLabel, "The deck runs on tmux")

        let copyChips = descendants(of: UIKitChassisChip.self, in: controller.view)
        XCTAssertEqual(copyChips.count, HostGuide.tmuxInstall.count)
        XCTAssertTrue(copyChips.allSatisfy {
            $0.accessibilityLabel == "Copy command"
                && $0.accessibilityTraits.contains(.button)
        })

        assertDoneRoutesFromNavigationItem(controller)
        controller.appAppearance = .light
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .light)
        controller.appAppearance = .dark
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .dark)
    }

    func testHerdrControllerUsesBackendSpecificTitleCopyAndCommands() {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.sessionBackend = .herdr
        let controller = TmuxInstallViewController(host: host)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.title, "Install herdr")
        let rendered = renderedText(in: controller.view)
        XCTAssertTrue(rendered.contains("THE DECK RUNS ON HERDR"))
        XCTAssertTrue(rendered.contains(controller.intro))
        XCTAssertEqual(
            descendants(of: UITextView.self, in: controller.view).map(\.text),
            HostGuide.herdrInstall.map(\.command)
        )
    }

    func testKeychainControllerPreservesHostInterpolationSessionsAndCommand() {
        let host = Host(name: "studio", hostname: "studio.local", username: "jhen")
        let controller = KeychainUnlockViewController(
            host: host,
            sessionNames: ["main", "agent"]
        )
        _ = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.title, "Keychain locked")
        let rendered = renderedText(in: controller.view)
        XCTAssertTrue(rendered.contains("CLAUDE CODE SHOWS SIGNED OUT"))
        XCTAssertTrue(rendered.contains(controller.intro))
        XCTAssertEqual(controller.intro.components(separatedBy: "studio").count - 1, 2)
        XCTAssertTrue(rendered.contains("Detected in: main · agent"))
        XCTAssertTrue(rendered.contains(
            "The command prompts for that Mac account's login password. The unlock "
                + "holds until macOS locks the keychain again — after a restart, or "
                + "per the keychain's own lock settings."
        ))
        XCTAssertEqual(
            descendants(of: UITextView.self, in: controller.view).map(\.text),
            [HostGuide.keychainUnlock.command]
        )
        assertDoneRoutesFromNavigationItem(controller)
    }

    func testKeychainControllerOmitsDetectedRowForEmptySnapshot() {
        let host = Host(name: "studio", hostname: "studio.local", username: "jhen")
        let controller = KeychainUnlockViewController(host: host, sessionNames: [])
        controller.loadViewIfNeeded()

        XCTAssertFalse(renderedText(in: controller.view).contains {
            $0.hasPrefix("Detected in:")
        })
    }

    func testNativeCopyFieldWritesClipboardAndAcknowledgesThroughAccessibleChip() {
        let command = "brew install tmux"
        var clipboardWrites: [String] = []
        let field = UIKitCopyableCommandField(
            label: "macOS",
            command: command,
            writeClipboard: { clipboardWrites.append($0) }
        )
        field.layoutIfNeeded()
        let chip = descendants(of: UIKitChassisChip.self, in: field).first

        XCTAssertNotNil(chip)
        XCTAssertTrue(chip?.accessibilityActivate() == true)
        XCTAssertEqual(clipboardWrites, [command])
        XCTAssertTrue(renderedText(in: field).contains("COPIED"))
        XCTAssertEqual(chip?.accessibilityLabel, "Copy command")
    }

    private func assertDoneRoutesFromNavigationItem(
        _ controller: UIKitHostGuideSheetViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var fired = false
        controller.onDone = { fired = true }
        guard let item = controller.navigationItem.rightBarButtonItem,
              let action = item.action else {
            return XCTFail("Missing Done bar action", file: file, line: line)
        }

        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        XCTAssertTrue(fired, file: file, line: line)
    }

    private func hasContentMaximumWidthConstraint(in root: UIView) -> Bool {
        guard let contentStack = descendants(of: UIStackView.self, in: root)
            .first(where: {
                $0.axis == .vertical
                    && $0.spacing == UIKitHostGuideSheetViewController.sectionSpacing
            }) else {
            return false
        }

        return allConstraints(in: root).contains { constraint in
            (constraint.firstItem as? UIStackView) === contentStack
                && constraint.firstAttribute == .width
                && constraint.relation == .lessThanOrEqual
                && constraint.constant == UIKitHostGuideSheetViewController.contentMaximumWidth
        }
    }

    private func allConstraints(in view: UIView) -> [NSLayoutConstraint] {
        view.constraints + view.subviews.flatMap(allConstraints(in:))
    }

    private func renderedText(in root: UIView) -> [String] {
        let labels = descendants(of: UILabel.self, in: root).compactMap {
            $0.attributedText?.string ?? $0.text
        }
        let textViews = descendants(of: UITextView.self, in: root).compactMap(\.text)
        return labels + textViews
    }

    private func descendants<View: UIView>(
        of type: View.Type,
        in root: UIView
    ) -> [View] {
        var result: [View] = []
        if let match = root as? View {
            result.append(match)
        }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}
