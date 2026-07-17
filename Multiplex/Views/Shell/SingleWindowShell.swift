import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Multiplex's real one-scene shell for iPhone and full-screen iPad. The deck
/// and terminal stage remain mounted together: compact navigation slides the
/// live terminal over the deck, while expanded layout exposes the same deck
/// as a one-session-wide rail. TerminalSessionController continues to own the
/// TerminalView, so back navigation, rail collapse, and width transitions do
/// not interrupt the shell or lose scrollback.
struct SingleWindowShell: View {
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var terminalRoute: TerminalWindowRoute
    @State private var compactShowsTerminal: Bool
    /// Keeps the first responder off the navigation's critical path. The
    /// first software-keyboard setup can synchronously occupy the main actor;
    /// the terminal should start moving before UIKit does that cold work.
    @State private var terminalFocusReady = true
    @State private var deckRailVisible = true
    /// Interactive position for the iPhone's right-swipe back gesture. The
    /// deck stays mounted beneath the terminal, so the swipe can reveal the
    /// real live wall without rebuilding either surface.
    @State private var compactBackSwipeOffset: CGFloat = 0
    @State private var compactBackSwipeActive = false

    private static let navigationResponse: TimeInterval = 0.3

    init(initialRoute: TerminalWindowRoute? = nil) {
        let route = initialRoute ?? TerminalWindowRoute(tabs: [])
        _terminalRoute = State(initialValue: route)
        _compactShowsTerminal = State(initialValue: !route.tabs.isEmpty)
    }

    var body: some View {
        GeometryReader { geometry in
            let safeArea = geometry.safeAreaInsets
            // A landscape phone insets both long edges by the Dynamic
            // Island's band. This reader stays inside them — an ignoring one
            // reports the edges it spans as zero — so the stack below spans
            // them explicitly and every pane is handed its own clearance.
            // The breakpoint keeps measuring the width panes can really use.
            let expanded = SingleWindowShellLayout.isExpanded(width: geometry.size.width)
            let fullWidth = geometry.size.width + safeArea.leading + safeArea.trailing
            // The rail carries its own leading clearance: the frame spans the
            // Island's band so the wall's chassis and rules reach the physical
            // edge, while FleetWall pads its content back out of it.
            let deckWidth = expanded
                ? (deckRailVisible
                    ? min(
                        SingleWindowShellLayout.deckRailWidth + safeArea.leading,
                        fullWidth
                    )
                    : 0)
                : fullWidth
            let terminalWidth = expanded
                ? max(0, fullWidth - deckWidth)
                : fullWidth
            // This reader is inset by whichever bottom region applies, so
            // adding it back always lands on the window's bottom edge —
            // keyboard or not. The deck's scroll viewport always wants that:
            // FleetWall restores the strip as content padding, so tiles pass
            // beneath the home indicator (and a docked keyboard) instead of
            // stopping short of it.
            let deckHeight = geometry.size.height + safeArea.bottom
            // Only a phone held in landscape — the one layout with a compact
            // vertical size class — is short enough to spend the home
            // indicator's strip on the key rail. Everywhere with room to
            // spare the rail keeps the standard clearance and the pane's
            // bezel simply paints through it. When the rail does take the
            // strip, SwiftTermView's container becomes the sole owner of
            // docked-keyboard clearance, exactly as in a classic window.
            let railTakesBottomStrip = verticalSizeClass == .compact
            let terminalHeight = geometry.size.height
                + (railTakesBottomStrip ? safeArea.bottom : 0)
            // Each pane keeps its content clear of the bands its own frame
            // spans — a hidden rail hands the Island's band to the terminal,
            // and a compact deck spans both. iOS reports both landscape edges
            // as unsafe without saying which one carries the Island, and the
            // Island sits mid-edge, over text rows: neither band is safe to
            // read in, so surfaces fill them and content stays out.
            let terminalOriginX = expanded ? deckWidth : 0
            let backSwipeOffset = expanded
                ? 0
                : SingleWindowShellBackSwipe.constrainedTranslation(
                    compactBackSwipeOffset,
                    width: fullWidth
                )

            ZStack(alignment: .topLeading) {
                deck(
                    expanded: expanded,
                    safeArea: EdgeInsets(
                        top: 0,
                        leading: safeArea.leading,
                        bottom: safeArea.bottom,
                        trailing: max(0, deckWidth - (fullWidth - safeArea.trailing))
                    )
                )
                    .frame(width: deckWidth, height: deckHeight)
                    .clipped()
                    .opacity(
                        expanded || !compactShowsTerminal || compactBackSwipeActive
                            ? 1
                            : 0
                    )
                    .allowsHitTesting(expanded ? deckRailVisible : !compactShowsTerminal)
                    .zIndex(0)

                terminalStage(
                    expanded: expanded,
                    availableWidth: terminalWidth
                        - max(0, safeArea.leading - terminalOriginX)
                        - safeArea.trailing,
                    contentSafeArea: EdgeInsets(
                        top: 0,
                        leading: max(0, safeArea.leading - terminalOriginX),
                        bottom: 0,
                        trailing: safeArea.trailing
                    ),
                    railOwnsBottomSafeArea: railTakesBottomStrip
                )
                    .frame(width: terminalWidth, height: terminalHeight)
                    .offset(x: expanded
                        ? deckWidth
                        : (compactShowsTerminal ? backSwipeOffset : fullWidth))
                    .opacity(expanded || compactShowsTerminal ? 1 : 0)
                    .allowsHitTesting(expanded || compactShowsTerminal)
                    .zIndex(1)

                if expanded, deckRailVisible {
                    Rectangle()
                        .fill(Theme.bezelHi)
                        .frame(width: 1, height: deckHeight)
                        .offset(x: deckWidth - 1)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
            }
            // Both panes are placed from the leading edge and the terminal
            // rides an `.offset`, which never claims width. The stack is
            // therefore narrower than the shell, and an unaligned frame
            // would center it — in landscape that pushed the deck inward and
            // ran the terminal off the screen's trailing edge.
            .frame(
                width: fullWidth,
                height: deckHeight,
                alignment: .topLeading
            )
            // Spend the safe areas rather than letting SwiftUI reserve them:
            // each pane fills its band with chassis and screen, and is handed
            // the inset back to spend on its own content — so what must stay
            // legible (tiles, chips, text) keeps clear of the Island and the
            // corners, while the deck's tiles scroll on through the bottom.
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            .background(Theme.chassis.ignoresSafeArea())
            .background {
                #if os(iOS)
                ShellBackSwipeRecognizer(
                    isEnabled: UIDevice.current.userInterfaceIdiom == .phone
                        && !expanded
                        && compactShowsTerminal,
                    onChanged: {
                        updateBackSwipe(translation: $0, width: fullWidth)
                    },
                    onEnded: { translation, velocity in
                        finishBackSwipe(
                            translation: translation,
                            velocity: velocity,
                            width: fullWidth
                        )
                    },
                    onCancelled: cancelBackSwipe
                )
                #endif
            }
            .animation(shellAnimation, value: compactShowsTerminal)
            .animation(shellAnimation, value: deckRailVisible)
            .animation(shellAnimation, value: expanded)
            .onChange(of: expanded) { _, isExpanded in
                if isExpanded {
                    resetBackSwipe()
                } else if !compactShowsTerminal {
                    releaseTerminalFocus()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active,
                      !expanded,
                      !compactShowsTerminal
                else { return }
                // UIKit may try to restore the still-mounted terminal's input
                // session as this scene foregrounds. The deck is frontmost,
                // so reassert the shell's no-terminal-focus invariant through
                // the controller/arbiter path.
                releaseTerminalFocus()
            }
        }
    }

    private func deck(
        expanded: Bool,
        safeArea: EdgeInsets
    ) -> some View {
        DeckWindow(
            terminalOpener: TerminalRouteOpener(
                destination: .shell,
                action: openTerminalRoute
            ),
            wallPresentation: expanded ? .shellRail : .shellCompact,
            selectedTerminal: terminalRoute.activeTab,
            shellSafeArea: safeArea
        )
    }

    @ViewBuilder
    private func terminalStage(
        expanded: Bool,
        availableWidth: CGFloat,
        contentSafeArea: EdgeInsets,
        railOwnsBottomSafeArea: Bool
    ) -> some View {
        if terminalRoute.tabs.isEmpty {
            emptyTerminal
        } else {
            TerminalWindowRoot(
                route: $terminalRoute,
                shell: .init(
                    deckControlLabel: expanded
                        ? (deckRailVisible ? "◧ HIDE" : "◧ DECK")
                        : "‹ DECK",
                    availableWidth: availableWidth,
                    contentSafeArea: contentSafeArea,
                    railOwnsBottomSafeArea: railOwnsBottomSafeArea,
                    showDeck: { showDeck(expanded: expanded) },
                    openTerminalRoute: openTerminalRoute,
                    revealTab: revealTab,
                    tabsEmptied: terminalTabsEmptied,
                    terminalFocusAllowed: (expanded || compactShowsTerminal)
                        && terminalFocusReady
                )
            )
        }
    }

    private var emptyTerminal: some View {
        ZStack {
            Theme.screen
            VStack(spacing: 10) {
                ChassisLabel("No terminal selected", size: 13, color: Theme.signal3)
                Text("Choose a session from the deck to attach it here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.signal2)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    private var shellAnimation: Animation? {
        reduceMotion
            ? nil
            : .spring(response: Self.navigationResponse, dampingFraction: 1)
    }

    /// Every incoming window route becomes tabs in this shell. AUTO_ATTACH
    /// `+` groups arrive as one route and comma-separated entries simply add
    /// to the same ordered tab list.
    private func openTerminalRoute(_ incoming: TerminalWindowRoute) {
        guard !incoming.tabs.isEmpty else { return }
        let isColdStart = terminalRoute.tabs.isEmpty
        if isColdStart { terminalFocusReady = false }
        resetBackSwipe()
        terminalRoute.merge(incoming.tabs)
        if let selected = incoming.activeTab?.id ?? incoming.tabs.first?.id {
            terminalRoute.activate(selected)
        }
        compactShowsTerminal = true
        focusAfterNavigation(
            tabID: terminalRoute.activeTabID,
            deferringColdStart: isColdStart
        )
    }

    /// TerminalWorkspace's existing press-to-focus lookup calls this reveal
    /// closure for an already-open session instead of creating a duplicate.
    private func revealTab(_ tabID: UUID) {
        resetBackSwipe()
        compactShowsTerminal = true
        focusAfterNavigation(tabID: tabID, deferringColdStart: false)
    }

    private func showDeck(expanded: Bool) {
        if expanded {
            deckRailVisible.toggle()
        } else {
            releaseTerminalFocus()
            resetBackSwipe()
            compactShowsTerminal = false
            // Cancel any still-pending cold-focus gate. Its delayed claim
            // sees the hidden stage and no-ops; a later warm reveal can focus
            // immediately, including after rotating into expanded layout.
            terminalFocusReady = true
        }
    }

    private func terminalTabsEmptied() {
        terminalFocusReady = true
        releaseTerminalFocus()
        resetBackSwipe()
        compactShowsTerminal = false
        deckRailVisible = true
    }

    /// A cold `becomeFirstResponder()` initializes TextInputUI and can block
    /// the main actor long enough to delay the shell's first rendered motion.
    /// Let the navigation spring get underway before asking for the keyboard.
    /// Warm returns only yield one run-loop turn, preserving their existing
    /// immediate focus behavior. Reduced Motion still gets one frame
    /// to commit the static stage change before keyboard setup begins.
    private func focusAfterNavigation(
        tabID: UUID?,
        deferringColdStart: Bool
    ) {
        guard let tabID else { return }
        let claim = {
            guard compactShowsTerminal,
                  terminalRoute.activeTabID == tabID
            else { return }
            terminalFocusReady = true
            workspace.controller(for: tabID)?.focusTerminal()
        }
        if deferringColdStart {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (reduceMotion ? 0.05 : Self.navigationResponse),
                execute: claim
            )
        } else {
            DispatchQueue.main.async(execute: claim)
        }
    }

    /// Tracks the terminal one-to-one with a directional rightward pan. Reduced
    /// Motion keeps the gesture as a navigation shortcut but removes the
    /// full-screen interactive travel.
    private func updateBackSwipe(translation: CGFloat, width: CGFloat) {
        guard !reduceMotion else { return }
        compactBackSwipeActive = true
        compactBackSwipeOffset = SingleWindowShellBackSwipe.constrainedTranslation(
            translation,
            width: width
        )
    }

    private func finishBackSwipe(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat
    ) {
        if SingleWindowShellBackSwipe.shouldReturnToDeck(
            translation: translation,
            velocity: velocity,
            width: width
        ) {
            showDeck(expanded: false)
        } else {
            cancelBackSwipe()
        }
    }

    private func cancelBackSwipe() {
        guard compactBackSwipeActive || compactBackSwipeOffset != 0 else { return }
        withAnimation(shellAnimation, completionCriteria: .removed) {
            compactBackSwipeOffset = 0
        } completion: {
            guard compactBackSwipeOffset == 0 else { return }
            compactBackSwipeActive = false
        }
    }

    private func resetBackSwipe() {
        compactBackSwipeOffset = 0
        compactBackSwipeActive = false
    }

    private func releaseTerminalFocus() {
        guard let tabID = terminalRoute.activeTab?.id else { return }
        workspace.controller(for: tabID)?.releaseFocus()
    }
}

#if os(iOS)
/// Installs a directional pan on the shell window so a right swipe can begin
/// anywhere in the terminal, including SwiftTerm's UIKit surface. The shell
/// pan gets first refusal only for horizontal movement; it fails immediately
/// for vertical intent and hands ordinary terminal scrolling back to SwiftTerm.
private struct ShellBackSwipeRecognizer: UIViewRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.update(
            isEnabled: isEnabled,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
        context.coordinator.attach(to: view.window)
    }

    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private var isEnabled: Bool
        private var onChanged: (CGFloat) -> Void
        private var onEnded: (CGFloat, CGFloat) -> Void
        private var onCancelled: () -> Void

        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleGesture(_:))
            )
            recognizer.minimumNumberOfTouches = 1
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            recognizer.isEnabled = isEnabled
            return recognizer
        }()

        init(
            isEnabled: Bool,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
            super.init()
        }

        func update(
            isEnabled: Bool,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
            if recognizer.isEnabled != isEnabled {
                recognizer.isEnabled = isEnabled
            }
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else { return }
            detach()
            guard let window else { return }
            window.addGestureRecognizer(recognizer)
            attachedWindow = window
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(recognizer)
            attachedWindow = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer
            else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
        }

        /// Let the horizontal shell navigation settle direction before a
        /// descendant terminal pan recognizes. If intent is vertical,
        /// `gestureRecognizerShouldBegin` fails and SwiftTerm receives the
        /// same accumulated touch stream rather than competing with it.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === recognizer
                && otherGestureRecognizer is UIPanGestureRecognizer
        }

        @objc private func handleGesture(_ recognizer: UIPanGestureRecognizer) {
            let translation = max(0, recognizer.translation(in: recognizer.view).x)
            switch recognizer.state {
            case .began, .changed:
                onChanged(translation)
            case .ended:
                onEnded(translation, recognizer.velocity(in: recognizer.view).x)
            case .cancelled, .failed:
                onCancelled()
            default:
                break
            }
        }
    }
}
#endif
