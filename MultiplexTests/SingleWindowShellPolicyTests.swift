import XCTest
@testable import Multiplex

final class SingleWindowShellPolicyTests: XCTestCase {
    func testDefaultDecisionMatrix() {
        let cases: [(
            platform: ShellModeDecision.Platform,
            idiom: ShellModeDecision.Idiom,
            fullScreen: Bool,
            expected: Bool
        )] = [
            (.iOS, .phone, false, true),
            (.iOS, .phone, true, true),
            (.iOS, .pad, false, false),
            (.iOS, .pad, true, true),
            (.iOS, .other, false, false),
            (.iOS, .other, true, false),
            (.visionOS, .other, false, false),
            (.visionOS, .pad, true, false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ShellModeDecision.usesSingleWindowShell(
                    platform: testCase.platform,
                    idiom: testCase.idiom,
                    isFullScreen: testCase.fullScreen,
                    environmentOverride: nil
                ),
                testCase.expected,
                "\(testCase.platform) \(testCase.idiom) fullScreen=\(testCase.fullScreen)"
            )
        }
    }

    func testForceOnOverridesEveryPlatformAndIdiom() {
        for platform in [ShellModeDecision.Platform.iOS, .visionOS] {
            for idiom in [
                ShellModeDecision.Idiom.phone,
                .pad,
                .other,
            ] {
                for fullScreen in [false, true] {
                    XCTAssertTrue(ShellModeDecision.usesSingleWindowShell(
                        platform: platform,
                        idiom: idiom,
                        isFullScreen: fullScreen,
                        environmentOverride: "1"
                    ))
                }
            }
        }
    }

    func testForceOffOverridesEveryPlatformAndIdiom() {
        for platform in [ShellModeDecision.Platform.iOS, .visionOS] {
            for idiom in [
                ShellModeDecision.Idiom.phone,
                .pad,
                .other,
            ] {
                for fullScreen in [false, true] {
                    XCTAssertFalse(ShellModeDecision.usesSingleWindowShell(
                        platform: platform,
                        idiom: idiom,
                        isFullScreen: fullScreen,
                        environmentOverride: "0"
                    ))
                }
            }
        }
    }

    func testUnknownOverrideFallsBackToScenePolicy() {
        XCTAssertTrue(ShellModeDecision.usesSingleWindowShell(
            platform: .iOS,
            idiom: .phone,
            isFullScreen: false,
            environmentOverride: "yes"
        ))
        XCTAssertFalse(ShellModeDecision.usesSingleWindowShell(
            platform: .iOS,
            idiom: .pad,
            isFullScreen: false,
            environmentOverride: "yes"
        ))
    }

    func testExpandedLayoutStartsAt620Points() {
        XCTAssertFalse(SingleWindowShellLayout.isExpanded(width: 619.999))
        XCTAssertTrue(SingleWindowShellLayout.isExpanded(width: 620))
        XCTAssertTrue(SingleWindowShellLayout.isExpanded(width: 1_024))
        XCTAssertEqual(SingleWindowShellLayout.deckRailWidth, 316)
    }
}
