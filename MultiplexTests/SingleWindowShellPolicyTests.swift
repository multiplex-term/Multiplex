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

    func testNarrowShellMovesTmuxShortcutFromKeyRailToTopBar() {
        XCTAssertTrue(SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: 375,
            supportsTmuxShortcuts: true
        ))
        XCTAssertFalse(SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: 390,
            supportsTmuxShortcuts: true
        ))
        XCTAssertFalse(SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: 375,
            supportsTmuxShortcuts: false
        ))
    }

    func testLockedPhoneReturnKeyMovesTmuxUntilAirWidth() {
        XCTAssertTrue(SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: 390,
            supportsTmuxShortcuts: true,
            keyBarIncludesReturnKey: true
        ))
        XCTAssertTrue(SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: 419.999,
            supportsTmuxShortcuts: true,
            keyBarIncludesReturnKey: true
        ))
        XCTAssertFalse(SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: 420,
            supportsTmuxShortcuts: true,
            keyBarIncludesReturnKey: true
        ))
        XCTAssertFalse(SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: 375,
            supportsTmuxShortcuts: false,
            keyBarIncludesReturnKey: true
        ))
    }

    func testBackSwipeBeginsOnlyForUnselectedRightwardHorizontalIntent() {
        XCTAssertTrue(SingleWindowShellBackSwipe.shouldBegin(
            horizontalVelocity: 300,
            verticalVelocity: 100,
            hasActiveTextSelection: false
        ))
        XCTAssertFalse(SingleWindowShellBackSwipe.shouldBegin(
            horizontalVelocity: -300,
            verticalVelocity: 100,
            hasActiveTextSelection: false
        ))
        XCTAssertFalse(SingleWindowShellBackSwipe.shouldBegin(
            horizontalVelocity: 100,
            verticalVelocity: 300,
            hasActiveTextSelection: false
        ))
        XCTAssertFalse(SingleWindowShellBackSwipe.shouldBegin(
            horizontalVelocity: 300,
            verticalVelocity: 100,
            hasActiveTextSelection: true
        ))
    }

    func testBackSwipeAvailabilityDoesNotDependOnMotionPreference() {
        XCTAssertTrue(SingleWindowShellBackSwipe.isAvailable(
            idiom: .phone,
            expanded: false,
            compactShowsTerminal: true
        ))
        XCTAssertFalse(SingleWindowShellBackSwipe.isAvailable(
            idiom: .phone,
            expanded: true,
            compactShowsTerminal: true
        ))
        XCTAssertFalse(SingleWindowShellBackSwipe.isAvailable(
            idiom: .pad,
            expanded: false,
            compactShowsTerminal: true
        ))
    }

    func testBackSwipeTranslationStaysWithinTheStage() {
        XCTAssertEqual(
            SingleWindowShellBackSwipe.constrainedTranslation(-20, width: 390),
            0
        )
        XCTAssertEqual(
            SingleWindowShellBackSwipe.constrainedTranslation(120, width: 390),
            120
        )
        XCTAssertEqual(
            SingleWindowShellBackSwipe.constrainedTranslation(500, width: 390),
            390
        )
        XCTAssertEqual(
            SingleWindowShellBackSwipe.constrainedTranslation(120, width: 0),
            0
        )
    }

    func testBackSwipeCompletesFromDistanceOrProjectedForwardVelocity() {
        XCTAssertTrue(SingleWindowShellBackSwipe.shouldReturnToDeck(
            translation: 200,
            velocity: 0,
            width: 390
        ))
        XCTAssertTrue(SingleWindowShellBackSwipe.shouldReturnToDeck(
            translation: 80,
            velocity: 600,
            width: 390
        ))
    }

    func testBackSwipeCancelsWhenShortStationaryOrReversing() {
        XCTAssertFalse(SingleWindowShellBackSwipe.shouldReturnToDeck(
            translation: 80,
            velocity: 0,
            width: 390
        ))
        XCTAssertFalse(SingleWindowShellBackSwipe.shouldReturnToDeck(
            translation: 250,
            velocity: -300,
            width: 390
        ))
        XCTAssertFalse(SingleWindowShellBackSwipe.shouldReturnToDeck(
            translation: 200,
            velocity: 1_000,
            width: 0
        ))
    }
}
