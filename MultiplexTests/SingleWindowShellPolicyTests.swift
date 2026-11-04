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
                    padPrefersShell: false,
                    environmentOverride: nil
                ),
                testCase.expected,
                "\(testCase.platform) \(testCase.idiom) fullScreen=\(testCase.fullScreen)"
            )
        }
    }

    func testPadOptInOnlyMovesTheIPad() {
        let cases: [(
            platform: ShellModeDecision.Platform,
            idiom: ShellModeDecision.Idiom,
            expected: Bool
        )] = [
            (.iOS, .pad, true),
            (.iOS, .phone, true),
            (.iOS, .other, false),
            (.visionOS, .pad, false),
            (.visionOS, .other, false),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ShellModeDecision.usesSingleWindowShell(
                    platform: testCase.platform,
                    idiom: testCase.idiom,
                    isFullScreen: false,
                    padPrefersShell: true,
                    environmentOverride: nil
                ),
                testCase.expected,
                "\(testCase.platform) \(testCase.idiom)"
            )
        }
        XCTAssertFalse(ShellModeDecision.usesSingleWindowShell(
            platform: .iOS,
            idiom: .pad,
            isFullScreen: false,
            padPrefersShell: true,
            environmentOverride: "0"
        ))
    }

    func testPadOptInDefaultsOffAndPersists() throws {
        let suite = "SingleWindowShellSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(SingleWindowShellSetting.isEnabled(defaults: defaults))
        SingleWindowShellSetting.setEnabled(true, defaults: defaults)
        XCTAssertTrue(SingleWindowShellSetting.isEnabled(defaults: defaults))
        SingleWindowShellSetting.setEnabled(false, defaults: defaults)
        XCTAssertFalse(SingleWindowShellSetting.isEnabled(defaults: defaults))
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
                        padPrefersShell: false,
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
                        padPrefersShell: false,
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
            padPrefersShell: false,
            environmentOverride: "yes"
        ))
        XCTAssertFalse(ShellModeDecision.usesSingleWindowShell(
            platform: .iOS,
            idiom: .pad,
            isFullScreen: false,
            padPrefersShell: false,
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

    func testExpandingRestoresAHiddenRailOnlyFromTheDeckOrAnotherDisplay() {
        let book = CGSize(width: 951, height: 669)
        let portrait = CGSize(width: 669, height: 951)
        let closed = CGSize(width: 466, height: 678)
        // Rotation on one display: the rail ◧ hid stays hidden.
        XCTAssertFalse(SingleWindowShellLayout.restoresDeckRailOnExpand(
            compactShowsTerminal: true, from: portrait, to: book
        ))
        XCTAssertFalse(SingleWindowShellLayout.restoresDeckRailOnExpand(
            compactShowsTerminal: true, from: CGSize(width: 669.5, height: 951), to: book
        ))
        // ‹ DECK in the single pane: the user went to the deck.
        XCTAssertTrue(SingleWindowShellLayout.restoresDeckRailOnExpand(
            compactShowsTerminal: false, from: portrait, to: book
        ))
        // Opening the Duo from its outer display.
        XCTAssertTrue(SingleWindowShellLayout.restoresDeckRailOnExpand(
            compactShowsTerminal: true, from: closed, to: book
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

    func testOnlyTheFoldablesClosedDisplayGoesBare() {
        XCTAssertTrue(
            SingleWindowShellLayout.chromeIsBare(idiom: .phone, foldable: true, compactWidth: true),
            "iPhone Duo closed"
        )
        XCTAssertFalse(
            SingleWindowShellLayout.chromeIsBare(idiom: .phone, foldable: true, compactWidth: false),
            "the inner display keeps the slab"
        )
        XCTAssertFalse(
            SingleWindowShellLayout.chromeIsBare(idiom: .phone, foldable: false, compactWidth: true),
            "shipped iPhone"
        )
        XCTAssertFalse(SingleWindowShellLayout.chromeIsBare(idiom: .pad, foldable: false, compactWidth: true))
    }

    func testDeckActionsStandInTheColumnOnlyWhileTheDeckSpansTheShell() {
        let column = ShellSideColumn(edge: .trailing, placement: .init(top: 12, bottom: 80))
        XCTAssertEqual(
            SingleWindowShellLayout.deckActionColumn(sideColumn: column, deckSpansShell: true),
            column, "closed display, deck alone"
        )
        XCTAssertEqual(
            SingleWindowShellLayout.deckActionColumn(sideColumn: column, deckSpansShell: false),
            .none, "beside a terminal the terminal's column owns the strip"
        )
        XCTAssertEqual(
            SingleWindowShellLayout.deckActionColumn(sideColumn: .none, deckSpansShell: true),
            .none, "shipped iPhone"
        )
    }

    func testSideColumnFrameAndCentreFollowTheEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 466, height: 678)
        let trailing = ShellSideColumn(edge: .trailing, placement: .init(top: 12, bottom: 80))
        XCTAssertEqual(trailing.frame(in: bounds, strip: 90), CGRect(x: 376, y: 12, width: 90, height: 586))
        XCTAssertEqual(trailing.frame(in: bounds, strip: 90, obstruction: 193).height, 473, "keyboard wins")
        XCTAssertEqual(trailing.centerX(stripWidth: 90), 42)
        let leading = ShellSideColumn(edge: .leading, placement: .init(top: 80, bottom: 12))
        XCTAssertEqual(leading.frame(in: bounds, strip: 30), CGRect(x: 0, y: 80, width: 48, height: 586), "48 pt floor")
        XCTAssertEqual(leading.centerX(stripWidth: 48), 48)
    }

    func testTheColumnStandsAboveTheKeyRailCrossingItsStrip() {
        let bounds = CGRect(x: 0, y: 0, width: 466, height: 678)
        let upright = ShellSideColumn(edge: .trailing, placement: .init(top: 160, bottom: 0))
        XCTAssertEqual(upright.frame(in: bounds, strip: 84, obstruction: 49).maxY, 629)
        XCTAssertEqual(
            upright.frame(in: bounds, strip: 84, obstruction: 252 + 49).maxY, 377,
            "the keyboard lifts the rail, and the column above it"
        )
        XCTAssertEqual(upright.frame(in: bounds, strip: 84).maxY, 678, "full screen folds the rail")
        let camera = ShellSideColumn(edge: .trailing, placement: .init(top: 12, bottom: 80))
        XCTAssertEqual(
            camera.frame(in: bounds, strip: 84, obstruction: 49).maxY, 598,
            "the camera's 80 pt already clears a resting rail"
        )
        XCTAssertEqual(
            camera.frame(in: bounds, strip: 84, obstruction: 193 + 49).maxY, 436,
            "the rail lifted over the keyboard stops the column"
        )
    }

    func testTheKeyRailRunsThroughTheColumnsStripAndKeepsOffCorners() {
        let pane = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 84)
        let trailing = ShellSideColumn(edge: .trailing, placement: .init(top: 160, bottom: 0))
        XCTAssertEqual(
            trailing.keyRailSafeArea(paneSafeArea: pane, cornerClearance: .none),
            UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        )
        XCTAssertEqual(
            trailing.keyRailSafeArea(paneSafeArea: pane, cornerClearance: .init(left: 0, right: 25)),
            UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 25),
            "across the strip, the corner sets the inset"
        )
        let leading = ShellSideColumn(edge: .leading, placement: .init(top: 80, bottom: 12))
        XCTAssertEqual(
            leading.keyRailSafeArea(paneSafeArea: pane, cornerClearance: .none),
            UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)
        )
        let inner = ShellSideColumn(edge: .trailing, placement: .init(top: 120, bottom: 0))
        XCTAssertEqual(
            inner.keyRailSafeArea(paneSafeArea: .zero, cornerClearance: .init(left: 21, right: 21)),
            UIEdgeInsets(top: 0, left: 21, bottom: 0, right: 21),
            "inner display, deck hidden: through the strip, off both corners"
        )
        XCTAssertEqual(
            inner.keyRailSafeArea(
                paneSafeArea: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84),
                cornerClearance: .init(left: 0, right: 21)
            ),
            UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 21),
            "inner display beside the deck rail"
        )
        XCTAssertEqual(
            ShellSideColumn.none.keyRailSafeArea(paneSafeArea: pane, cornerClearance: .none),
            pane,
            "no column: the pane's own insets"
        )
    }

    #if !os(visionOS)
    /// The widths each pose hands the rail, against what the device masks cut
    /// at the faces' bottom edge: every tier, the narrow book page's included.
    func testTheRailsEndKeysStayOnTheGlassInEveryPose() {
        let closed = SingleWindowShellLayout.closedBottomCornerClearance
        let inner = SingleWindowShellLayout.innerBottomCornerClearance
        struct Pose {
            var name: String
            var width: CGFloat
            var clearance: CGFloat
            var cut: CGFloat
            var left = true
        }
        let poses = [
            Pose(name: "closed upright", width: 466, clearance: closed, cut: 30, left: false),
            Pose(name: "closed, column right", width: 678, clearance: closed, cut: 30),
            Pose(name: "inner landscape, deck hidden", width: 951, clearance: inner, cut: 26),
            Pose(name: "inner landscape, beside the deck", width: 635, clearance: inner, cut: 26, left: false),
            Pose(name: "inner upright", width: 669, clearance: inner, cut: 26),
            Pose(name: "book page", width: 455.5, clearance: inner, cut: 26, left: false),
        ]
        for pose in poses {
            for includesReturn in [false, true] {
                for showsTmux in [false, true] {
                    let safeArea = UIEdgeInsets(
                        top: 0,
                        left: pose.left ? pose.clearance : 0,
                        bottom: 0,
                        right: pose.clearance
                    )
                    let specification = TerminalKeyBarLayout.specification(
                        width: pose.width,
                        contentSafeArea: safeArea,
                        showsTmux: showsTmux,
                        includesReturn: includesReturn,
                        returnOnlyWhileLocked: true
                    )
                    let frames = TerminalKeyBarLayout.keyFrames(
                        specification: specification,
                        keyCount: specification.keyCount(includesReturn: includesReturn),
                        includesReturn: includesReturn,
                        width: pose.width,
                        contentSafeArea: safeArea,
                        keyTop: 7,
                        keyHeight: 34
                    )
                    let faceInset = specification.metric.faceInset
                    if pose.left, let first = frames.first {
                        XCTAssertGreaterThanOrEqual(first.minX + faceInset, pose.cut, pose.name)
                    }
                    if let last = frames.last {
                        XCTAssertGreaterThanOrEqual(pose.width - last.maxX + faceInset, pose.cut, pose.name)
                    }
                }
            }
        }
    }
    #endif

    func testBottomCornerClearanceFollowsTheDisplaysBigCorners() {
        func clearance(
            idiom: ShellModeDecision.Idiom = .phone,
            closed: Bool = false,
            display: ShellSizeClass,
            vertical: ShellSizeClass,
            landscape: Bool,
            column: ShellRailEdge,
            corners: ShellBottomCorners = ShellBottomCorners(left: true, right: true)
        ) -> BottomCornerClearance {
            SingleWindowShellLayout.bottomCornerClearance(
                idiom: idiom,
                closedDisplay: closed,
                displayHorizontalSizeClass: display,
                verticalSizeClass: vertical,
                isLandscape: landscape,
                columnEdge: column,
                corners: corners
            )
        }
        XCTAssertEqual(
            clearance(closed: true, display: .compact, vertical: .regular, landscape: false, column: .trailing),
            .init(left: 0, right: 25),
            "closed upright: the hinge side's corners are small"
        )
        XCTAssertEqual(
            clearance(closed: true, display: .regular, vertical: .compact, landscape: true, column: .trailing),
            .init(left: 25, right: 25),
            "closed, column right: the big corners are along the bottom"
        )
        XCTAssertEqual(
            clearance(closed: true, display: .regular, vertical: .compact, landscape: true, column: .leading),
            .none,
            "closed, column left: the hinge side is along the bottom"
        )
        XCTAssertEqual(
            clearance(display: .regular, vertical: .regular, landscape: false, column: .top),
            .init(left: 21, right: 21),
            "inner display"
        )
        XCTAssertEqual(
            clearance(
                display: .regular,
                vertical: .regular,
                landscape: true,
                column: .trailing,
                corners: ShellBottomCorners(left: false, right: true)
            ),
            .init(left: 0, right: 21),
            "a pane beside the deck rail has no left corner"
        )
        XCTAssertEqual(
            clearance(closed: true, display: .compact, vertical: .regular, landscape: false, column: .top),
            .none,
            "closed, no column"
        )
        XCTAssertEqual(
            clearance(display: .compact, vertical: .regular, landscape: false, column: .top),
            .none,
            "shipped iPhone"
        )
        XCTAssertEqual(
            clearance(idiom: .pad, display: .regular, vertical: .regular, landscape: true, column: .top),
            .none,
            "iPad"
        )
    }

    func testTheTopRailKeepsOffTheClosedDisplaysTopRightCorner() {
        func inset(closed: Bool = true, landscape: Bool = true, column: ShellRailEdge) -> CGFloat {
            SingleWindowShellLayout.topTrailingCornerClearance(
                closedDisplay: closed, isLandscape: landscape, columnEdge: column
            )
        }
        XCTAssertEqual(inset(column: .leading), 25, "column left: the big corners are along the top")
        XCTAssertEqual(inset(column: .trailing), 0, "column right: the hinge side is along the top")
        XCTAssertEqual(inset(landscape: false, column: .trailing), 0, "upright: the column's strip clears it")
        XCTAssertEqual(inset(closed: false, column: .leading), 0, "inner display")
    }

    func testCornerClearanceWidensAnAuxiliaryRailWithoutEnteringTheStrip() {
        let clearance = BottomCornerClearance(left: 25, right: 25)
        XCTAssertEqual(
            clearance.applied(to: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)),
            UIEdgeInsets(top: 0, left: 25, bottom: 0, right: 84),
            "closed, column right: off the far corner, the column keeps its strip"
        )
        XCTAssertEqual(
            BottomCornerClearance.none.applied(to: UIEdgeInsets(top: 0, left: 84, bottom: 0, right: 0)),
            UIEdgeInsets(top: 0, left: 84, bottom: 0, right: 0)
        )
    }

    func testTheClosedDisplayIsKnownByItsShortEdgeInEveryRotation() {
        func closed(_ width: CGFloat, _ height: CGFloat, idiom: ShellModeDecision.Idiom = .phone) -> Bool {
            SingleWindowShellLayout.isClosedDisplay(idiom: idiom, screenSize: CGSize(width: width, height: height))
        }
        XCTAssertTrue(closed(466, 678), "upright")
        XCTAssertTrue(closed(678, 466), "landscape, where the screen's width class reads regular")
        XCTAssertFalse(closed(669, 951), "inner display, upright")
        XCTAssertFalse(closed(951, 669), "inner display, landscape")
        XCTAssertFalse(closed(466, 678, idiom: .pad))
        XCTAssertFalse(closed(440, 956), "the widest shipped iPhone")
        XCTAssertFalse(closed(956, 440), "the widest shipped iPhone, landscape")
    }

    func testTheTerminalReachesOnlyTheDisplayCornersItTouches() {
        func corners(
            division: CGRect? = nil,
            deck: Bool = true,
            size: CGSize = CGSize(width: 951, height: 669),
            ownsLeading: Bool = true,
            ownsTrailing: Bool = true
        ) -> ShellBottomCorners {
            SingleWindowShellNativeLayout.resolve(
                size: size,
                safeArea: .zero,
                verticalSizeClass: .regular,
                horizontalSizeClass: .regular,
                idiom: .phone,
                division: division,
                deckRailVisible: deck,
                compactShowsTerminal: true,
                compactBackSwipeOffset: 0,
                compactBackSwipeActive: false,
                foldable: true,
                ownsLeadingDisplayCorner: ownsLeading,
                ownsTrailingDisplayCorner: ownsTrailing
            ).terminalBottomCorners
        }
        XCTAssertEqual(corners(), .init(left: false, right: true), "beside the deck rail")
        XCTAssertEqual(corners(deck: false), .init(left: true, right: true), "deck hidden")
        let book = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        XCTAssertEqual(corners(division: book), .init(left: false, right: true), "the right-hand page")
        let portrait = CGSize(width: 669, height: 951)
        let laptop = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        XCTAssertEqual(corners(division: laptop, size: portrait), .init(), "above the fold")
        XCTAssertEqual(
            corners(division: laptop, deck: false, size: portrait),
            .init(left: true, right: true),
            "◧ HIDE hands the pane the whole display"
        )
        let half = CGSize(width: 475, height: 669)
        XCTAssertEqual(
            corners(size: half, ownsLeading: false),
            .init(left: false, right: true),
            "the Split View half on the right"
        )
        XCTAssertEqual(
            corners(deck: false, size: half, ownsTrailing: false),
            .init(left: true, right: false),
            "the Split View half on the left"
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
                 landscape: false, leading: 84, expected: .leading, note: "system edge wins on the closed display"),
            Case(system: .trailing, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, trailing: 84, expected: .trailing,
                 note: "Split View right-hand app: it owns the system column's strip"),
            Case(system: .leading, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, expected: .top, note: "Split View left-hand app: no strip, top rail"),
            Case(system: .trailing, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, expected: .top, note: "a reported edge without a strip keeps the top rail"),
            Case(system: .top, idiom: .phone, horizontal: .regular, vertical: .regular,
                 landscape: true, expected: .top, note: "an explicit system .top also wins"),
            Case(system: nil, idiom: .phone, horizontal: .regular, vertical: .compact,
                 landscape: true, expected: .top, note: "every shipped iPhone in landscape"),
            Case(system: nil, idiom: .phone, horizontal: .compact, vertical: .regular,
                 landscape: false, expected: .top, note: "every shipped iPhone in portrait"),
            Case(system: nil, idiom: .phone, horizontal: .regular, vertical: .regular,
                 landscape: true, leading: 84, expected: .leading, note: "Duo inner display, landscape"),
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
        XCTAssertFalse(SingleWindowShellBackSwipe.isAvailable(
            idiom: .phone,
            expanded: false,
            compactShowsTerminal: true,
            terminalFullScreen: true
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
