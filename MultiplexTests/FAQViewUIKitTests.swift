import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class FAQViewUIKitTests: XCTestCase {
    /// The multiplexer answer speaks for both backends, and the backend is a
    /// per-host setting the FAQ cannot know — so the install road is a
    /// tmux | herdr choice bar that swaps the commands *and* the PATH note
    /// in place, never a stacked list of both.
    func testMultiplexerAnswerSwapsInstallCommandsAndPathNoteWithTheBackendBar() throws {
        let controller = FAQViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 640, height: 2_000)
        controller.view.layoutIfNeeded()

        let bar = try XCTUnwrap(
            descendants(of: AddHostChoiceBar<Host.SessionBackend>.self, in: controller.view)
                .first { $0.accessibilityIdentifier == "faq.backendBar" }
        )
        let buttons = descendants(of: UIButton.self, in: bar)
        XCTAssertEqual(buttons.compactMap(\.accessibilityLabel), ["tmux", "herdr"])
        XCTAssertEqual(bar.selection, .tmux)

        var commands = commandTexts(in: controller.view)
        XCTAssertEqual(
            commands.filter { HostGuide.tmuxInstall.map(\.command).contains($0) },
            HostGuide.tmuxInstall.map(\.command)
        )
        XCTAssertFalse(commands.contains(where: {
            HostGuide.herdrInstall.map(\.command).contains($0)
        }))
        var rendered = renderedText(in: controller.view)
        XCTAssertTrue(rendered.contains(HostGuide.probePathDetail(for: .tmux)))
        XCTAssertFalse(rendered.contains(HostGuide.probePathDetail(for: .herdr)))

        buttons[1].sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(bar.selection, .herdr)
        commands = commandTexts(in: controller.view)
        XCTAssertEqual(
            commands.filter { HostGuide.herdrInstall.map(\.command).contains($0) },
            HostGuide.herdrInstall.map(\.command)
        )
        XCTAssertFalse(commands.contains(where: {
            HostGuide.tmuxInstall.map(\.command).contains($0)
        }))
        rendered = renderedText(in: controller.view)
        XCTAssertTrue(rendered.contains(HostGuide.probePathDetail(for: .herdr)))
        XCTAssertFalse(rendered.contains(HostGuide.probePathDetail(for: .tmux)))

        // The other answers are untouched by the swap — the keychain fix is
        // still one copyable command below it.
        XCTAssertTrue(commands.contains(HostGuide.keychainUnlock.command))
    }

    private func commandTexts(in root: UIView) -> [String] {
        descendants(of: UITextView.self, in: root).compactMap(\.text)
    }

    private func renderedText(in root: UIView) -> [String] {
        var result: [String] = []
        if let label = root as? UILabel {
            if let text = label.text {
                result.append(text)
            } else if let text = label.attributedText?.string {
                result.append(text)
            }
        }
        if let textView = root as? UITextView, let text = textView.text {
            result.append(text)
        }
        for child in root.subviews {
            result.append(contentsOf: renderedText(in: child))
        }
        return result
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var result: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}
