import os
import SwiftTerm
import UIKit

/// The real terminal pane surface. UIKit callers can construct and update it
/// directly. It owns the adopted `TerminalView`'s delegate, focus gesture,
/// platform chrome, constraints, keyboard avoidance, and visionOS link
/// overlay.
@MainActor
final class TerminalSurfaceView: UIView {
    struct Configuration {
        var fontSize: CGFloat
        var theme: TerminalTheme
        var bottomChromeHeight: CGFloat = 0
        var contentSafeArea: UIEdgeInsets = .zero
        /// `contentSafeArea` as the key rail reads it (iPhone Duo's closed
        /// display: the rail runs through the side strip).
        var keyRailSafeArea: UIEdgeInsets = .zero
        var railOwnsBottomSafeArea = false
        /// The key rail drops its bezel slab and top rule.
        var bareChrome = false
        /// Full screen: the key rail steps aside and the grid takes its rows.
        var keyRailHidden = false
        var isActive = true
        /// Which multiplexer owns the rail's shortcut key (TMUX/HRDR); nil
        /// drops the key — plain shells and auxiliary panes have no panel.
        var shortcutBackend: Host.SessionBackend?
        /// The session has several windows to switch between: the key lights.
        var shortcutHasChoices = false
        /// The tier's Key Commands cap and paywall route for the rail's
        /// hold-CTRL panel.
        var keyCommandPlan: KeyCommandPlan = .unrestricted
    }

    private static let focusTapName = "multiplex.focus-tap"
    private static let focusTouchName = "multiplex.focus-touch"
    // Keep a compact gutter around the terminal grid, but let tmux's status
    // line meet the helper/key rail directly—any bottom inset reads as an
    // accidental black seam between the two surfaces.
    private static let terminalInsets = UIEdgeInsets(
        top: 4,
        left: 6,
        bottom: 0,
        right: 6
    )

    let controller: TerminalSessionController
    /// The surface's own: keyboard avoidance, the grid's outer edges, and —
    /// on a tab with one emulator — that emulator's delegate. On a paned
    /// tab every pane has a coordinator of its own (`PaneCellView`) and this
    /// one only follows the pane the keyboard is on.
    private let coordinator: Coordinator
    private var configuration: Configuration
    /// A paned tab's emulators; nil on a tab that draws one.
    private(set) var paneSplitView: PaneSplitView?
    #if !os(visionOS)
    private weak var keyBar: TerminalKeyBar?
    #endif

    init(
        controller: TerminalSessionController,
        configuration: Configuration
    ) {
        self.controller = controller
        self.configuration = configuration
        coordinator = Coordinator(controller: controller, screen: controller.soleScreen)
        super.init(frame: .zero)
        // PROTOTYPE(GLASS): THIS wrapper carries the glass pane (theme
        // background at `screenAlpha`) — it spans the whole silhouette, so
        // the tint fills the compact gutter to the window border instead of
        // leaving a bare-smoke band around the inset grid (user report
        // 2026-08-02: "different border"). The grid's own layer goes clear.
        backgroundColor = GlassPrototype.terminalGround(
            themeBackground: UIColor(configuration.theme.background)
        )
        isOpaque = !GlassPrototype.enabled
        installTerminal()
        // PROTOTYPE(GLASS): a live GLASS⇄DARK switch re-applies the theme so
        // the fork's model ground follows the selection, not just the layer.
        registerForTraitChanges(
            [GlassAppearanceTrait.self]
        ) { (surface: TerminalSurfaceView, _: UITraitCollection) in
            for emulator in surface.emulators {
                surface.apply(surface.configuration.theme, to: emulator.view, emulator.coordinator)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Every emulator this surface still holds, with the coordinator that
    /// is its delegate. A moved tab's views may already belong to another
    /// window while this (about to be torn down) surface gets one last
    /// update; those are left out.
    private var emulators: [(view: TerminalView, coordinator: Coordinator)] {
        let all: [(view: TerminalView, coordinator: Coordinator)]
        if let paneSplitView {
            all = paneSplitView.cells.map { ($0.terminalView, $0.coordinator) }
        } else {
            all = coordinator.terminalView.map { [($0, coordinator)] } ?? []
        }
        return all.filter { $0.view.isDescendant(of: self) }
    }

    /// The emulator view for one of the tab's screens, ready to be placed:
    /// made — or adopted from the window the tab just left — themed, sized,
    /// and wired to `coordinator`.
    private func prepareTerminalView(
        for screen: TerminalScreen, coordinator: Coordinator
    ) -> TerminalView {
        let view: TerminalView
        if let existing = screen.terminalView {
            // This tab moved here from another window (merge/split): adopt
            // the live view so buffer, scrollback, and connection survive.
            // removeFromSuperview also drops constraints tied to the old
            // container before we pin it to the new one.
            existing.removeFromSuperview()
            view = existing
        } else {
            view = TerminalView(
                frame: .zero,
                font: .monospacedSystemFont(
                    ofSize: configuration.fontSize,
                    weight: .regular
                )
            )
            view.changeScrollback(controller.localScrollbackLines)
            // Use the standard keyboard so the user's selected language and
            // multistage IMEs remain available instead of forcing ASCII input.
            view.keyboardType = .default
            #if os(visionOS)
            // SwiftTerm still builds its stock accessory here even though
            // the floating visionOS keyboard never shows one — and that
            // invisible accessory's controlModifier shadows the view-level
            // latch the ornament key cluster sets (`terminalAccessory?.
            // controlModifier ?? controlModifier`). Drop it.
            view.inputAccessoryView = nil
            #else
            // Never attach Multiplex chrome as `inputAccessoryView` on iPad.
            // TextInputUI rehosts custom accessories while a Stage Manager
            // window moves, reactivating a floating keyboard every frame.
            // The UIKit container below renders the same TALLY controls as a
            // normal sibling view instead.
            view.inputAccessoryView = nil
            #endif
        }
        TerminalFocusArbiter.installScribbleGate(on: view)
        view.renderUpdatesEnabled = configuration.isActive
        apply(configuration.theme, to: view, coordinator)
        coordinator.preferredFontSize = configuration.fontSize
        // An adopted view showing another client's grid keeps the text
        // size that grid was fitted at; the first layout fits it here.
        if screen.gridPin == nil, view.font.pointSize != configuration.fontSize {
            view.font = .monospacedSystemFont(
                ofSize: configuration.fontSize,
                weight: .regular
            )
        }
        view.terminalDelegate = coordinator
        // Replace, never stack: an adopted view still carries the previous
        // window's sampler. The fork calls this on the feed thread, so hop
        // unconditionally — one path, and the sample is displayed at a ~5 s
        // cadence anyway.
        view.echoLatencySampleHandler = { [weak controller] milliseconds in
            Task { @MainActor in
                controller?.recordEchoSample(milliseconds: milliseconds)
            }
        }
        coordinator.terminalView = view

        // Tapping the terminal claims app-wide keyboard focus (and re-summons
        // a dismissed keyboard) — without cancelling SwiftTerm's own
        // selection/scroll gestures. An adopted view still carries the
        // recognizers wired to its previous window's coordinator — replace,
        // don't stack.
        view.gestureRecognizers?
            .filter { $0.name == Self.focusTapName || $0.name == Self.focusTouchName }
            .forEach(view.removeGestureRecognizer)
        let tap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.reclaimFocus(_:))
        )
        tap.name = Self.focusTapName
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        if screen.paneID != nil {
            // Among several panes the keyboard has to follow the finger
            // before a gesture resolves: a long press raises the selection
            // menu of whichever pane is the tab's active one.
            let touch = TouchDownGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.paneTouched(_:))
            )
            touch.name = Self.focusTouchName
            touch.cancelsTouchesInView = false
            touch.delaysTouchesBegan = false
            touch.delaysTouchesEnded = false
            touch.delegate = coordinator
            view.addGestureRecognizer(touch)
        }
        return view
    }

    #if os(visionOS)
    /// Gaze hover for links: the overlay is a subview of the terminal (its
    /// touches keep feeding the terminal's own pan recognizers) and survives
    /// merge/split with it — reuse the one already riding an adopted view
    /// rather than stacking another.
    private func installLinkHoverOverlay(
        on view: TerminalView, screen: TerminalScreen, coordinator: Coordinator
    ) {
        let overlay = view.subviews.compactMap { $0 as? TerminalLinkHoverOverlay }.first
            ?? {
                let created = TerminalLinkHoverOverlay(terminalView: view)
                view.addSubview(created)
                return created
            }()
        overlay.activate = { [weak controller] target in
            _ = controller?.activateLink(target)
        }
        coordinator.linkHoverOverlay = overlay
        screen.onOutputFlushed = { [weak overlay] in
            overlay?.scheduleRefresh()
        }
        overlay.scheduleRefresh()
    }
    #endif

    /// Experimental Metal renderer (visionOS scale + glass fixes live in
    /// the fork): a Settings toggle, default off, with MULTIPLEX_METAL=1
    /// as the harness/scheme override. Applied at install so a changed
    /// setting reaches new terminal windows and re-hosted (merge/split)
    /// tabs; setUseMetal early-returns when the state already matches.
    private func applyRendererSetting(to view: TerminalView) {
        let wantsMetal = MetalRendererSetting.isEnabled
        guard wantsMetal != view.isUsingMetalRenderer else { return }
        let log = Logger(
            subsystem: "app.multiplexterm.multiplex",
            category: "render"
        )
        do {
            try view.setUseMetal(wantsMetal)
            log.info("Metal renderer \(wantsMetal ? "enabled" : "disabled")")
        } catch {
            log.error("setUseMetal(\(wantsMetal)) failed: \(error)")
        }
    }

    /// One pane of a paned tab: its emulator, with a coordinator of its own.
    private func makePaneCell(for screen: TerminalScreen) -> PaneCellView {
        let paneCoordinator = Coordinator(controller: controller, screen: screen)
        let view = prepareTerminalView(for: screen, coordinator: paneCoordinator)
        let cell = PaneCellView(
            screen: screen, coordinator: paneCoordinator, terminalView: view)
        #if os(visionOS)
        installLinkHoverOverlay(on: view, screen: screen, coordinator: paneCoordinator)
        #endif
        applyRendererSetting(to: view)
        controller.bind(view, to: screen)
        // Replace, never stack: a moved tab's hook still names the pane
        // cell it left.
        screen.onGridPinChanged = { [weak paneCoordinator] in
            paneCoordinator?.applyGridPin(synchronously: true)
        }
        return cell
    }

    private func installTerminal() {
        // What sits in the grid's place: the one emulator, or the split of
        // a paned tab's. Everything below — the gutter, the rail, keyboard
        // avoidance — holds `content` and does not care which.
        let content: UIView
        let soleView: TerminalView?
        if controller.drawsPanes {
            let split = PaneSplitView(controller: controller) { [unowned self] screen in
                makePaneCell(for: screen)
            }
            paneSplitView = split
            content = split
            soleView = nil
        } else if let screen = controller.soleScreen {
            let view = prepareTerminalView(for: screen, coordinator: coordinator)
            content = view
            soleView = view
        } else {
            return
        }

        // On iPad, the app-owned rail is a normal sibling below the terminal.
        // Moving its bottom constraint above a genuinely docked keyboard
        // reflows the PTY once, while floating keyboards reserve nothing and
        // never enter TextInputUI's custom-accessory path. On visionOS the
        // keyboard floats in its own panel and never overlaps the window.
        #if os(visionOS)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        let terminalTrailing = content.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.terminalInsets.right
        )
        let terminalBottom = content.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -Self.terminalInsets.bottom
        )
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.terminalInsets.top
            ),
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.terminalInsets.left
            ),
            terminalTrailing,
            terminalBottom,
        ])
        coordinator.installGridEdges(trailing: terminalTrailing, bottom: terminalBottom)
        if let soleView, let screen = controller.soleScreen {
            installLinkHoverOverlay(on: soleView, screen: screen, coordinator: coordinator)
        }
        #else
        let keyBar = TerminalKeyBar(
            terminal: soleView,
            controller: controller,
            performShortcut: { [weak controller] item in
                controller?.performPanelShortcut(item)
            },
            finishTmuxCopyMode: { [weak controller] in
                controller?.finishTmuxCopyMode()
            },
            shortcutBackend: configuration.shortcutBackend
        )
        keyBar.contentSafeArea = configuration.keyRailSafeArea
        keyBar.spendsBottomStrip = configuration.railOwnsBottomSafeArea
        keyBar.bareChrome = configuration.bareChrome
        keyBar.keyCommandPlan = configuration.keyCommandPlan
        keyBar.shortcutHasChoices = configuration.shortcutHasChoices
        coordinator.keyBar = keyBar
        self.keyBar = keyBar
        addSubview(content)
        addSubview(keyBar)
        content.translatesAutoresizingMaskIntoConstraints = false
        keyBar.translatesAutoresizingMaskIntoConstraints = false
        let terminalTop = content.topAnchor.constraint(
            equalTo: topAnchor,
            constant: Self.terminalInsets.top
        )
        let keyBarBottom = keyBar.bottomAnchor.constraint(equalTo: bottomAnchor)
        let terminalBottom = content.bottomAnchor.constraint(
            equalTo: keyBar.topAnchor,
            constant: -(
                Self.terminalInsets.bottom + configuration.bottomChromeHeight
            )
        )
        // The container spans whatever side safe areas the shell handed it,
        // and the pane's screen paints across them. The grid does not: it
        // rides these constants back inside the readable region.
        let terminalLeading = content.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.terminalInsets.left + configuration.contentSafeArea.left
        )
        let terminalTrailing = content.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -(Self.terminalInsets.right + configuration.contentSafeArea.right)
        )
        // A docked keyboard lifts the rail by the measured overlap, and the
        // strip it vacates otherwise shows the terminal theme — under a light
        // theme the translucent system keyboard samples that near-white and
        // reads washed-out on dark chrome (user-reported). Continue the
        // rail's chassis down to the container edge instead, so the keyboard
        // always sits over appearance-correct hardware; its top rides the
        // rail's bottom anchor, so it is exactly the keyboard-covered band
        // and collapses to nothing when no keyboard docks.
        let keyBarHeight = keyBar.heightAnchor.constraint(
            equalToConstant: TerminalKeyBar.barHeight(
                spendsBottomStrip: configuration.railOwnsBottomSafeArea
            )
        )
        let keyboardBackfill = UIView()
        keyboardBackfill.backgroundColor = TallyPalette.bezel
        keyboardBackfill.isUserInteractionEnabled = false
        insertSubview(keyboardBackfill, belowSubview: keyBar)
        keyboardBackfill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalTop,
            terminalLeading,
            terminalTrailing,
            terminalBottom,
            keyBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyBarHeight,
            keyBarBottom,
            keyboardBackfill.topAnchor.constraint(equalTo: keyBar.bottomAnchor),
            keyboardBackfill.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardBackfill.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboardBackfill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        coordinator.installKeyboardAvoidance(
            container: self,
            constraint: keyBarBottom,
            terminalTopConstraint: terminalTop,
            terminalBottomConstraint: terminalBottom,
            terminalLeadingConstraint: terminalLeading,
            terminalTrailingConstraint: terminalTrailing
        )
        coordinator.installGridEdges(trailing: terminalTrailing, bottom: terminalBottom)
        coordinator.keyBarHeightConstraint = keyBarHeight
        coordinator.setRailOwnsBottomSafeArea(configuration.railOwnsBottomSafeArea)
        coordinator.setKeyRailHidden(configuration.keyRailHidden)
        #endif

        if let soleView, let screen = controller.soleScreen {
            applyRendererSetting(to: soleView)
            controller.bind(soleView, to: screen)
            // Replace, never stack: a moved tab's hook still names the pane
            // it left.
            screen.onGridPinChanged = { [weak coordinator] in
                coordinator?.applyGridPin(synchronously: true)
            }
            if configuration.isActive {
                DispatchQueue.main.async {
                    TerminalFocusArbiter.claim(soleView)
                }
            }
        } else {
            // Replace, never stack — as above. The controller calls this
            // the moment its transport says how the panes are arranged, and
            // reads each pane's grid as soon as it returns.
            controller.observePaneLayout(as: self) { [weak self] in
                self?.syncPanes(synchronously: true)
            }
            syncPanes(synchronously: false)
        }
    }

    /// Brings a paned tab's cells in line with its controller: the panes
    /// there are, where they sit, and which has the keyboard — the rail and
    /// keyboard avoidance follow that one.
    ///
    /// `synchronously` is for the controller's call: a new pane's terminal
    /// is opened at the grid its emulator measures, so the layout has to
    /// have happened when this returns.
    private func syncPanes(synchronously: Bool) {
        // A moved tab's surface in the window it left gets one last update;
        // the emulators are the new window's by then.
        guard let paneSplitView, controller.isPaneLayoutObserver(self) else { return }
        // Read before the cells change: the pane being left may be one
        // that is about to go.
        let previous = coordinator.terminalView
        let hadKeyboard = previous != nil && TerminalFocusArbiter.current === previous
        var active: TerminalView?
        paneSplitView.apply(
            layout: controller.paneLayout, screens: controller.screens,
            activePane: controller.activePaneID, zoomedPane: controller.zoomedPaneID,
            theme: configuration.theme
        ) { [self] in
            active = paneSplitView.cell(for: controller.activePaneID)?.terminalView
            // Before the claim: keyboard avoidance acts only on the
            // terminal the coordinator names, so the hide a resigning pane
            // reports is not acted on and the show its successor's is.
            coordinator.terminalView = active
            // The keyboard follows the tab's focus when the tab had it — a
            // split just made, a pane closed under the cursor, the tab
            // moved to another window's panes — and it moves HERE, while
            // the pane it is leaving is still in the window. Left until a
            // pane that was going had gone, the keyboard went with it and
            // came back a turn later, and the layout below measured the
            // panes without it: a new pane's terminal was opened 22 rows
            // too tall and its screen drawn into an emulator that had
            // shrunk back by then (measured: the top of the screen
            // scrolled away). A tab that did not have the keyboard does
            // not take it because its layout changed.
            if hadKeyboard, configuration.isActive, let active, active !== previous {
                TerminalFocusArbiter.claim(active)
            }
        }
        #if !os(visionOS)
        keyBar?.retarget(to: active)
        #endif
        if synchronously { layoutIfNeeded() }
        // The first pane an attach brings takes the keyboard a turn later,
        // as a single emulator does when its surface is installed.
        guard previous == nil, configuration.isActive, let active else { return }
        DispatchQueue.main.async { [weak controller] in
            guard controller?.terminalView === active else { return }
            TerminalFocusArbiter.claim(active)
        }
    }

    func update(configuration: Configuration) {
        self.configuration = configuration
        backgroundColor = GlassPrototype.terminalGround(
            themeBackground: UIColor(configuration.theme.background)
        )
        let emulators = emulators
        // A moved tab's view may already belong to another window while this
        // (about to be torn down) surface gets one last update.
        guard paneSplitView != nil || !emulators.isEmpty else { return }
        // Every emulator is updated; `contains` on a lazy map would stop at
        // the first whose font changed.
        let fontChanged = emulators
            .map { update($0.view, $0.coordinator, to: configuration) }
            .contains(true)
        #if !os(visionOS)
        coordinator.updateBottomChromeHeight(
            Self.terminalInsets.bottom + configuration.bottomChromeHeight
        )
        coordinator.updateContentSafeArea(configuration.contentSafeArea)
        coordinator.keyBar?.contentSafeArea = configuration.keyRailSafeArea
        coordinator.setRailOwnsBottomSafeArea(configuration.railOwnsBottomSafeArea)
        coordinator.setKeyRailHidden(configuration.keyRailHidden)
        coordinator.keyBar?.bareChrome = configuration.bareChrome
        coordinator.keyBar?.keyCommandPlan = configuration.keyCommandPlan
        coordinator.keyBar?.shortcutHasChoices = configuration.shortcutHasChoices
        if fontChanged {
            coordinator.terminalMetricsDidChange()
        }
        #endif
        syncPanes(synchronously: false)
    }

    /// One emulator's share of an update. Returns whether its font changed.
    private func update(
        _ view: TerminalView, _ coordinator: Coordinator, to configuration: Configuration
    ) -> Bool {
        if view.renderUpdatesEnabled != configuration.isActive {
            view.renderUpdatesEnabled = configuration.isActive
        }
        #if os(visionOS)
        // An obscured tab's links must not glow through the tab on screen.
        if let overlay = coordinator.linkHoverOverlay {
            if overlay.isHidden == configuration.isActive {
                overlay.isHidden = !configuration.isActive
                if configuration.isActive {
                    overlay.scheduleRefresh()
                } else {
                    overlay.clearRegions()
                }
            }
        }
        #endif
        // While the grid is another client's the text size is whatever
        // fits it; the tab's own size comes back with its own grid.
        let isPinned = coordinator.screen?.gridPin != nil
        let fontChanged = coordinator.preferredFontSize != configuration.fontSize
            || (!isPinned && view.font.pointSize != configuration.fontSize)
        coordinator.preferredFontSize = configuration.fontSize
        if fontChanged {
            if !isPinned {
                view.font = .monospacedSystemFont(
                    ofSize: configuration.fontSize,
                    weight: .regular
                )
            } else {
                coordinator.applyGridPin(synchronously: false)
            }
        }
        if coordinator.appliedTheme != configuration.theme {
            apply(configuration.theme, to: view, coordinator)
        } else if coordinator.appliedCaretVisible != (controller.status == .live) {
            // The pane re-runs this update on every observed status change,
            // which is where a connecting tab earns its caret back.
            applyCaretColor(theme: configuration.theme, to: view, coordinator)
        }
        return fontChanged
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if !os(visionOS)
        coordinator.containerDidLayout()
        #endif
        // The pane changed size under a grid that is not its own: fit again.
        // (A paned tab's cells each do this for themselves.)
        if paneSplitView == nil { coordinator.applyGridPin(synchronously: false) }
    }

    /// Colors change live — SwiftTerm's setters queue a full redraw, so an
    /// open session re-skins in place when the user switches themes.
    private func apply(
        _ theme: TerminalTheme, to view: TerminalView, _ coordinator: Coordinator
    ) {
        // PROTOTYPE(GLASS): keep the fork's own non-opaque invariant — cells
        // stay transparent (`nativeBackgroundColor = .clear` is exactly what
        // its setupOptions chose) and the pane ground lives on the view's
        // layer below, at `screenAlpha`, tinted by the selected theme.
        view.nativeBackgroundColor = GlassPrototype.terminalNativeGround(
            themeBackground: UIColor(theme.background)
        )
        view.nativeForegroundColor = UIColor(theme.foreground)
        applyCaretColor(theme: theme, to: view, coordinator)
        view.selectedTextBackgroundColor = UIColor(theme.cursor).withAlphaComponent(0.3)
        // SwiftTerm 1.15 adds an explicit selected-text foreground whose
        // upstream default is black. Preserve the theme's former text color,
        // especially for dark terminal surfaces.
        view.selectedTextForegroundColor = UIColor(theme.foreground)
        if theme.isValid {
            view.installColors(theme.ansi.map { color in
                SwiftTerm.Color(
                    red: UInt16(color.red) * 257,
                    green: UInt16(color.green) * 257,
                    blue: UInt16(color.blue) * 257
                )
            })
        }
        // PROTOTYPE(GLASS): the surface wrapper above carries the pane
        // tint edge-to-edge; the grid's own layer stays clear over it.
        view.backgroundColor = GlassPrototype.terminalWrapperGround(
            themeBackground: UIColor(theme.background)
        )
        // The keyboard belongs to the chassis, not the terminal surface:
        // `.default` follows the window's appearance (the Settings choice via
        // `overrideUserInterfaceStyle`), so a light terminal theme under dark
        // chrome keeps a dark keyboard — and vice versa (user-reported).
        view.keyboardAppearance = .default
        coordinator.appliedTheme = theme
    }

    /// The caret carries the theme's cursor color — tally red in the house
    /// themes — and SwiftTerm parks it at row 0 / column 0 while the screen is
    /// still empty. Over the CONNECTING panel that lone red glyph reads as a
    /// rendering fault, so the caret stays invisible until the tab's transport
    /// is actually live.
    private func applyCaretColor(
        theme: TerminalTheme, to view: TerminalView, _ coordinator: Coordinator
    ) {
        let visible = controller.status == .live
        view.caretColor = visible ? UIColor(theme.cursor) : .clear
        coordinator.appliedCaretVisible = visible
    }

    /// Forwards SwiftTerm delegate events to the session controller.
    /// SwiftTerm calls these on the main thread; `assumeIsolated` bridges
    /// into the controller's MainActor isolation.
    ///
    /// One per emulator: `screen` is the emulator's, and every event is
    /// forwarded with it, so the controller knows which pane spoke. The
    /// surface's own coordinator on a paned tab has no screen — it is
    /// nobody's delegate there, and only carries keyboard avoidance for the
    /// pane the keyboard is on (`terminalView`).
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let controller: TerminalSessionController
        let screen: TerminalScreen?
        weak var terminalView: TerminalView?
        #if os(visionOS)
        /// Gaze link regions — owned by the terminal view it floats over,
        /// referenced here for visibility gating and scroll refreshes.
        weak var linkHoverOverlay: TerminalLinkHoverOverlay?
        #endif
        var appliedTheme: TerminalTheme?
        /// Whether the last applied caret color was the theme's cursor (live)
        /// or clear. `nil` until the first application.
        var appliedCaretVisible: Bool?

        init(controller: TerminalSessionController, screen: TerminalScreen?) {
            self.controller = controller
            self.screen = screen
        }

        // MARK: Another client's grid (Rex)

        /// The tab's own text size — what the emulator goes back to when
        /// the grid is its own again.
        var preferredFontSize: CGFloat = 0
        /// The two edges a foreign grid pulls in, and where they rest
        /// without one. Everything else that moves these edges (bottom
        /// chrome, side safe areas) writes the resting value and calls
        /// `applyGridEdges`, so the two never overwrite each other.
        private var gridTrailingConstraint: NSLayoutConstraint?
        private var gridBottomConstraint: NSLayoutConstraint?
        private var restingTrailing: CGFloat = 0
        private var restingBottom: CGFloat = 0
        /// Room left beside and below a fitted grid (negative when even
        /// the smallest text cannot fit it and it runs off the pane).
        private var gridSlack = CGSize.zero
        /// What the current fit was solved for; an unchanged pane is not
        /// solved again on every layout pass.
        private var gridFitKey: GridFitKey?

        private struct GridFitKey: Equatable {
            var grid: TerminalGrid
            var available: CGSize
            var preferred: CGFloat
        }

        func installGridEdges(trailing: NSLayoutConstraint, bottom: NSLayoutConstraint) {
            gridTrailingConstraint = trailing
            gridBottomConstraint = bottom
            restingTrailing = trailing.constant
            restingBottom = bottom.constant
            gridSlack = .zero
            gridFitKey = nil
        }

        private func applyGridEdges() {
            let trailing = restingTrailing - gridSlack.width
            let bottom = restingBottom - gridSlack.height
            if gridTrailingConstraint?.constant != trailing {
                gridTrailingConstraint?.constant = trailing
            }
            if gridBottomConstraint?.constant != bottom {
                gridBottomConstraint?.constant = bottom
            }
        }

        /// Lays the emulator out at the grid of a terminal another client
        /// owns the size of (`TerminalScreen.gridPin`), or back at the
        /// pane's own.
        ///
        /// SwiftTerm measures its grid from its frame and its font, so the
        /// grid is given by giving it exactly that frame: the text shrinks
        /// until the grid fits the pane (`TerminalGridFit`), and the room
        /// left over is taken off the trailing and bottom edges. Nothing
        /// in the fork changes, and its frame-is-the-grid arithmetic —
        /// scrolling, hit testing, the caret — stays true.
        ///
        /// `synchronously` is for the controller's call: the screen that
        /// follows is drawn for this grid, so the grid has to be in place
        /// when it returns. From a layout pass it only asks for another.
        func applyGridPin(synchronously: Bool) {
            guard let view = terminalView, let container = view.superview,
                  gridTrailingConstraint != nil, preferredFontSize > 0
            else { return }
            func relayout() {
                if synchronously { container.layoutIfNeeded() } else { container.setNeedsLayout() }
            }
            func setFontSize(_ size: CGFloat) {
                guard abs(view.font.pointSize - size) > 0.01 else { return }
                view.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            }
            guard let grid = screen?.gridPin else {
                guard gridFitKey != nil || gridSlack != .zero else { return }
                gridFitKey = nil
                gridSlack = .zero
                setFontSize(preferredFontSize)
                applyGridEdges()
                relayout()
                return
            }
            if synchronously { container.layoutIfNeeded() }
            let available = CGSize(
                width: view.bounds.width + gridSlack.width,
                height: view.bounds.height + gridSlack.height)
            guard available.width > 0, available.height > 0 else { return }
            let key = GridFitKey(grid: grid, available: available, preferred: preferredFontSize)
            guard key != gridFitKey else { return }
            let scale = max(view.traitCollection.displayScale, 1)
            func cell() -> CGSize? {
                let dimensions = view.terminalDimensions
                guard dimensions.cols > 0, dimensions.rows > 0 else { return nil }
                let optimal = view.getOptimalFrameSize()
                return CGSize(
                    width: optimal.width / CGFloat(dimensions.cols),
                    height: optimal.height / CGFloat(dimensions.rows))
            }
            guard let measured = cell(), view.font.pointSize > 0 else { return }
            var size = TerminalGridFit.fontSize(
                for: grid, in: available,
                cellPerPoint: CGSize(
                    width: measured.width / view.font.pointSize,
                    height: measured.height / view.font.pointSize),
                preferred: preferredFontSize)
            setFontSize(size)
            // Cell size is only nearly linear in font size (it is snapped
            // to pixels): check the real cell and step down.
            while let fitted = cell(),
                  size > TerminalGridFit.minimumFontSize,
                  !TerminalGridFit.fits(grid, cell: fitted, in: available, displayScale: scale) {
                size = max(TerminalGridFit.minimumFontSize, size - 0.5)
                setFontSize(size)
            }
            guard let fitted = cell() else { return }
            let frame = TerminalGridFit.frameSize(for: grid, cell: fitted, displayScale: scale)
            gridSlack = CGSize(
                width: available.width - frame.width,
                height: available.height - frame.height)
            gridFitKey = key
            applyGridEdges()
            relayout()
        }

        #if !os(visionOS)
        weak var keyBar: TerminalKeyBar?
        private(set) var railOwnsBottomSafeArea = false
        private(set) var keyRailHidden = false
        var keyBarHeightConstraint: NSLayoutConstraint?
        private weak var avoidingContainer: UIView?
        private var bottomConstraint: NSLayoutConstraint?
        private var terminalTopConstraint: NSLayoutConstraint?
        private var terminalBottomConstraint: NSLayoutConstraint?
        private var terminalLeadingConstraint: NSLayoutConstraint?
        private var terminalTrailingConstraint: NSLayoutConstraint?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var keyboardPresentation: KeyboardAvoidance.Presentation = .hidden
        private var keyboardSettleWorkItems: [DispatchWorkItem] = []
        #if DEBUG
        private var keyboardLogSettleWorkItem: DispatchWorkItem?
        #endif
        /// Last *docked* keyboard end-frame (screen coords); floating frames
        /// are deliberately discarded. Kept so overlap can be re-measured
        /// when geometry — not the keyboard — changes after a docked event.
        private var lastKeyboardFrame: CGRect?

        deinit {
            for observer in keyboardObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            // Inlined `cancelKeyboardSettleRemeasures()`: SwiftTerm 2's
            // delegate protocol is @MainActor, so this coordinator is too,
            // and its nonisolated deinit may read storage but not call
            // isolated methods.
            for item in keyboardSettleWorkItems { item.cancel() }
            #if DEBUG
            keyboardLogSettleWorkItem?.cancel()
            #endif
        }

        /// Move the app-owned rail and terminal above a docked keyboard, and
        /// publish the same obstruction for the helper strip. Floating/split
        /// keyboards reserve nothing.
        func installKeyboardAvoidance(
            container: UIView,
            constraint: NSLayoutConstraint,
            terminalTopConstraint: NSLayoutConstraint,
            terminalBottomConstraint: NSLayoutConstraint,
            terminalLeadingConstraint: NSLayoutConstraint,
            terminalTrailingConstraint: NSLayoutConstraint
        ) {
            avoidingContainer = container
            bottomConstraint = constraint
            self.terminalTopConstraint = terminalTopConstraint
            self.terminalBottomConstraint = terminalBottomConstraint
            self.terminalLeadingConstraint = terminalLeadingConstraint
            self.terminalTrailingConstraint = terminalTrailingConstraint
            // didChangeFrame too: some presentations deliver their final
            // geometry (accessory attach, dock/float transitions) only in
            // the did- pass — reacting to will- alone under-insets and the
            // input row ends up behind the key rail. Repeated floating-frame
            // events are filtered by presentation state before they reach
            // layout, and docked settle work is coalesced.
            for name in [UIResponder.keyboardWillChangeFrameNotification,
                         UIResponder.keyboardDidChangeFrameNotification,
                         UIResponder.keyboardWillHideNotification,
                         UIResponder.keyboardDidHideNotification] {
                keyboardObservers.append(NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated {
                        self?.applyKeyboardFrame(notification)
                    }
                })
            }
        }

        /// Whether this pane reaches the window's bottom edge instead of the
        /// bottom safe area's. It moves with rotation on iPhone, and the rail
        /// grows its own chassis when it does, so keep the fact, the bar, and
        /// the height constraint in one place.
        func setRailOwnsBottomSafeArea(_ owns: Bool) {
            guard owns != railOwnsBottomSafeArea || keyBar?.spendsBottomStrip != owns
            else { return }
            railOwnsBottomSafeArea = owns
            keyBar?.spendsBottomStrip = owns
            applyKeyBarHeight()
        }

        /// Full screen folds the rail to nothing; the grid's bottom rides the
        /// rail's top, so it takes the rows in the same pass.
        func setKeyRailHidden(_ hidden: Bool) {
            guard hidden != keyRailHidden else { return }
            keyRailHidden = hidden
            if hidden { keyBar?.stepAside() }
            keyBar?.isHidden = hidden
            applyKeyBarHeight()
        }

        private func applyKeyBarHeight() {
            let height = TerminalKeyBar.barHeight(
                spendsBottomStrip: railOwnsBottomSafeArea,
                hidden: keyRailHidden
            )
            guard let constraint = keyBarHeightConstraint,
                  constraint.constant != height
            else { return }
            constraint.constant = height
            avoidingContainer?.layoutIfNeeded()
        }

        func updateBottomChromeHeight(_ height: CGFloat) {
            guard terminalBottomConstraint != nil, restingBottom != -height
            else { return }
            restingBottom = -height
            applyGridEdges()
            avoidingContainer?.layoutIfNeeded()
        }

        /// Rotating a phone moves the Island's band from one long edge to the
        /// other, and hiding the deck rail hands the leading band to this
        /// pane. Both change the grid's clearance without rebuilding it.
        func updateContentSafeArea(_ safeArea: UIEdgeInsets) {
            guard let leadingConstraint = terminalLeadingConstraint,
                  terminalTrailingConstraint != nil
            else { return }
            let leadingConstant = TerminalSurfaceView.terminalInsets.left
                + safeArea.left
            let trailingConstant = -(TerminalSurfaceView.terminalInsets.right
                + safeArea.right)
            guard leadingConstraint.constant != leadingConstant
                    || restingTrailing != trailingConstant
            else { return }
            leadingConstraint.constant = leadingConstant
            restingTrailing = trailingConstant
            applyGridEdges()
            avoidingContainer?.layoutIfNeeded()
        }

        func terminalMetricsDidChange() {
            avoidingContainer?.setNeedsLayout()
            avoidingContainer?.layoutIfNeeded()
        }

        /// SwiftTerm renders only whole rows from the top of its bounds. Move
        /// its measured fractional remainder into the existing top gutter so
        /// a tmux status line hugs the lower chrome. One physical pixel stays
        /// below the grid to keep the PTY safely in the same row-count bucket.
        private func alignTerminalGridTowardBottom() {
            guard controller.route.usesTmux,
                  let view = terminalView,
                  let topConstraint = terminalTopConstraint,
                  view.bounds.height > 0
            else { return }

            let baseTop = TerminalSurfaceView.terminalInsets.top
            let appliedNudge = max(0, topConstraint.constant - baseTop)
            let rawHeight = view.bounds.height + appliedNudge
            let rows = view.terminalDimensions.rows
            guard rows > 0 else { return }
            let cellHeight = view.getOptimalFrameSize().height / CGFloat(rows)
            guard cellHeight > 0 else { return }

            let scale = max(view.window?.screen.scale ?? UIScreen.main.scale, 1)
            let epsilon = 0.5 / scale
            let nudge = TerminalGridAlignment.bottomNudge(
                rawHeight: rawHeight,
                cellHeight: cellHeight,
                displayScale: scale
            )
            let targetTop = baseTop + nudge
            guard abs(topConstraint.constant - targetTop) > epsilon else { return }
            topConstraint.constant = targetTop
            // This method runs after `super.layoutSubviews()`. Ensure UIKit
            // resolves the new constraint even if the keyboard/window stops
            // moving immediately after the layout pass that changed it.
            avoidingContainer?.setNeedsLayout()
        }

        private func applyKeyboardFrame(_ notification: Notification) {
            guard notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool != false
            else { return }
            guard let container = avoidingContainer,
                  let window = container.window
            else { return }
            // Keyboard notifications are process-global. Only the terminal
            // that owns the app-wide input session may convert geometry or
            // touch constraints; hidden Stage Manager scenes otherwise do
            // the same work (and can race a transient UIScreen replacement).
            guard terminalView === TerminalFocusArbiter.current,
                  terminalView?.window === window
            else { return }

            let previousPresentation = keyboardPresentation
            let endFrame: CGRect?
            if notification.name == UIResponder.keyboardDidHideNotification {
                endFrame = nil
                keyboardPresentation = .hidden
            } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                endFrame = frame
                let screenSpace = window.screen.coordinateSpace
                keyboardPresentation = KeyboardAvoidance.presentation(
                    keyboard: frame,
                    screen: screenSpace.bounds
                )
            } else if notification.name == UIResponder.keyboardWillHideNotification {
                endFrame = nil
                keyboardPresentation = .hidden
            } else {
                return
            }

            lastKeyboardFrame = keyboardPresentation == .docked ? endFrame : nil

            // Stage Manager reports the floating keyboard as a zero-height
            // shortcut frame and can emit will-change, will-hide, then
            // did-change with that same geometry during one window move.
            // Classify the frame rather than treating will-hide as definitive;
            // repeated shortcut/floating events do no layout or timer work.
            guard KeyboardAvoidance.shouldReapplyFrameChange(
                from: previousPresentation,
                to: keyboardPresentation
            ) else {
                return
            }

            #if DEBUG
            logKeyboardDiagnostics(notification, container: container, window: window)
            #endif
            reapplyKeyboardLayout()

            // Stage Manager can keep moving the window after a real keyboard
            // transition. Keep the two proven settle points, but replace any
            // pending pair so a notification burst never fans out unbounded
            // main-thread layout work.
            if keyboardPresentation == .docked {
                scheduleKeyboardSettleRemeasures()
            } else {
                cancelKeyboardSettleRemeasures()
            }
        }

        private func scheduleKeyboardSettleRemeasures() {
            cancelKeyboardSettleRemeasures()
            for delay: TimeInterval in [0.35, 0.8] {
                let item = DispatchWorkItem { [weak self] in
                    self?.reapplyKeyboardLayout()
                }
                keyboardSettleWorkItems.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }

        private func cancelKeyboardSettleRemeasures() {
            for item in keyboardSettleWorkItems { item.cancel() }
            keyboardSettleWorkItems.removeAll()
        }

        /// Window movement causes layout passes even though a floating
        /// or short/flat keyboard frame has no effect on terminal geometry.
        /// Only a docked keyboard needs remeasurement as the window moves.
        func containerDidLayout() {
            alignTerminalGridTowardBottom()
            guard terminalView === TerminalFocusArbiter.current else { return }
            guard keyboardPresentation == .docked else { return }
            reapplyKeyboardLayout()
        }

        /// Recomputes rail clearance and `keyboardObstruction` from the last
        /// docked frame against the current window position. The helper value
        /// is measured against the window so its own content insets cannot
        /// feed back into the measurement.
        func reapplyKeyboardLayout() {
            guard let container = avoidingContainer,
                  let constraint = bottomConstraint,
                  let window = container.window,
                  terminalView === TerminalFocusArbiter.current,
                  terminalView?.window === window
            else { return }
            let screenSpace = window.screen.coordinateSpace
            let containerOnScreen = container.convert(container.bounds, to: screenSpace)
            let windowOnScreen = window.convert(window.bounds, to: screenSpace)
            // The helper's interactive content rests directly on the rail,
            // which rests on the window's bottom safe-area edge — or on the
            // window's edge itself where the shell hands its pane the home
            // indicator's strip. Either way the reference comes from the
            // window and a static fact about this pane, never from the
            // container's live frame: the strip's own padding would feed back.
            let restingBottom = windowOnScreen.maxY
                - (railOwnsBottomSafeArea ? 0 : window.safeAreaInsets.bottom)
            var overlap: CGFloat = 0
            var obstruction: CGFloat = 0
            if let endFrame = lastKeyboardFrame {
                if KeyboardAvoidance.isDocked(
                    keyboard: endFrame,
                    screen: screenSpace.bounds,
                    containerWidth: containerOnScreen.width
                ) {
                    let inContainer = container.convert(endFrame, from: screenSpace)
                    overlap = max(0, container.bounds.maxY - inContainer.minY)
                    obstruction = max(0, restingBottom - endFrame.minY)
                }
            }
            overlap = min(overlap, container.bounds.height * 0.8)
            obstruction = min(obstruction, window.bounds.height * 0.8)
            MainActor.assumeIsolated {
                controller.reportKeyboardObstruction(max(0, obstruction))
            }
            guard constraint.constant != -overlap else { return }
            constraint.constant = -overlap
            container.layoutIfNeeded()
        }

        #if DEBUG
        /// Diagnosis aid for keyboard-geometry bugs: dumps what the
        /// notification reported, what the classifier decided, and where
        /// UIKit put the container — read with
        /// `log show --predicate 'subsystem == "app.multiplexterm.multiplex"'`.
        private func logKeyboardDiagnostics(_ notification: Notification, container: UIView, window: UIWindow) {
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .null
            let screenSpace = window.screen.coordinateSpace
            let containerOnScreen = container.convert(container.bounds, to: screenSpace)
            let docked = KeyboardAvoidance.isDocked(
                keyboard: endFrame, screen: screenSpace.bounds, containerWidth: containerOnScreen.width
            )
            let logLine = { [weak self] (tag: String) in
                let onScreen = container.convert(container.bounds, to: screenSpace)
                Logger(subsystem: "app.multiplexterm.multiplex", category: "kbd").debug(
                    "\(tag, privacy: .public): \(notification.name.rawValue, privacy: .public) end=\(String(describing: endFrame), privacy: .public) docked=\(docked, privacy: .public) container=\(String(describing: onScreen), privacy: .public) obstruction=\(self?.controller.keyboardObstruction ?? 0, privacy: .public) safeBottom=\(container.safeAreaInsets.bottom, privacy: .public)"
                )
            }
            logLine("kbd-event")
            keyboardLogSettleWorkItem?.cancel()
            let item = DispatchWorkItem { logLine("kbd-settled") }
            keyboardLogSettleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }
        #endif
        #endif

        @objc func reclaimFocus(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? TerminalView else { return }
            if let pane = screen?.paneID {
                MainActor.assumeIsolated { controller.focusPane(pane) }
            }
            TerminalFocusArbiter.summon(view)
        }

        /// A finger came down on one pane of several. The tab's focus goes
        /// there at once; the keyboard goes with it only if the tab had it
        /// — a scroll through a pane does not summon a dismissed keyboard,
        /// the tap that `reclaimFocus` hears does.
        @objc func paneTouched(_ gesture: TouchDownGestureRecognizer) {
            guard gesture.state == .recognized,
                  let view = gesture.view as? TerminalView,
                  let pane = screen?.paneID
            else { return }
            MainActor.assumeIsolated {
                guard controller.activePaneID != pane else { return }
                let previous = controller.terminalView
                let hadKeyboard = previous != nil && TerminalFocusArbiter.current === previous
                controller.focusPane(pane)
                if hadKeyboard { TerminalFocusArbiter.claim(view) }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated {
                controller.sendInput(bytes, from: screen)
            }
        }

        /// The fork's second road (`sendTerminalReport`): what the emulator
        /// said by itself, kept apart from what a person did so the
        /// controller can decide whether this tab's far side wants it.
        func sendTerminalReport(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated {
                controller.sendTerminalReport(bytes, from: screen)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                controller.terminalResized(cols: newCols, rows: newRows, of: screen)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated {
                controller.terminalTitleChanged(title, from: screen)
            }
        }

        /// OSC 52 write. The remote naming the device clipboard is the
        /// mechanism `mpx bind --copy` rides (and tmux's own `set-clipboard`),
        /// so it stays — bounded, because the payload is remote bytes and a
        /// clipboard entry nobody can read back is not worth a megabyte.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard content.count <= Coordinator.maxClipboardWriteBytes,
                  let text = String(data: content, encoding: .utf8)
            else { return }
            UIPasteboard.general.string = text
        }

        /// OSC 52 read is deliberately unanswered. The query is pane output —
        /// any remote process that can print can send it — and answering it
        /// hands the device pasteboard (passwords, tokens, whatever was last
        /// copied) back over the wire with nothing on screen to show for it.
        /// Paste stays a user action: the key bar, the selection menu, and the
        /// system paste control all still work.
        func clipboardRead(source: TerminalView) -> Data? {
            nil
        }

        static let maxClipboardWriteBytes = 256 * 1024

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {
            #if os(visionOS)
            // Scrollback browsing moves links under fixed regions — re-place
            // them for the rows now visible.
            linkHoverOverlay?.scheduleRefresh()
            #endif
        }
        /// Only reached if the view's `linkActivationHandler` is ever absent —
        /// `bind` installs one. Kept wired so the two routes can't disagree.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            MainActor.assumeIsolated {
                _ = controller.activateLink(link)
            }
        }

        func bell(source: TerminalView) {
            MainActor.assumeIsolated {
                controller.bellRang()
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

extension TerminalView {
    /// True while the user is actively typing into this terminal — read from
    /// the fork's send-path input stamp, so every input road (IME commits, the key rail, kitty-encoded hardware
    /// keys, dictation chunks) counts, and none has to report separately.
    /// Chrome uses it to defer work that has no business running between
    /// keystrokes: the focused-pane agent probe and the gaze hover-region
    /// rebuild both wait for a quiet gap instead.
    func hasRecentUserInput(within window: Duration) -> Bool {
        let last = lastUserInputUptimeNanoseconds
        guard last > 0 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= last else { return false }
        let windowNs = UInt64(window / .nanoseconds(1))
        return now - last <= windowNs
    }
}
