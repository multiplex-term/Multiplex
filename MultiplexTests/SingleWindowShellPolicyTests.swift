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

    func testPhoneExpandsOnTheTerminalsWidthAndPadOnTheWindows() {
        let phone: [(available: CGFloat, expected: Bool, note: String)] = [
            (410, true, "iPhone 16e landscape beside the rail"),
            (440, true, "iPhone Pro Max landscape"),
            (389.999, false, "just under the key rail's TMUX tier"),
            (351, false, "SE-class 667-wide landscape"),
            (292, false, "iPhone Duo closed landscape"),
            (310, false, "iPhone Duo open portrait"),
            (504, true, "iPhone Duo open landscape"),
        ]
        for testCase in phone {
            XCTAssertEqual(
                SingleWindowShellLayout.isExpanded(
                    usableWidth: 2_000,
                    terminalAvailableWidthIfExpanded: testCase.available,
                    idiom: .phone
                ),
                testCase.expected,
                testCase.note
            )
        }
        XCTAssertEqual(
            SingleWindowShellLayout.phoneTerminalMinimumWidth,
            SingleWindowShellLayout.keyBarTmuxMinimumWidth
        )

        // The iPad ignores the terminal figure: its shell is full-screen.
        XCTAssertTrue(SingleWindowShellLayout.isExpanded(
            usableWidth: 620,
            terminalAvailableWidthIfExpanded: 304,
            idiom: .pad
        ))
        XCTAssertFalse(SingleWindowShellLayout.isExpanded(
            usableWidth: 619.999,
            terminalAvailableWidthIfExpanded: 1_000,
            idiom: .pad
        ))
        XCTAssertTrue(SingleWindowShellLayout.isExpanded(
            usableWidth: 744,
            terminalAvailableWidthIfExpanded: 428,
            idiom: .other
        ))
    }

    func testCornerInsetOnlyWhereThePhoneHasNoInsetAboveOrBesideTheCorner() {
        func inset(top: CGFloat, leading: CGFloat, idiom: ShellModeDecision.Idiom,
                   width: ShellSizeClass = .regular) -> CGFloat {
            SingleWindowShellLayout.cornerLeadingInset(
                topSafeArea: top, leadingSafeArea: leading, idiom: idiom, horizontalSizeClass: width)
        }
        XCTAssertEqual(inset(top: 0, leading: 0, idiom: .phone), 24, "Duo inner landscape")
        XCTAssertEqual(inset(top: 0, leading: 0, idiom: .phone, width: .compact), 0,
                       "Duo closed display: a 6 pt corner, title flush")
        XCTAssertEqual(inset(top: 82, leading: 0, idiom: .phone), 0, "Duo inner portrait")
        XCTAssertEqual(inset(top: 0, leading: 59, idiom: .phone, width: .compact), 0,
                       "notched iPhone landscape")
        XCTAssertEqual(inset(top: 59, leading: 0, idiom: .phone, width: .compact), 0, "iPhone portrait")
        XCTAssertEqual(inset(top: 0, leading: 0, idiom: .pad), 0, "iPad never")
    }

    func testTheRailTakesTheHomeStripOnIPadAndOnAFoldable() {
        XCTAssertTrue(SingleWindowShellLayout.railAlwaysTakesBottomStrip(idiom: .pad, foldable: false))
        XCTAssertTrue(SingleWindowShellLayout.railAlwaysTakesBottomStrip(idiom: .phone, foldable: true))
        XCTAssertFalse(SingleWindowShellLayout.railAlwaysTakesBottomStrip(idiom: .phone, foldable: false),
                       "a shipped iPhone in portrait keeps its strip")
        XCTAssertFalse(SingleWindowShellLayout.railAlwaysTakesBottomStrip(idiom: .other, foldable: false))
    }

    func testTheFoldableGoesBareEveryOtherDeviceKeepsTheSlab() {
        XCTAssertTrue(SingleWindowShellLayout.chromeIsBare(idiom: .phone, foldable: true), "iPhone Duo")
        XCTAssertFalse(SingleWindowShellLayout.chromeIsBare(idiom: .phone, foldable: false), "shipped iPhone")
        XCTAssertFalse(SingleWindowShellLayout.chromeIsBare(idiom: .pad, foldable: false))
    }

    func testDeckActionsStandInTheColumnOnlyWhileTheDeckSpansTheShell() {
        XCTAssertEqual(
            SingleWindowShellLayout.deckActionColumnEdge(railEdge: .trailing, deckSpansShell: true),
            .trailing, "inner landscape, deck alone"
        )
        XCTAssertEqual(
            SingleWindowShellLayout.deckActionColumnEdge(railEdge: .trailing, deckSpansShell: false),
            .top, "beside a terminal the terminal's column owns the strip"
        )
        XCTAssertEqual(
            SingleWindowShellLayout.deckActionColumnEdge(railEdge: .top, deckSpansShell: true),
            .top, "shipped iPhone"
        )
    }

    func testBareTopPaddingOnlyOnTheInnerDisplayWithNoTopInset() {
        func padding(
            top: CGFloat, idiom: ShellModeDecision.Idiom = .phone,
            horizontal: ShellSizeClass = .regular, vertical: ShellSizeClass = .regular
        ) -> CGFloat {
            SingleWindowShellLayout.bareTopPadding(
                topSafeArea: top, idiom: idiom, horizontalSizeClass: horizontal, verticalSizeClass: vertical
            )
        }
        XCTAssertEqual(padding(top: 0), 8, "inner display, landscape")
        XCTAssertEqual(padding(top: 82), 0, "inner portrait has the band")
        XCTAssertEqual(padding(top: 0, horizontal: .compact, vertical: .compact), 0, "closed display, landscape")
        XCTAssertEqual(padding(top: 0, horizontal: .regular, vertical: .compact), 0, "a shipped iPhone, landscape")
        XCTAssertEqual(padding(top: 59, horizontal: .compact, vertical: .regular), 0)
        XCTAssertEqual(padding(top: 0, idiom: .pad), 0)
    }

    func testTopBandOnlyOnTheDuoInnerPortrait() {
        XCTAssertEqual(SingleWindowShellLayout.topBandHeight(
            topSafeArea: 82, idiom: .phone, horizontalSizeClass: .regular, verticalSizeClass: .regular), 82)
        XCTAssertEqual(SingleWindowShellLayout.topBandHeight(
            topSafeArea: 59, idiom: .phone, horizontalSizeClass: .compact, verticalSizeClass: .regular), 0,
            "an iPhone's status bar is not a band")
        XCTAssertEqual(SingleWindowShellLayout.topBandHeight(
            topSafeArea: 0, idiom: .phone, horizontalSizeClass: .regular, verticalSizeClass: .regular), 0)
        XCTAssertEqual(SingleWindowShellLayout.topBandHeight(
            topSafeArea: 82, idiom: .pad, horizontalSizeClass: .regular, verticalSizeClass: .regular), 0)
        XCTAssertEqual(SingleWindowShellLayout.topBandTrailingClearance, 128)
        XCTAssertEqual(ShellHeaderChrome(bandHeight: 82).bandTrailingClearance, 128)
        XCTAssertEqual(ShellHeaderChrome(bandHeight: 82).bandRowCenterY, 48)
        XCTAssertEqual(ShellHeaderChrome.none.bandTrailingClearance, 0)
        XCTAssertNil(ShellHeaderChrome.none.bandRowCenterY)
    }

    func testBandRowsAndColumnChipsSitOnTheSystemGlyphLine() {
        XCTAssertEqual(SingleWindowShellLayout.systemGlyphLine, 48)
        XCTAssertEqual(SingleWindowShellLayout.topBandRowCenter(bandHeight: 82), 48)
        XCTAssertEqual(SingleWindowShellLayout.topBandRowCenter(bandHeight: 40), 20)
        XCTAssertEqual(SingleWindowShellLayout.sideColumnCenterX(stripWidth: 84, trailingEdge: true), 36)
        XCTAssertEqual(SingleWindowShellLayout.sideColumnCenterX(stripWidth: 84, trailingEdge: false), 48)
    }

    func testRailEdgeFollowsTheSystemThenOnlyTheDuoInnerDisplay() {
        struct Case {
            let system: ShellRailEdge?
            let idiom: ShellModeDecision.Idiom
            let horizontal: ShellSizeClass
            let vertical: ShellSizeClass
            let landscape: Bool
            var foldable = false
            var leading: CGFloat = 0
            var trailing: CGFloat = 0
            let expected: ShellRailEdge
            let note: String
        }
        let cases = [
            Case(system: .leading, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, expected: .leading, note: "system edge wins on the closed display"),
            Case(system: .trailing, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, expected: .trailing, note: "Split View right-hand app"),
            Case(system: .top, idiom: .phone, horizontal: .regular, vertical: .regular,
                 landscape: true, expected: .top, note: "an explicit system .top also wins"),
            Case(system: nil, idiom: .phone, horizontal: .regular, vertical: .compact,
                 landscape: true, expected: .top, note: "every shipped iPhone in landscape"),
            Case(system: nil, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, expected: .top, note: "every shipped iPhone in portrait"),
            Case(system: nil, idiom: .phone, horizontal: .regular, vertical: .regular,
                 landscape: true, expected: .leading, note: "Duo inner display, landscape"),
            Case(system: nil, idiom: .phone, horizontal: .regular, vertical: .regular,
                 landscape: false, expected: .top, note: "Duo inner display, portrait"),
            Case(system: nil, idiom: .pad, horizontal: .regular, vertical: .regular,
                 landscape: true, expected: .top, note: "iPad never moves the rail"),
            Case(system: nil, idiom: .phone, horizontal: .compact, vertical: .compact,
                 landscape: true, foldable: true, leading: 90, trailing: 0, expected: .leading,
                 note: "Duo closed display, landscape: the camera's strip"),
            Case(system: nil, idiom: .phone, horizontal: .compact, vertical: .compact,
                 landscape: true, foldable: true, leading: 0, trailing: 90, expected: .trailing,
                 note: "Duo closed display, rotated the other way"),
            Case(system: nil, idiom: .phone, horizontal: .compact, vertical: .compact,
                 landscape: true, foldable: false, leading: 59, trailing: 59, expected: .top,
                 note: "a compact iPhone in landscape stays put"),
            Case(system: nil, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, foldable: true, expected: .top,
                 note: "Duo closed display, portrait"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ShellRailPlacement.edge(
                    systemVerticalBarEdge: testCase.system,
                    idiom: testCase.idiom,
                    horizontalSizeClass: testCase.horizontal,
                    verticalSizeClass: testCase.vertical,
                    isLandscape: testCase.landscape,
                    foldable: testCase.foldable,
                    leadingSafeArea: testCase.leading,
                    trailingSafeArea: testCase.trailing
                ),
                testCase.expected,
                testCase.note
            )
        }
    }

    func testTerminalFontDefaultsPerDeviceClass() {
        XCTAssertEqual(TerminalFontDefaults.pointSize(
            idiom: .phone, horizontalSizeClass: .regular, verticalSizeClass: .regular
        ), 13, "Duo inner display")
        XCTAssertEqual(TerminalFontDefaults.pointSize(
            idiom: .phone, horizontalSizeClass: .compact, verticalSizeClass: .regular
        ), 12, "phone portrait, Duo closed included")
        XCTAssertEqual(TerminalFontDefaults.pointSize(
            idiom: .phone, horizontalSizeClass: .regular, verticalSizeClass: .compact
        ), 12, "phone landscape")
        XCTAssertEqual(TerminalFontDefaults.pointSize(
            idiom: .pad, horizontalSizeClass: .regular, verticalSizeClass: .regular
        ), 14)
        XCTAssertEqual(TerminalFontDefaults.pointSize(
            idiom: .other, horizontalSizeClass: .unspecified, verticalSizeClass: .unspecified
        ), 14)
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
