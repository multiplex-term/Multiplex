//
//  iOSTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
//
//  The indicator "//X" means that this code was commented out from the Mac version for the sake of
//  porting and need to be audited.
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(iOS) || os(visionOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics
import GameController
import os
import SwiftUI
#if canImport(MetalKit)
import MetalKit
#endif

@available(iOS 14.0, *)
internal var log: Logger = Logger(subsystem: "org.tirania.SwiftTerm", category: "msg")

public extension Notification.Name {
    /// Posted when TerminalView's controlModifier is reset to false
    static let terminalViewControlModifierReset = Notification.Name("SwiftTerm.TerminalView.controlModifierReset")
    /// Posted when TerminalView's metaModifier is reset to false
    static let terminalViewMetaModifierReset = Notification.Name("SwiftTerm.TerminalView.metaModifierReset")
}

/**
 * TerminalView provides an AppKit/UIKit front-end to the `Terminal` terminal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 *
 * Developers might want to surface UIs for `optionAsMetaKey` which defaults to
 * true.  This means that Option-Letter is hijacked for terminal purposes
 * to send the sequence ESC-Letter.   Users can toggle this with command-option-o
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: UIScrollView, UITextInputTraits, UIKeyInput, UIScrollViewDelegate, TerminalDelegate, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    private enum PendingKoreanResyllabificationResult {
        case none
        case prefixReinserted
        case completed
    }

    public static var textInputDebugEnabled: Bool = ProcessInfo.processInfo.environment["SWIFTTERM_TEXT_INPUT_DEBUG"] == "1"
    internal static var textInputLogCounter: Int = 0

    // Multiplex patch: inactive tabs must keep parsing bytes so their buffer
    // and scrollback remain current, but they do not need UIKit invalidations,
    // cursor placement, or accessibility notifications while fully obscured.
    // The lock matters because feed() is allowed on a background thread.
    private let renderUpdatesLock = NSLock()
    private var _renderUpdatesEnabled = true
    public var renderUpdatesEnabled: Bool {
        get {
            renderUpdatesLock.lock()
            defer { renderUpdatesLock.unlock() }
            return _renderUpdatesEnabled
        }
        set {
            renderUpdatesLock.lock()
            let shouldRefresh = newValue && !_renderUpdatesEnabled
            _renderUpdatesEnabled = newValue
            renderUpdatesLock.unlock()
            guard shouldRefresh else { return }
            let refresh = { [weak self] in
                guard let self else { return }
                self.terminal.refresh(
                    startRow: 0,
                    endRow: max(0, self.terminal.rows - 1)
                )
                self.queuePendingDisplay()
            }
            if Thread.isMainThread {
                refresh()
            } else {
                DispatchQueue.main.async(execute: refresh)
            }
        }
    }

    struct FontSet {
        public let normal: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
        
        static var defaultFont: UIFont {
            UIFont.monospacedSystemFont (ofSize: 12, weight: .regular)
        }
        
        public init(font baseFont: UIFont) {
            self.normal = baseFont
            if let boldDescriptor = baseFont.fontDescriptor.withSymbolicTraits ([.traitBold]) {
                self.bold = UIFont (descriptor: boldDescriptor, size: 0)
            } else {
                self.bold = baseFont
            }
            
            if let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic]) {
                self.italic = UIFont (descriptor: italicDescriptor, size: 0)
            } else {
                self.italic = baseFont
            }
            
            if let boldItalicDescriptor = baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic, .traitBold]) {
                self.boldItalic = UIFont (descriptor: boldItalicDescriptor, size: 0)
            } else {
                if self.italic != baseFont {
                    self.boldItalic = self.italic
                } else if self.bold != baseFont {
                    self.boldItalic = self.bold
                } else {
                    self.boldItalic = baseFont
                }
            }
        }
        
        public init (normal: UIFont, bold: UIFont, italic: UIFont, boldItalic: UIFont) {
            self.normal = normal
            self.bold = bold
            self.italic = italic
            self.boldItalic = boldItalic
        }
        
        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return -1.2
        }
        
        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return 0.63
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var terminalDelegate: TerminalViewDelegate?

    /// Controls how the Metal renderer builds GPU buffers each frame.
    ///
    /// The default is ``MetalBufferingMode/perRowPersistent``, which caches
    /// per-row vertex data and only rebuilds dirty rows. Switch to
    /// ``MetalBufferingMode/perFrameAggregated`` for workloads that repaint
    /// most of the screen every frame.
    ///
    /// You can change this property at any time; the renderer picks up the
    /// new mode on the next frame.
    public var metalBufferingMode: MetalBufferingMode = .perRowPersistent
    
    /**
     * If set, and the the client application has requested mouse events to be sent, this will
     * send the events.   If this value if false, then a secondary codepath is enabled that will
     * always allow the selection or the scrolling/panning to take place, regardless of the
     * request from the client application.
     *
     * Additionally, during a pan operation if allowMouseReporting is false, then this turns
     * panning operations into sending cursor key commands.
     *
     * If a client application has not indicated any use for mouse events, then this setting
     * does not do anything, and selection and panning are still processed.
     */
    public var allowMouseReporting: Bool = true

    /// Controls how link tracking resolves hovered links:
    /// `.explicit` = OSC 8 only, `.implicit` = explicit + implicit fallback, `.none` = off.
    public var linkReporting: LinkReporting = .implicit

    /// Controls link highlighting and link activation behavior.
    public var linkHighlightMode: LinkHighlightMode = .hover {
        didSet {
            linkHighlightRange = nil
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }

    /// Multiplex patch: allow a resolved link to be activated without the
    /// pointer state `linkHighlightMode` demands. Touch never hovers, so a
    /// touch-only device could otherwise activate explicit OSC 8 links at
    /// best and implicit URLs never. This only affects activation — hover
    /// underlining still follows `linkHighlightMode`.
    public var linkActivationIgnoresHighlight = false

    /// Multiplex patch: app-owned policy for an activated link. Implicit
    /// detection matches filesystem paths (`./src/main.swift`, `/etc/hosts`)
    /// as readily as URLs, and those are everywhere in terminal output — a
    /// long press over one must still open the selection menu. Returning
    /// false declines the match and lets the gesture continue as if no link
    /// were there. Install with a weak capture: the view owns this closure.
    ///
    /// With no handler installed, upstream behavior stands: the delegate's
    /// `requestOpenLink` is called and the gesture is consumed.
    ///
    /// `rowTexts` is the implicit match split at its hard-wrap seams
    /// (empty for explicit links and single-row matches) — the app-side
    /// glue detector's evidence.
    ///
    /// `position` is the pressed cell in buffer coordinates (row includes
    /// the scrollback offset) — on a multiplexer's composited screen it
    /// names the pane under the finger, which the app needs to resolve a
    /// relative path against that pane's cwd rather than the active one's.
    public var linkActivationHandler: ((_ link: String, _ params: [String: String], _ rowTexts: [String], _ position: Position) -> Bool)?

    /// Multiplex patch: shared activation path for tap and long press.
    func activateLink(_ result: (link: String, params: [String: String], rowTexts: [String]), at position: Position) -> Bool
    {
        if let linkActivationHandler {
            return linkActivationHandler(result.link, result.params, result.rowTexts, position)
        }
        terminalDelegate?.requestOpenLink(source: self, link: result.link, params: result.params)
        return true
    }

    private var lastReportedLink: String?
    var commandActive = false
    private var activeCommandKeys: Set<UIKeyboardHIDUsage> = []
    private var pointerInteraction: UIPointerInteraction?
    private var hoverGesture: UIHoverGestureRecognizer?
    private var didFinishSetup = false
    var linkHighlightRange: [Terminal.LinkMatch.RowRange]?
    private var lastPointerLocation: CGPoint?
    private var lastMacSecondaryClickAt: TimeInterval = -.infinity
    
    /**
     * If set, this turns Option-letter keystrokes into an escape + keystroke combination
     * which is convenient when you are an Emacs user for example.   But this means that
     * international input using the option key is not easy to enter.
     */
    public var optionAsMetaKey = true
    
    /**
     * If set to true, this will call the TerminalViewDelegate's rangeChanged method
     * when there are changes that are being performed on the UI
     */
    public var notifyUpdateChanges = false

    /// If true, the caret view will show different shapes depending on the focus
    /// otherwise, it will behave like it is focused
    public var caretViewTracksFocus: Bool {
        get {
            return caretView?.tracksFocus ?? false
        }
        set {
            caretView?.tracksFocus = newValue
        }
    }
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: UIView?
    var pendingDisplay: Bool = false
    /// Output received shortly after local input is likely echo or prompt redraw;
    /// render it without the 16.67ms frame-rate throttle so typing feels responsive.
    var lastUserInputUptimeNs: UInt64 = 0
    /// Guards lastUserInputUptimeNs, which is written on the main thread and
    /// read from the (possibly background) feed thread.
    let userInputLock = NSLock()
    let interactiveInputDisplayWindowNs: UInt64 = 150_000_000
#if canImport(MetalKit)
    var metalView: MTKView?
    var metalRenderer: MetalTerminalRenderer?
    var pendingMetalDisplay: Bool = false
    private var useMetalRenderer = false
    var metalDirtyRange: ClosedRange<Int>?
    /// The cursor position last submitted to the Metal renderer. Used to
    /// detect pure cursor-only moves (no rows dirty) such as the
    /// CSI Ps C / CSI Ps D sequences shells emit in response to Option+Arrow
    /// word jumps, which would otherwise leave the cursor visually stuck
    /// because `MTKView` is paused and only redraws on demand.
    var lastRenderedCursor: (x: Int, y: Int, hidden: Bool)?

    /// Whether the terminal view is currently using the Metal GPU renderer.
    ///
    /// Returns `true` after a successful call to ``setUseMetal(_:)`` with
    /// `true`, and `false` otherwise.
    public var isUsingMetalRenderer: Bool {
        return useMetalRenderer
    }
#endif
    var cellDimension: CellDimension
    var caretView: CaretView?
    var _lineSpacing: CGFloat = 1.0
    var terminal: Terminal!
    // Multiplex patch: keep IME composition local in a floating label until
    // UIKit commits it; provisional marked text must never enter the PTY.
    var markedTextOverlay: UILabel?
    private var progressBarView: TerminalProgressBarView?
    private var progressReportTimer: Timer?
    private var lastProgressValue: UInt8?
    
    var selection: SelectionService!
    var attrStrBuffer: CircularList<ViewLineInfo>!
    var images:[(image: TerminalImage, col: Int, row: Int)] = []

    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]

    // Timer to display the terminal buffer
    var link: CADisplayLink!
    // Cache for the colors in the 0..255 range
    var colors: [UIColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:UIColor] = [:]
    var transparent = TTColor.transparent ()
    private var lastLayoutBounds: CGRect = .zero
    
    // UITextInput support starts
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer (textInput: self) // TerminalInputTokenizer()
    
    // We use this as temporary storage for UITextInput, which we send to the terminal on demand
    var textInputStorage: String = ""
    var pendingAutoPeriodDeleteWasSpace: Bool = false
    private var koreanResyllabificationTransaction = HangulInput.ResyllabificationTransaction()

    func resetKoreanResyllabificationTransaction() {
        koreanResyllabificationTransaction.reset()
    }

    // This tracks the marked text, part of the UITextInput protocol, which is used to flag temporary data entry, that might
    // be removed afterwards by the input system (input methods will insert approximiations, mark and change on demand)
    var _markedTextRange: TextRange?

    // The input delegate is part of UITextInput, and we notify it of changes.
    public weak var inputDelegate: UITextInputDelegate?

    // This tracks the selection in the textInputStorage, it is not the same as our global selection, it is temporary
    var _selectedTextRange: TextRange = TextRange(from: TextPosition(offset: 0), to: TextPosition(offset: 0))

    var _markedTextStyle: [NSAttributedString.Key: Any]?

    // Used for the keyboard long-press gesture that works as a cursor
    var lastFloatingCursorLocation: CGPoint?
    
    var fontSet: FontSet
    
    /// The font to use to render the terminal, this attempts to derive the bold, italic and italic/bold variants from
    /// the original font, using the iOS UIFontDescriptor APIs.   For full control use the `setFonts(normal:bold:italic:boldItalic)`
    /// API instead
    public var font: UIFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont()
            selectNone()
        }
    }
    
    /// Sets the various fonts to be used by the terminal to render text, their size is ignored
    /// - Parameters:
    ///  - normal: The font used by default for most text
    ///  - bold: The font used for bold text
    ///  - italic: The font used for italic text
    ///  - boldItalic: The font used for text that is both bold and italic.
    public func setFonts (normal: UIFont, bold: UIFont, italic: UIFont, boldItalic: UIFont) {
        fontSet = FontSet (normal: normal, bold: bold, italic: italic, boldItalic: boldItalic)
        resetFont ()
        selectNone ()
    }
    
    public init(frame: CGRect, font: UIFont?) {
        self.fontSet = FontSet (font: font ?? FontSet.defaultFont)
        cellDimension = CellDimension(width: 1, height: 1)
        super.init (frame: frame)
        isAccessibilityElement = true
        accessibilityTraits.formUnion([.staticText, .causesPageTurn])
        accessibilityTextualContext = .sourceCode
        setup()
    }
    
    public override init (frame: CGRect)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        cellDimension = CellDimension(width: 1, height: 1)
        super.init (frame: frame)
        isAccessibilityElement = true
        accessibilityTraits.formUnion([.staticText, .causesPageTurn])
        accessibilityTextualContext = .sourceCode
        setup()
    }
    
    public required init? (coder: NSCoder)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        cellDimension = CellDimension(width: 1, height: 1)
        super.init (coder: coder)
        setup()
    }
          
    func setup()
    {
        showsHorizontalScrollIndicator = true
        indicatorStyle = .white
        
        setupKeyboardButtonColors()
        setupDisplayUpdates ();
        setupOptions ()
        setupProgressBar()
        setupGestures ()
        setupLinkReportingInteractions()
        setupAccessoryView ()
        didFinishSetup = true
    }

    // Multiplex patch: a detached terminal has lost its input session
    // (transport/view teardown or tab reparenting), so discard its local composition.
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        // Multiplex patch: the shared menu cannot still belong to a view that
        // has left its window, so drop this view's record of it rather than
        // let it swallow the first tap after the tab comes back.
        contextMenuPresented = false
        guard _markedTextRange != nil || markedTextOverlay != nil else { return }
        resetInputBuffer()
    }

#if canImport(MetalKit)
    /// Enables or disables GPU-accelerated rendering via Metal.
    ///
    /// When enabled, the terminal view replaces its CoreGraphics rendering
    /// path with a Metal-based renderer that rasterizes glyphs into a
    /// texture atlas and draws cells as GPU quads. This can significantly
    /// reduce CPU usage for large or rapidly-updating terminals.
    ///
    /// Metal rendering is **disabled by default**. Call this method after
    /// the view has been added to a window:
    ///
    /// ```swift
    /// try terminalView.setUseMetal(true)
    /// ```
    ///
    /// You can switch back to CoreGraphics at any time by passing `false`.
    ///
    /// - Parameter enabled: Pass `true` to activate Metal rendering, or
    ///   `false` to revert to CoreGraphics.
    /// - Throws: ``MetalError`` if the Metal device or pipeline cannot be
    ///   initialized (for example, on hardware without Metal support).
    public func setUseMetal(_ enabled: Bool) throws {
        if enabled == useMetalRenderer {
            return
        }
        if enabled {
            try updateMetalRenderer(enabled: true)
            useMetalRenderer = true
        } else {
            try updateMetalRenderer(enabled: false)
            useMetalRenderer = false
        }
    }

    private func updateMetalRenderer(enabled: Bool) throws {
        if enabled {
            if metalView != nil {
                return
            }
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw MetalError.deviceUnavailable
            }
            let mtkView = MTKView(frame: bounds, device: device)
            mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            mtkView.framebufferOnly = true
            mtkView.colorPixelFormat = .bgra8Unorm
            mtkView.isUserInteractionEnabled = false
            // Multiplex patch: the terminal's ground is painted by the view's
            // layer (and, under the app's GLASS appearance, by live glass
            // behind a clear nativeBackgroundColor). The renderer clears to
            // nativeBackgroundColor including its alpha, so the Metal surface
            // must composite with alpha instead of the MTKView default opaque
            // black.
            mtkView.isOpaque = false
            mtkView.backgroundColor = .clear
            // Tag the metal layer with sRGB so the compositor color-manages our
            // pixels the same way as a regular UIView's layer. Without this,
            // CAMetalLayer is untagged and raw bytes are treated as
            // already-in-display-gamut, oversaturating colors on wide-gamut
            // displays.
            if let metalLayer = mtkView.layer as? CAMetalLayer {
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            }
            let renderer = try MetalTerminalRenderer(view: mtkView, terminalView: self)
            mtkView.delegate = renderer
            if let caretView = caretView {
                insertSubview(mtkView, belowSubview: caretView)
                caretView.disableAnimations()
                caretView.isHidden = true
            } else {
                addSubview(mtkView)
            }
            metalView = mtkView
            metalRenderer = renderer
            setNeedsDisplay(bounds)
            mtkView.setNeedsDisplay(mtkView.bounds)
        } else {
            metalView?.removeFromSuperview()
            metalView = nil
            metalRenderer = nil
            if let caretView = caretView {
                caretView.isHidden = false
                caretView.updateCursorStyle()
            }
            setNeedsDisplay(bounds)
        }
    }
#endif

    func setupDisplayUpdates ()
    {
        link = CADisplayLink(target: self, selector: #selector(step))
            
        link.add(to: .current, forMode: .default)
        suspendDisplayUpdates()
    }

    private func setupProgressBar() {
        let bar = TerminalProgressBarView(frame: .zero)
        bar.isHidden = true
        addSubview(bar)
        if #available(iOS 11.0, visionOS 1.0, *) {
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor),
                bar.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: 2)
            ])
        } else {
            bar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
            bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 2)
        }
        progressBarView = bar
    }

    private func resolveProgress(for report: Terminal.ProgressReport) -> UInt8? {
        switch report.state {
        case .remove:
            return nil
        case .set:
            return report.progress ?? 0
        case .error:
            return report.progress ?? lastProgressValue
        case .indeterminate:
            return nil
        case .pause:
            return report.progress ?? lastProgressValue ?? 100
        }
    }

    private func resetProgressReportTimer() {
        progressReportTimer?.invalidate()
        progressReportTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.clearProgressReport()
        }
    }

    private func clearProgressReport() {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
        lastProgressValue = nil
        progressBarView?.apply(state: .remove, progress: nil)
    }

    private func handleProgressReport(_ report: Terminal.ProgressReport) {
        if report.state == .remove {
            clearProgressReport()
            return
        }

        let resolvedProgress = resolveProgress(for: report)
        if let resolvedProgress {
            lastProgressValue = resolvedProgress
        }
        progressBarView?.apply(state: report.state, progress: resolvedProgress)
        resetProgressReportTimer()
    }
    
    @objc
    func step(displaylink: CADisplayLink) {
        updateDisplay()
    }

    func startDisplayUpdates()
    {
        link.isPaused = false
    }
    
    func suspendDisplayUpdates()
    {
        link.isPaused = true
    }
    
    public func updateUiClosed() {
        self.link.invalidate()
    }
    
    // Multiplex patch: UIKit hides the menu once one of its items runs, so each
    // action clears this view's record of it (`contextMenuPresented`). `select`
    // re-shows the menu for the word it just selected and re-sets the flag from
    // `showContextMenu`.
    @objc open override func paste (_ sender: Any?) {
        contextMenuPresented = false
        disableSelectionPanGesture()
        if let start = UIPasteboard.general.string {
            if terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteStart[0...])
            }
            send(txt: start)
            if terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteEnd[0...])
            }
            queuePendingDisplay()
        }
    }

    @objc open override func copy(_ sender: Any?) {
        contextMenuPresented = false
        UIPasteboard.general.string = selection.getSelectedText()
        selection.selectNone()
        disableSelectionPanGesture()
    }

    @objc open override func selectAll(_ sender: Any?) {
        contextMenuPresented = false
        selection.selectAll()
        enableSelectionPanGesture()
    }

    /// Invoked when the user has long-pressed and then clicked "Select"
    @objc public override func select (_ sender: Any?)  {
        contextMenuPresented = false
        if let loc = lastLongSelect {
            selection.selectWordOrExpression(at: Position (col: loc.col, row: loc.row), in: terminal.displayBuffer)
            selection.selectionMode = .character
            enableSelectionPanGesture()
            DispatchQueue.main.async {
                self.showContextMenu(forRegion:  self.makeContextMenuRegionForSelection(), pos: loc)
            }
            
        }
        lastLongSelect = nil
    }
    
    @objc func resetCmd(_ sender: Any?) {
        contextMenuPresented = false
        terminal.cmdReset()
        // Multiplex patch: terminal reset also resets UIKit's transient IME state
        // so no marked-text preview survives a rebuilt terminal view.
        resetInputBuffer()
        selection.selectNone()
        disableSelectionPanGesture()
        queuePendingDisplay()
    }

    @objc
    public override func canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return selection.active
        case #selector(paste(_:)):
            return true
        case #selector(select(_:)):
            return !selection.active
        case #selector(selectAll(_:)):
            return true
        case #selector(resetCmd(_:)):
            return true
        case #selector(consumeMacEscape(_:)):
            return ProcessInfo.processInfo.isiOSAppOnMac
        default:
            //print ("canPerformAction invoked for \(action)")
            return false
        }
    }
    
    /// Shows the context menu for the terminal, the arguments play a key role:
    /// - Parameters:
    ///  - region: This is the location that we want to avoid having the menu being shown
    ///  - pos: the location where this was triggered in the buffer, it used at a later point
    ///  to auto-select a word
    func showContextMenu (forRegion: CGRect, pos: Position) {
        // Multiplex patch: the app owns selection chrome — the deprecated
        // UIMenuController stays out of the picture entirely.
        if selectionUIHandler != nil {
            return
        }
        var items: [UIMenuItem] = []

        lastLongSelect = pos
        lastLongSelectRegion = forRegion
        // Multiplex patch: see `dismissLocalSelectionUI` — this view tracks its
        // own menu so a tap can dismiss one that no selection accompanies.
        contextMenuPresented = true

        //GAR: Declutter context menu
        //items.append (UIMenuItem(title: "Reset", action: #selector(resetCmd)))
        
        // Configure the shared menu controller
        let menuController = UIMenuController.shared
        menuController.menuItems = items
        
        // Set the location of the menu in the view.
        //let menuLocation = CGRect (origin: at, size: CGSize (width: cellDimension.width, height: cellDimension.height))
        menuController.showMenu(from: self, rect: forRegion)
    }
    
    // This is a position relative to the buffer
    var lastLongSelect: Position?
    var lastLongSelectRegion = CGRect.zero

    /// Multiplex patch: true while this view believes its selection context
    /// menu is on screen. Kept in step by `showContextMenu`/`hideContextMenu`
    /// and cleared by every menu action, so it can never outlive the menu and
    /// swallow a tap. See `dismissLocalSelectionUI`.
    var contextMenuPresented = false
    
    /// Creates a region suitable to be passed to the showContextMenu that wants a
    /// region for the menu to avoid.
    func makeContextMenuRegionForTap (point: CGPoint) -> CGRect {
        CGRect (origin: point, size: CGSize (width: cellDimension.width, height: cellDimension.height))
    }
                    
    func makeContextMenuRegionForSelection () -> CGRect {
        let width = selection.isMultiLine ? frame.width : CGFloat(selection.end.col-selection.start.col)*cellDimension.width
        
        return CGRect (x: CGFloat (selection.start.col)*cellDimension.width,
                       y: CGFloat (selection.start.row)*cellDimension.height,
                       width: width,
                       height: CGFloat (selection.end.row-selection.start.row+1)*cellDimension.height)
    }
    
    @objc func longPress (_ gestureRecognizer: UILongPressGestureRecognizer)
    {
         switch gestureRecognizer.state {
         case .began:
             // Multiplex patch: the app can claim a long press as the start of
             // a remote mouse drag (press + motion + release) for cells it
             // recognizes — a TUI multiplexer's pane-resize bar. Checked before
             // link activation and the selection menu; everything the filter
             // declines keeps the existing behavior.
             if !shiftBypassesMouseReporting(for: gestureRecognizer),
                beginRemoteMouseDrag(at: gestureRecognizer.location(in: self)) {
                 return
             }
             presentLocalPressActions(at: gestureRecognizer.location(in: self))
         case .changed:
             continueRemoteMouseDrag(at: gestureRecognizer.location(in: self))
         case .ended, .cancelled, .failed:
             endRemoteMouseDrag(at: gestureRecognizer.location(in: self))
         default:
             break
          }
    }

    /// Multiplex patch: the local action chain a long press runs, shared with
    /// a pointer's secondary click — the same "reach the local surface"
    /// intent said with a mouse. In select-text mode the press seeds the
    /// selection; otherwise a press over a link the app claims resolves it
    /// (a long press/right click is local at any mouse-tracking mode, so it
    /// is the one activation route that always reaches the user's intent);
    /// anywhere else raises the app's selection block, or legacy
    /// UIMenuController when no handler is installed.
    func presentLocalPressActions (at tapLocation: CGPoint) {
        let _ = self.becomeFirstResponder()
        let tapRegion = makeContextMenuRegionForTap (point: tapLocation)
        let hit = calculateTapHit (point: tapLocation).grid

        // With app-owned selection chrome a press is just a firmer tap —
        // seed the word selection (links wait until the mode ends;
        // selection is the whole point here).
        if selectionUIHandler != nil {
            _ = dismissAppMenu()
            seedAppSelection(at: hit)
            return
        }

        if let result = linkForClick(at: hit, hasCommandModifier: commandActive),
           activateLink(result, at: hit) {
            _ = dismissAppMenu()
            return
        }

        // Outside select-text mode the app's block replaces the
        // UIMenuController flow — another gesture elsewhere simply moves it.
        if presentSelectionMenu(at: tapLocation) {
            return
        }

        showContextMenu (forRegion: tapRegion, pos: hit)
    }

    /// Multiplex patch: raise the app-owned SELECT / SELECT ALL / PASTE
    /// block at a view coordinate. Long press and secondary click reach this
    /// after link resolution; a direct double tap reaches it deliberately
    /// without resolving a link, because that gesture expresses selection.
    /// Public so the app's headless hook can exercise the shared entry point.
    @discardableResult
    public func presentSelectionMenu (at tapLocation: CGPoint) -> Bool {
        guard let handler = selectionMenuHandler else { return false }
        handler(
            makeContextMenuRegionForTap(point: tapLocation),
            calculateTapHit(point: tapLocation).grid
        )
        return true
    }

    /// Multiplex patch: a mouse/trackpad secondary click runs the same local
    /// chain as a long press. Deliberately never a remote button-2 report —
    /// the block's MENU chip is the explicit road to a TUI's own right-click
    /// surface, and a silent remote report would make links unreachable by
    /// pointer under mouse tracking.
    @objc func secondaryClick (_ gestureRecognizer: UITapGestureRecognizer) {
        guard gestureRecognizer.state == .ended else { return }
        handleSecondaryClick(at: gestureRecognizer.location(in: self))
    }

    /// One secondary-click sink for UIKit's pointer recognizer and the Mac HID
    /// fallback. A physical click can reach both; the short gate makes that
    /// one local action regardless of callback order.
    private func handleSecondaryClick(at location: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        if ProcessInfo.processInfo.isiOSAppOnMac,
           now - lastMacSecondaryClickAt < Self.macSecondaryClickDedupWindow {
            return
        }
        lastMacSecondaryClickAt = now
        presentLocalPressActions(at: location)
    }

    /// Multiplex patch: when set, a long press over a cell this filter claims
    /// becomes a remote mouse drag instead of the selection menu. The filter
    /// receives the screen cell (zero-based, what the wire will report) and
    /// that cell's character, and must answer quickly — it runs at gesture
    /// time. Only consulted while the client requested button tracking
    /// (1002/1003), so a plain shell never loses its long press.
    public var longPressMouseDragFilter: ((_ cell: (col: Int, row: Int), _ content: Character?) -> Bool)?

    /// Multiplex patch: true between a claimed drag's press and its release.
    public var remoteMouseDragActive: Bool { mouseDragPressFlags != nil }

    private var mouseDragPressFlags: Int?
    private var mouseDragReleaseFlags = 0
    private var mouseDragLastCell: Position?

    /// Converts a point in view coordinates to the screen cell a mouse report
    /// should carry, clamped to the visible grid.
    private func remoteMouseDragCell (at point: CGPoint) -> (grid: Position, pixels: Position)? {
        guard let terminal else { return nil }
        let hit = calculateTapHit(point: point)
        guard let screen = hit.grid.toScreenCoordinate(from: terminal.displayBuffer) else { return nil }
        let clamped = Position(col: min (max (0, screen.col), terminal.cols-1),
                               row: min (max (0, screen.row), terminal.rows-1))
        return (clamped, hit.pixels)
    }

    /// Multiplex patch: begins a remote mouse drag at `point` if the filter
    /// claims that cell. Public so the app's DEBUG hooks can drive the exact
    /// gesture path headlessly. Returns true when the press was sent.
    @discardableResult
    public func beginRemoteMouseDrag (at point: CGPoint) -> Bool {
        guard let filter = longPressMouseDragFilter,
              allowMouseReporting,
              let terminal,
              terminal.mouseMode.sendButtonTracking(),
              !selection.active,
              !contextMenuPresented,
              mouseDragPressFlags == nil,
              let hit = remoteMouseDragCell(at: point)
        else { return false }
        guard filter((hit.grid.col, hit.grid.row),
                     terminal.getCharacter(col: hit.grid.col, row: hit.grid.row))
        else { return false }
        // Encode both flag values once at press time: encodeFlags clears the
        // app's CTRL latch as a side effect, and a drag's many motion samples
        // must all ride the modifiers the press carried.
        let control = terminalAccessory?.controlModifier ?? controlModifier
        let pressFlags = encodeFlags(release: false)
        mouseDragPressFlags = pressFlags
        mouseDragReleaseFlags = terminal.encodeButton(button: 0, release: true,
                                                      shift: false, meta: false, control: control)
        mouseDragLastCell = hit.grid
        terminal.sendEvent(buttonFlags: pressFlags, x: hit.grid.col, y: hit.grid.row,
                           pixelX: hit.pixels.col, pixelY: hit.pixels.row)
        return true
    }

    /// Multiplex patch: sends a motion report when the drag has moved to a new
    /// cell. Quantized to cells so a fast finger never floods the remote.
    public func continueRemoteMouseDrag (at point: CGPoint) {
        guard let pressFlags = mouseDragPressFlags,
              let terminal,
              let hit = remoteMouseDragCell(at: point),
              hit.grid != mouseDragLastCell
        else { return }
        mouseDragLastCell = hit.grid
        terminal.sendMotion(buttonFlags: pressFlags, x: hit.grid.col, y: hit.grid.row,
                            pixelX: hit.pixels.col, pixelY: hit.pixels.row)
    }

    /// Multiplex patch: the inverse of `calculateTapHit` for a visible screen
    /// cell — the view-coordinate center of that cell. What the app's DEBUG
    /// hooks stand on to drive the drag path headlessly (no headless route
    /// can synthesize a real touch).
    public func pointForCell (col: Int, row: Int) -> CGPoint {
        let bufferRow = CGFloat (row + (terminal?.displayBuffer.yDisp ?? 0))
        return CGPoint (x: (CGFloat (col) + 0.5) * cellDimension.width,
                        y: (bufferRow + 0.5) * cellDimension.height)
    }

    /// Multiplex patch: sends one right-button press + release report at the
    /// given buffer position — how the app's selection block reaches a TUI's
    /// own right-click surface (herdr's pane menu; no touch gesture maps to a
    /// right click). Sent only while the client reports mouse; returns
    /// whether the click went out.
    @discardableResult
    public func sendRemoteRightClick (atBufferPosition position: Position) -> Bool {
        guard allowMouseReporting,
              let terminal,
              terminal.mouseMode != .off,
              let screen = position.toScreenCoordinate(from: terminal.displayBuffer)
        else { return false }
        let col = min (max (0, screen.col), terminal.cols-1)
        let row = min (max (0, screen.row), terminal.rows-1)
        let point = pointForCell(col: col, row: row)
        let pixelX = Int (point.x)
        let pixelY = Int (point.y)
        let press = terminal.encodeButton(button: 2, release: false,
                                          shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: press, x: col, y: row, pixelX: pixelX, pixelY: pixelY)
        terminal.sendButtonReleaseEvent(button: 2, x: col, y: row, pixelX: pixelX, pixelY: pixelY)
        return true
    }

    /// Multiplex patch: the view-point flavor of the right-click send — what
    /// the app's DEBUG hooks stand on (no headless route can synthesize a
    /// real touch).
    @discardableResult
    public func sendRemoteRightClick (at point: CGPoint) -> Bool {
        guard let hit = remoteMouseDragCell(at: point), let terminal else { return false }
        let buffer = Position(col: hit.grid.col,
                              row: hit.grid.row + terminal.displayBuffer.yDisp)
        return sendRemoteRightClick(atBufferPosition: buffer)
    }

    /// Multiplex patch: releases an active drag at `point` (falling back to
    /// the last reported cell), always exactly once.
    public func endRemoteMouseDrag (at point: CGPoint? = nil) {
        guard mouseDragPressFlags != nil, let terminal else { return }
        let hit = point.flatMap { remoteMouseDragCell(at: $0) }
        let cell = hit?.grid ?? mouseDragLastCell ?? Position(col: 0, row: 0)
        let pixels = hit?.pixels ?? Position(col: 0, row: 0)
        terminal.sendEvent(buttonFlags: mouseDragReleaseFlags, x: cell.col, y: cell.row,
                           pixelX: pixels.col, pixelY: pixels.row)
        mouseDragPressFlags = nil
        mouseDragLastCell = nil
    }
    
    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false

    /// If this variable is set, this simulates the control key being pressed, it auto resets after we send data
    public var controlModifier: Bool = false {
        didSet {
            if oldValue && !controlModifier {
                NotificationCenter.default.post(name: .terminalViewControlModifierReset, object: self)
            }
        }
    }

    /// If this variable is set, this simulates the meta key being pressed, sending an esc before the text
    public var metaModifier: Bool = false {
        didSet {
            if oldValue && !metaModifier {
                NotificationCenter.default.post(name: .terminalViewMetaModifierReset, object: self)
            }
        }
    }

    /// Returns a buffer-relative position, instead of a screen position.
    /// - Parameters:
    ///   - gesture: the location of where the event took place
    /// - Returns: both the position where the event took place (either in screen resolution, or buffer relative) and the pixel position to construct the menu location
    func calculateTapHit (gesture: UIGestureRecognizer) -> (grid: Position, pixels: Position)
    {
        return calculateTapHit(point: gesture.location(in: self))
    }

    /// Returns a buffer-relative position, instead of a screen position.
    /// - Parameter point: location of where the event took place in view coordinates
    /// - Returns: both the position where the event took place (either in screen resolution, or buffer relative) and the pixel position to construct the menu location
    func calculateTapHit (point: CGPoint) -> (grid: Position, pixels: Position)
    {
        func toInt (_ p: CGPoint) -> Position {
            
            let x = min (max (p.x, 0), bounds.width)
            let y = min (max (p.y, 0), bounds.height)
            return Position (col: Int (x), row: Int (y))
        }

        let col = Int (point.x / cellDimension.width)
        let row = Int (point.y / cellDimension.height)
        if row < 0 {
            return (Position(col: 0, row: 0), toInt (point))
        }
        return (Position(col: min (max (0, col), terminal.cols-1), row: row), toInt (point))
    }

    func encodeFlags (release: Bool) -> Int
    {
        let encodedFlags = terminal.encodeButton(
            // Outpost patch: taps/drags are the primary (left) button. Upstream
            // hard-codes 1 (middle), so every tap arrives as a middle-click —
            // vim pastes, and left-click targets in TUIs never fire. 0 = left.
            button: 0,
            release: release,
            shift: false,
            meta: false,
            control: terminalAccessory?.controlModifier ?? controlModifier ?? false)
        terminalAccessory?.controlModifier = false
        controlModifier = false
        return encodedFlags
    }
    
    func sharedMouseEvent (gestureRecognizer: UIGestureRecognizer, release: Bool)
    {
        let hit = calculateTapHit(gesture: gestureRecognizer)
        if let grid = hit.grid.toScreenCoordinate(from: terminal.displayBuffer) {
            terminal.sendEvent(buttonFlags: encodeFlags (release: release), x: grid.col, y: grid.row, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
        }
    }
    
    // Returns the offsets into getTerminal().buffer.lines for the first visible and last visible lines
    func getVisibleLineRange () -> ClosedRange<Int> {
        let topVisibleLine = contentOffset.y/cellDimension.height
        let bottomVisibleLine = (topVisibleLine+frame.height/cellDimension.height)-1

        return Int(topVisibleLine)...Int(bottomVisibleLine)
    }
    
    public func repositionVisibleFrame () {
        let topVisibleLine = contentOffset.y/cellDimension.height
        let bottomVisibleLine = (topVisibleLine+frame.height/cellDimension.height)-1
        let lines = self.terminal.displayBuffer.lines.count
        contentOffset.y = max(0, CGFloat(lines) - bottomVisibleLine) * cellDimension.height
    }
    
    /// Returns true when the user is holding Shift on an attached hardware keyboard
    /// and the running application has not opted in to capturing shift via XTSHIFTESCAPE.
    /// In that case the gesture should fall through to local selection handling instead
    /// of being forwarded to the application as a mouse event.
    private func shiftBypassesMouseReporting(for gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.modifierFlags.contains(.shift) && !terminal.mouseShiftCapture
    }

    /// Multiplex patch: the selection highlight and its context menu are both
    /// app-side UI painted over the remote screen, so any tap while either is
    /// present dismisses them and is consumed — before link opening and before
    /// mouse reporting. Previously the dismissal only lived in singleTap's
    /// mouse-off branch: with mouse tracking on (tmux `mouse on`, CLI agents,
    /// vim) the tap was forwarded to the remote as a click and the highlight
    /// could never be cancelled by touch — and pans kept extending the
    /// selection, since an active selection owns the drag.
    ///
    /// The menu is tracked independently of `selection.active` because a long
    /// press opens PASTE / SELECT / SELECT ALL *without* selecting anything:
    /// guarding on the selection alone left that menu stuck on screen with no
    /// way to cancel it, unless the user pressed SELECT first (which finally
    /// made the guard true). Returns true when anything was dismissed.
    ///
    /// `contextMenuPresented` is this view's own record of having shown the
    /// menu, rather than `UIMenuController.isMenuVisible` alone: the whole
    /// controller is deprecated since iOS 16 and only its `hideMenu()` is
    /// exercised on a path known to work here, so the query is kept as a
    /// second opinion and never as the sole authority.
    @discardableResult
    func dismissLocalSelectionUI () -> Bool {
        // Multiplex patch: the app's selection block obeys the same contract
        // as the native menu — a tap anywhere dismisses it and is consumed.
        if dismissAppMenu() {
            return true
        }
        guard selection.active || contextMenuPresented || UIMenuController.shared.isMenuVisible
        else { return false }
        if selection.active {
            selection.selectNone()
            disableSelectionPanGesture()
        }
        hideContextMenu()
        queuePendingDisplay()
        return true
    }

    /// Multiplex patch: hides the selection menu and clears this view's record
    /// of it. Call instead of `UIMenuController.hideMenu()` so the record can
    /// never outlive the menu and swallow a later tap.
    func hideContextMenu () {
        contextMenuPresented = false
        // Unconditional: `isMenuVisible` is the untrusted half of the pair, so
        // gating the hide on it would put it back in charge. `hideMenu()` on
        // an already-hidden menu is a no-op.
        UIMenuController.shared.hideMenu()
    }

    @objc func singleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }

        if gestureRecognizer.state != .ended {
            return
        }

        // Multiplex patch: while the app owns selection chrome, a tap seeds
        // a word selection right where it lands — no PASTE/SELECT menu
        // detour, and no dismiss-then-retap dance (re-tapping simply
        // re-anchors). Links and mouse reporting are out of the picture in
        // that state by construction.
        if selectionUIHandler != nil {
            if !isFirstResponder {
                let _ = becomeFirstResponder()
            }
            // A lingering selection block from before the mode started goes
            // away with the tap; the seed still happens.
            _ = dismissAppMenu()
            seedAppSelection(at: calculateTapHit(gesture: gestureRecognizer).grid)
            return
        }

        // Multiplex patch: the cancel tap also works while the terminal is
        // not first responder (keyboard dismissed) — it dismisses and
        // refocuses in one tap instead of needing a second one.
        if dismissLocalSelectionUI() {
            if !isFirstResponder {
                let _ = becomeFirstResponder()
            }
            return
        }

        if isFirstResponder {
            let tapHit = calculateTapHit(gesture: gestureRecognizer).grid
            // Multiplex patch: a tap belongs to the remote whenever the client
            // asked for mouse tracking. Upstream resolves links first, which
            // means any URL-shaped text under the finger silently swallows the
            // click — tmux `mouse on` (this app's default) stops switching
            // panes there, and vim stops placing the cursor. Long press is the
            // link route in that state; see `longPress`.
            let remoteWantsTap = allowMouseReporting
                && !shiftBypassesMouseReporting(for: gestureRecognizer)
                && terminal.mouseMode.sendButtonPress()
            if !remoteWantsTap,
               let result = linkForClick(at: tapHit, hasCommandModifier: commandActive),
               activateLink(result, at: tapHit) {
                return
            }

            if allowMouseReporting && !shiftBypassesMouseReporting(for: gestureRecognizer) && terminal.mouseMode.sendButtonPress() {
                sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)

                if terminal.mouseMode.sendButtonRelease() {
                    sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
                }
            } else {
                // Multiplex patch: upstream's "menu visible → hide it" arm
                // lived here, reachable only with mouse reporting off and the
                // terminal already first responder. `dismissLocalSelectionUI`
                // above now owns that dismissal at every mouse mode, so only
                // the show arm remains.
                let location = gestureRecognizer.location(in: gestureRecognizer.view)
                let tapLoc = calculateTapHit(gesture: gestureRecognizer).grid
                let displayBuffer = terminal.displayBuffer
                let cursorRow = displayBuffer.y + displayBuffer.yDisp
                if abs (tapLoc.col-displayBuffer.x) < 4 && abs (tapLoc.row - cursorRow) < 2 {
                    showContextMenu (forRegion: makeContextMenuRegionForTap (point: location), pos: tapLoc)
                }
            }
            queuePendingDisplay()
        } else {
            let _ = becomeFirstResponder ()
        }
    }
    
    @objc func doubleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }

        if gestureRecognizer.state != .ended {
            return
        }

        if allowMouseReporting && !shiftBypassesMouseReporting(for: gestureRecognizer) && terminal.mouseMode.sendButtonPress() {
            // Multiplex patch: a double tap — finger, Pencil, visionOS
            // gaze/pinch, or a pointer's double-click — is an additive route
            // to the app-owned selection block. The single recognizer has
            // already sent both physical clicks to the remote immediately —
            // preserving the no-latency contract — and this recognizer must
            // not add a third.
            if localDoubleTapOpensSelectionMenu(gestureRecognizer) {
                _ = dismissLocalSelectionUI()
                _ = presentSelectionMenu(at: gestureRecognizer.location(in: self))
                return
            }
            // A fast re-tap on an active selection or its menu must dismiss
            // that UI, never add another remote click.
            if dismissLocalSelectionUI() {
                return
            }
            if remoteOwnsImmediateTaps(for: gestureRecognizer) {
                return
            }
            sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)

            if terminal.mouseMode.sendButtonRelease() {
                sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
            }
            return
        } else {
            let hit = calculateTapHit(gesture: gestureRecognizer).grid
            selection.selectWordOrExpression(at: hit, in: terminal.displayBuffer)
            selection.selectionMode = .character
            enableSelectionPanGesture()
            showContextMenu (forRegion: makeContextMenuRegionForSelection(), pos: hit)
            queuePendingDisplay()
        }
    }

    @objc func tripleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }

        if gestureRecognizer.state != .ended {
            return
        }

        if allowMouseReporting && !shiftBypassesMouseReporting(for: gestureRecognizer) && terminal.mouseMode.sendButtonPress() {
            // Multiplex patch: same dismissal rule as singleTap/doubleTap.
            if dismissLocalSelectionUI() {
                return
            }
            // Multiplex patch: same no-extra-click rule as doubleTap while
            // the failure chain is bypassed.
            if remoteOwnsImmediateTaps(for: gestureRecognizer) {
                return
            }
            sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)

            if terminal.mouseMode.sendButtonRelease() {
                sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
            }
            return
        } else {
            let hit = calculateTapHit(gesture: gestureRecognizer).grid
            selection.select(row: hit.row)
            enableSelectionPanGesture()
            showContextMenu (forRegion: makeContextMenuRegionForSelection(), pos: hit)
            queuePendingDisplay()
        }
    }
    
    var directionView: UIView?
    var directionCount: Int = 0
    var lastCursorImage: String? = nil
    func createDirectionView () -> UIView {
        let timeout = 0.5
        if directionView == nil {
            let w = 80
            let h = 80
            let f = frame
            directionView = UIView (
                frame: CGRect (x: (Int (f.width)-w)/2,
                               y: (Int(f.height)-w)/2,
                               width: w,
                               height: h))
            addSubview(directionView!)
        }
        let dv = directionView!
        dv.backgroundColor = UIColor.gray
        dv.alpha = 0.5
        
        directionCount += 1
        DispatchQueue.main.asyncAfter (deadline: .now() + timeout) {
            self.directionCount -= 1
            if self.directionCount == 0 {
                if let dv = self.directionView {
                    self.directionView = nil
                    UIView.animate(withDuration: 0.3, animations: {
                        dv.alpha = 0
                    }, completion: { x in
                        dv.removeFromSuperview()
                    })
                }
            }
        }
        return dv
    }
    
    func sendKey (deltaCol: Int, deltaRow: Int) {
        if deltaCol == 0 && deltaRow == 0 { return }
        let host = createDirectionView()
        var imgName: String? = nil
        if deltaRow > 0 {
            imgName = "arrow.up.square.fill"
            sendKeyUp()
        } else if deltaRow < 0 {
            imgName = "arrow.down.square.fill"
            sendKeyDown()
        }
        if deltaCol > 0 {
            imgName = "arrow.left.square.fill"
            sendKeyLeft()
        } else if deltaCol < 0 {
            imgName = "arrow.right.square.fill"
            sendKeyRight()
        }
        if imgName == nil {
            print ("What?")
        }
        guard let name = imgName else { return }

        if lastCursorImage == name { return }
        guard let img = UIImage(systemName: name) else { return }
        lastCursorImage = name
        if let child = host.subviews.first {
            child.removeFromSuperview()
        }

        let imgView = UIImageView (image: img)
        host.addSubview (imgView)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.center = host.center
        imgView.topAnchor.constraint(equalTo: host.topAnchor, constant: 0).isActive = true
        imgView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 0).isActive = true
        imgView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: 0).isActive = true
        imgView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: 0).isActive = true
        imgView.tintColor = .white
    }
    
    // Multiplex patch: a pan used to be reported as a click-drag (press +
    // motion + release), which in tmux starts a copy-mode selection and
    // never scrolls; and with mouse reporting off there was no way to reach
    // an alternate-screen app's own scrollback at all. Touch has one scroll
    // gesture, so the pan now scrolls the *remote*: wheel reports when the
    // client asked for mouse events, cursor keys ("alternate scroll") when
    // the alternate buffer is active without mouse tracking, or while the
    // host app explicitly presents a remote copy-mode surface. The primary
    // buffer otherwise keeps native local scrollback.
    var remoteScrollResidual: CGFloat = 0

    // Multiplex patch: wheel reports are pinned to the pan's START location.
    // A pan's live location moves with the drag (on visionOS it is the gaze
    // hit at pinch time plus the hand's unbounded translation), so a long
    // scroll walks the reported coordinate off the content and the row clamp
    // pins it to row 0 — herdr's tab bar, where a wheel event switches tabs.
    // Desktop wheel semantics scroll the point under the pointer at gesture
    // start; anchoring restores that.
    var remoteScrollAnchor: CGPoint?

    /// Multiplex patch: an app-owned tmux copy-mode HUD disables mouse
    /// reporting so UIKit can select text locally, but tmux may still render
    /// in the primary buffer. In that narrow state, keep pans remote by
    /// translating them to cursor keys. Selection drags continue to win in
    /// `RemoteScrollGestureGate` below.
    public var forceRemoteCursorScroll: Bool = false {
        didSet {
            guard forceRemoteCursorScroll != oldValue else { return }
            updateRemotePanGesture()
        }
    }

    /// Multiplex patch: constrain local selection to one multiplexer pane.
    /// The app sets the focused pane's screen rectangle while its
    /// select-text mode runs, so taps, drags, and Select All operate on the
    /// pane instead of the whole screen (a split's neighbor pane must not
    /// bleed into a selection). Rows/columns are screen cells, both ends
    /// inclusive. A live selection is pulled into the new rectangle rather
    /// than dropped — the clamp arrives asynchronously, and a Select All
    /// taken meanwhile should tighten to the pane, not vanish.
    public var selectionClampRect: (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        get { selection.clampRect }
        set {
            selection.clampRect = newValue
            selection.reclampActiveSelection()
            queuePendingDisplay()
        }
    }

    /// Multiplex patch: while set, the APP owns selection chrome. The
    /// deprecated UIMenuController never shows (`showContextMenu` no-ops),
    /// a plain tap or long press seeds a word selection directly — no
    /// PASTE/SELECT menu detour — and every selection change reports the
    /// selection's CONTENT-coordinate rectangle (`selectionUIRect`; nil
    /// when the selection clears) so the app can float its own actions
    /// beside it as sibling subviews. Set only while the app's
    /// select-text mode runs; nil restores the stock UIKit selection flow.
    public var selectionUIHandler: ((CGRect?) -> Void)?

    /// Multiplex patch: the app's replacement for the selection context menu
    /// OUTSIDE select-text mode. A long press / secondary click that does not
    /// activate a link, or a direct double tap, reports its screen region and
    /// buffer position here instead of showing deprecated UIMenuController —
    /// the app draws its own SELECT / SELECT ALL / PASTE block there.
    public var selectionMenuHandler: ((CGRect, Position) -> Void)?

    /// Multiplex patch: set by the app while its selection block is on
    /// screen. A tap dismisses-and-consumes exactly like the native menu
    /// (`dismissLocalSelectionUI` calls and clears it); the app also clears
    /// it whenever it hides the block itself.
    public var appMenuDismiss: (() -> Void)?

    /// Multiplex patch: run-and-clear the app's menu dismissal, answering
    /// whether anything was dismissed.
    private func dismissAppMenu () -> Bool {
        guard let dismiss = appMenuDismiss else { return false }
        appMenuDismiss = nil
        dismiss()
        return true
    }

    /// Multiplex patch: the app's SELECT action — seed a word selection at
    /// the position its selection block recorded, exactly like an in-mode
    /// tap.
    public func seedWordSelection (atBufferPosition position: Position) {
        seedAppSelection(at: position)
    }

    /// Multiplex patch: the active selection's bounding box in CONTENT
    /// coordinates (the scroll view's own space — what subview frames use),
    /// clipped to the visible rows; nil when fully off-screen. A displayed
    /// buffer row's content y is simply its absolute row × cell height, so
    /// the visibility test converts through `yDisp` but the rect must NOT —
    /// subtracting it anchored the HUD a whole content-offset short (one
    /// keyboard height per stranded frame on mosh tabs, reported
    /// 2026-08-10). Multi-row widths honor `selectionClampRect` so the box
    /// hugs the pane the selection lives in.
    public func selectionUIRect () -> CGRect? {
        guard let terminal, selection.active, selection.hasSelectionRange else { return nil }
        let (first, last) = Position.compare(selection.start, selection.end) == .before
            ? (selection.start, selection.end)
            : (selection.end, selection.start)
        let yDisp = terminal.displayBuffer.yDisp
        let startRow = first.row - yDisp
        let endRow = last.row - yDisp
        guard endRow >= 0, startRow < terminal.rows else { return nil }
        let cols: (lo: Int, hi: Int)
        if startRow == endRow {
            cols = (first.col, last.col)
        } else if let clamp = selection.clampRect {
            cols = (clamp.columns.lowerBound, clamp.columns.upperBound)
        } else {
            cols = (0, terminal.cols - 1)
        }
        return CGRect(
            x: CGFloat(cols.lo) * cellDimension.width,
            y: CGFloat(max(0, startRow) + yDisp) * cellDimension.height,
            width: CGFloat(cols.hi - cols.lo + 1) * cellDimension.width,
            height: CGFloat(min(terminal.rows - 1, endRow) - max(0, startRow) + 1) * cellDimension.height)
    }

    /// Multiplex patch: seed a word selection at a gesture location — what
    /// a plain tap/long press does while the app owns selection chrome.
    /// Character-granular drags afterwards, exactly like the double-tap
    /// selection path.
    private func seedAppSelection (at hit: Position) {
        selection.selectWordOrExpression(at: hit, in: terminal.displayBuffer)
        selection.selectionMode = .character
        enableSelectionPanGesture()
        queuePendingDisplay()
    }

    /// Multiplex patch: an app-owned select-text HUD over a mouse-capturing
    /// full-screen app (tmux, herdr). Like the copy-mode state above it turns
    /// mouse reporting off so taps run the native selection gestures — but
    /// unlike copy mode there is no remote view that answers cursor keys, so
    /// a pan falling through to the alternate-screen branch would type
    /// arrows into the remote app. While set, pans are not forwarded at all
    /// (the alternate buffer has no local scrollback to move either).
    public var suppressRemotePanScroll: Bool = false {
        didSet {
            guard suppressRemotePanScroll != oldValue else { return }
            updateRemotePanGesture()
        }
    }

    /// True when a pan should be forwarded to the remote instead of
    /// scrolling the local scrollback. Terminal.init replays mode changes
    /// through the delegate before `terminal` is assigned — stay nil-safe.
    var remoteScrollApplies: Bool {
        guard let terminal else { return false }
        if suppressRemotePanScroll { return false }
        return forceRemoteCursorScroll
            || (allowMouseReporting && terminal.mouseMode != .off)
            || terminal.isCurrentBufferAlternate
    }

    /// Preserve upstream's Shift+mouse bypass while Multiplex owns the
    /// pan recognizer. Unless the remote explicitly captures Shift through
    /// XTSHIFTESCAPE, a shifted pan must not emit remote mouse/wheel events;
    /// an active local selection remains free to own its drag.
    fileprivate func shouldBeginRemoteScroll (_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard remoteScrollApplies, !selection.active, let terminal else { return false }
        return !(allowMouseReporting
            && terminal.mouseMode != .off
            && shiftBypassesMouseReporting(for: gestureRecognizer))
    }

    @objc func panMouseHandler (_ gestureRecognizer: UIPanGestureRecognizer){
        guard gestureRecognizer.view != nil,
              cellDimension.height > 0,
              shouldBeginRemoteScroll(gestureRecognizer)
        else { return }
        switch gestureRecognizer.state {
        case .began:
            remoteScrollResidual = 0
            remoteScrollAnchor = gestureRecognizer.location(in: self)
        case .changed:
            let dy = gestureRecognizer.translation(in: self).y + remoteScrollResidual
            let ticks = Int (dy / cellDimension.height)
            remoteScrollResidual = dy - CGFloat (ticks) * cellDimension.height
            gestureRecognizer.setTranslation(.zero, in: self)
            if ticks != 0 {
                performRemoteScroll(ticks: ticks, at: remoteScrollAnchor
                    ?? gestureRecognizer.location(in: self))
            }
        default:
            remoteScrollAnchor = nil
        }
    }

    /// Multiplex patch: scrolls the remote by `ticks` cells — positive means
    /// the finger moved down, i.e. reveal earlier content. Sends wheel
    /// button events when the client requested mouse tracking, otherwise
    /// DECCKM-aware cursor keys while the alternate buffer is active. Cursor
    /// key bursts are batched into one send per pan tick.
    public func performRemoteScroll (ticks: Int, at point: CGPoint? = nil) {
        guard let terminal else { return }
        let count = min (abs (ticks), 40)
        guard count > 0 else { return }
        if allowMouseReporting && terminal.mouseMode != .off {
            let flags = terminal.encodeButton(button: ticks > 0 ? 4 : 5, release: false,
                                              shift: false, meta: false, control: false)
            let hit = calculateTapHit(point: point ?? CGPoint (x: bounds.midX, y: bounds.midY))
            guard let grid = hit.grid.toScreenCoordinate(from: terminal.displayBuffer) else { return }
            for _ in 0..<count {
                terminal.sendEvent(buttonFlags: flags, x: grid.col, y: grid.row,
                                   pixelX: hit.pixels.col, pixelY: hit.pixels.row)
            }
        } else if forceRemoteCursorScroll || terminal.isCurrentBufferAlternate {
            let sequence: [UInt8]
            if ticks > 0 {
                sequence = terminal.applicationCursor
                    ? EscapeSequences.moveUpApp
                    : EscapeSequences.moveUpNormal
            } else {
                sequence = terminal.applicationCursor
                    ? EscapeSequences.moveDownApp
                    : EscapeSequences.moveDownNormal
            }
            var burst: [UInt8] = []
            burst.reserveCapacity(sequence.count * count)
            for _ in 0..<count {
                burst.append(contentsOf: sequence)
            }
            send(burst)
        }
    }
   
    @MainActor
    func startSelectionTimer (_ callback: @MainActor @escaping ()->()) {
        panTask = Task {
            while !Task.isCancelled {
                callback ()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    
    func stopSelectionTimer () {
        panTask?.cancel()
        panTask = nil
    }
    
    // The start of the pan operation, for the case where we are not sending the input to the client
    var panStart: Position?
    var panTask: Task<(),Never>?
    
    @objc func panSelectionHandler (_ gestureRecognizer: UIPanGestureRecognizer) {
        func near (_ pos1: Position, _ pos2: Position) -> Bool {
            return abs (pos1.col-pos2.col) < 3 && abs (pos1.row-pos2.row) < 2
        }
        
        switch gestureRecognizer.state {
        case .began:
            let hit = calculateTapHit(gesture: gestureRecognizer).grid
            if selection.active {
                var extend = false
                if near (selection.start, hit) {
                    selection.pivot = selection.end
                    extend = true
                } else if near (selection.end, hit) {
                    selection.pivot = selection.start
                    extend = true
                }
                if extend {
                    selection.pivotExtend(bufferPosition: hit)
                    requestDisplay()
                    break
                }
            }
            panStart = hit
        case .changed:
            let absoluteY = gestureRecognizer.location (in: self).y - contentOffset.y
            let hit = calculateTapHit(gesture: gestureRecognizer).grid
            if selection.active {
                stopSelectionTimer()
                selection.pivotExtend(bufferPosition: hit)
                gestureRecognizer.setTranslation(CGPoint.zero, in: self)
                if absoluteY < 0 || absoluteY > bounds.height {
                    startSelectionTimer {
                        let newPlace = CGRect (x: 0, y: max (0, self.contentOffset.y+absoluteY), width: self.bounds.width, height: self.bounds.height)
                        self.scrollRectToVisible(newPlace, animated: true)
                    }
                }
                requestDisplay()
            } else {
                if let ps = panStart {
                    let deltaRow = ps.row - hit.row
                    if allowMouseReporting {
                        // TODO: what scenario would have this?
                        scrollDown (lines: deltaRow)
                    } else {
                        let deltaCol = ps.col - hit.col
                        
                        sendKey (deltaCol: deltaCol, deltaRow: deltaRow)
                    }
                }
            }
        case .ended:
            stopSelectionTimer()
            if selection.active {
                showContextMenu (forRegion: makeContextMenuRegionForSelection(), pos: calculateTapHit(gesture: gestureRecognizer).grid)
            }
            break
        case .cancelled:
            stopSelectionTimer()
            selection.active = false
        default:
            break
        }
    }
    
    var panMouseGesture: UIPanGestureRecognizer?
    // Multiplex patch: the gate yields to an active selection drag, and the
    // recognizer also accepts indirect (trackpad/mouse wheel) scrolls.
    private lazy var remoteScrollGate = RemoteScrollGestureGate (terminalView: self)
    func enableMousePanGesture () {
        guard panMouseGesture == nil else {
            return
        }
        let gesture = UIPanGestureRecognizer (target: self, action: #selector(panMouseHandler))
        gesture.allowedScrollTypesMask = .all
        gesture.delegate = remoteScrollGate
        addGestureRecognizer(gesture)
        panMouseGesture = gesture
    }

    func disableMousePanGesture () {
        guard let gesture = panMouseGesture else {
            return
        }
        removeGestureRecognizer(gesture)
        panMouseGesture = nil
    }

    // Multiplex patch: while pans go to the remote, the scroll view's own
    // pan must not compete for touches (the alternate buffer has no local
    // content to scroll anyway). Re-enabled for local scrollback otherwise.
    func updateRemotePanGesture () {
        if remoteScrollApplies {
            enableMousePanGesture()
            isScrollEnabled = false
        } else {
            disableMousePanGesture()
            isScrollEnabled = true
        }
    }
    
    var panSelectionGesture: UIPanGestureRecognizer?
    func enableSelectionPanGesture () {
        guard panSelectionGesture == nil else {
            return
        }
        let gesture = UIPanGestureRecognizer (target: self, action: #selector(panSelectionHandler))
        addGestureRecognizer(gesture)
        self.panSelectionGesture = gesture
    }
    
    func disableSelectionPanGesture() {
        guard let gesture = panSelectionGesture else {
            return
        }
        removeGestureRecognizer(gesture)
        panSelectionGesture = nil
    }
    
    func setupGestures ()
    {
        let longPress = UILongPressGestureRecognizer (target: self, action: #selector(longPress(_:)))
        longPress.minimumPressDuration = 0.7
        addGestureRecognizer(longPress)
        
        let singleTap = UITapGestureRecognizer (target: self, action: #selector(singleTap(_:)))
        addGestureRecognizer(singleTap)
        
        let doubleTap = UITapGestureRecognizer (target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let tripleTap = UITapGestureRecognizer (target: self, action: #selector(tripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        addGestureRecognizer(tripleTap)

        // Multiplex patch: a pointer's secondary click is the long press
        // said with a mouse — same local chain, decided in
        // `presentLocalPressActions`. `buttonMaskRequired` is the actual
        // secondary-button gate, but the touch type must ALSO be pinned to
        // `.indirectPointer`: the mask is ignored for direct input, so
        // otherwise every finger tap raises the block (observed on device).
        // Designed-for-iPad has a separate GCMouse HID fallback for physical
        // clicks UIKit fails to classify as indirect pointer input.
        if #available(iOS 13.4, visionOS 1.0, *) {
            let secondaryClick = UITapGestureRecognizer(
                target: self,
                action: #selector(secondaryClick(_:))
            )
            secondaryClick.allowedTouchTypes = [
                UITouch.TouchType.indirectPointer.rawValue as NSNumber
            ]
            secondaryClick.buttonMaskRequired = .secondary
            addGestureRecognizer(secondaryClick)
        }

        // Multiplex patch: the single→double→triple failure chain is decided
        // per touch by the delegate instead of `require(toFail:)`. With mouse
        // reporting active, single taps never wait: every physical tap reaches
        // the remote immediately, preserving remote double-click semantics.
        // The app-owned double-tap selection block is additive; only the
        // otherwise-silent double recognizer waits for triple to fail so a
        // triple tap cannot flash the block. With mouse off, the delegate
        // answers exactly like the old chain: double/triple keep their local
        // word/line selection, singles keep waiting.
        singleTap.delegate = self
        doubleTap.delegate = self
        tripleTap.delegate = self
    }

    /// Whether this remote-owned double gesture should additionally raise
    /// local selection chrome. Every input kind counts — finger, Pencil,
    /// visionOS gaze/pinch, and a pointer's double-click — so a mouse says
    /// "select this word" exactly the way a double tap does. The two physical
    /// clicks still reach the remote first, so a mouse-aware TUI keeps its
    /// own double-click semantics.
    private func localDoubleTapOpensSelectionMenu(
        _ gestureRecognizer: UITapGestureRecognizer
    ) -> Bool {
        selectionMenuHandler != nil
    }

    /// Multiplex patch: true while a tap belongs to the remote right now —
    /// the same predicate the tap handlers' mouse branches test, evaluated
    /// per touch so runtime mouse-mode flips and the Copy Mode
    /// `allowMouseReporting` toggle are always honored.
    private func remoteOwnsImmediateTaps(for gestureRecognizer: UIGestureRecognizer) -> Bool {
        allowMouseReporting
            && !shiftBypassesMouseReporting(for: gestureRecognizer)
            && terminal.mouseMode.sendButtonPress()
    }

    /// Multiplex patch: the dynamic form of the tap failure chain. Mouse-off
    /// gestures keep the stock single→double→triple chain. While the remote
    /// owns taps, single never waits for double; when the app selection block
    /// is installed, double alone waits for triple so a triple remains three
    /// immediate remote clicks without briefly opening local chrome.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let tap = gestureRecognizer as? UITapGestureRecognizer,
              let other = otherGestureRecognizer as? UITapGestureRecognizer,
              tap.view === self, other.view === self,
              other.numberOfTapsRequired == tap.numberOfTapsRequired + 1
        else { return false }
        let remoteOwnsTap = remoteOwnsImmediateTaps(for: tap)
        if remoteOwnsTap,
           tap.numberOfTapsRequired == 2,
           selectionMenuHandler != nil {
            return true
        }
        return !remoteOwnsTap
    }

    func setupLinkReportingInteractions ()
    {
        if #available(iOS 13.4, visionOS 1.0, *) {
            let interaction = UIPointerInteraction(delegate: self)
            addInteraction(interaction)
            pointerInteraction = interaction
        }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            Self.setupMacSecondaryClickBridgeIfNeeded()
        }
        if #available(iOS 13.0, visionOS 1.0, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hover)
            hoverGesture = hover
        }
    }

    @available(iOS 13.4, visionOS 1.0, *)
    public func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion?
    {
        lastPointerLocation = request.location
        if ProcessInfo.processInfo.isiOSAppOnMac {
            Self.macSecondaryClickTarget = self
        }
        reportLinkIfNeeded(at: request.location, modifiers: request.modifiers, force: false)
        updateLinkHighlightIfNeeded(at: request.location, modifiers: request.modifiers, force: false)
        return nil
    }

    @objc func handleHover (_ gestureRecognizer: UIHoverGestureRecognizer)
    {
        switch gestureRecognizer.state {
        case .began, .changed:
            let location = gestureRecognizer.location(in: self)
            lastPointerLocation = location
            if ProcessInfo.processInfo.isiOSAppOnMac {
                Self.macSecondaryClickTarget = self
            }
            reportLinkIfNeeded(at: location, modifiers: [], force: true)
            updateLinkHighlightIfNeeded(at: location, modifiers: [.command], force: true)
        case .ended, .cancelled:
            lastReportedLink = nil
            lastPointerLocation = nil
            if Self.macSecondaryClickTarget === self {
                Self.macSecondaryClickTarget = nil
            }
            if linkHighlightMode == .hover || linkHighlightMode == .hoverWithModifier {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                queuePendingDisplay()
            }
        default:
            break
        }
    }

    private func reportLinkIfNeeded(at point: CGPoint, modifiers: UIKeyModifierFlags, force: Bool)
    {
        guard linkReporting != .none else {
            lastReportedLink = nil
            return
        }
        if !force && !commandActive && !modifiers.contains(.command) {
            return
        }
        let hit = calculateTapHit(point: point).grid
        let mode: Terminal.LinkLookupMode = linkReporting == .explicit ? .explicitOnly : .explicitAndImplicit
        let link = terminal.link(at: .buffer(hit), mode: mode)
        if link != lastReportedLink {
            lastReportedLink = link
        }
    }

    private func updateLinkHighlightIfNeeded(at point: CGPoint, modifiers: UIKeyModifierFlags, force: Bool)
    {
        if linkHighlightMode == .always || linkHighlightMode == .alwaysWithModifier {
            return
        }
        let requiresModifier = linkHighlightMode == .hoverWithModifier
        if requiresModifier && !commandActive && !modifiers.contains(.command) {
            if linkHighlightRange != nil {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                queuePendingDisplay()
            }
            return
        }
        if !force && !commandActive && !modifiers.contains(.command) && linkHighlightMode == .hoverWithModifier {
            return
        }
        let hit = calculateTapHit(point: point).grid
        let match = terminal.linkMatch(at: .buffer(hit), mode: .explicitAndImplicit)
        let newRange = match?.rowRanges
        if newRange != linkHighlightRange {
            let oldRange = linkHighlightRange
            linkHighlightRange = newRange
            invalidateLinkHighlight(oldRange: oldRange, newRange: newRange)
            queuePendingDisplay()
        }
    }
    
    var _inputAccessory: UIView?
    var _inputView: UIView?
    
    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    #if os(visionOS)
    public var inputAccessoryView: UIView? {
        get { _inputAccessory }
        set {
            _inputAccessory = newValue
        }
    }
    #else
    public override var inputAccessoryView: UIView? {
        get { _inputAccessory }
        set {
            _inputAccessory = newValue
        }
    }
    #endif

    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    public override var inputView: UIView? {
        get { _inputView }
        set {
            _inputView = newValue
        }
    }

    /// Returns the inputaccessory in case it is a TerminalAccessory and we can use it
    var terminalAccessory: TerminalAccessory? {
        get {
            _inputAccessory as? TerminalAccessory
        }
    }

    func setupAccessoryView ()
    {
        let short = UIDevice.current.userInterfaceIdiom == .phone
        let ta = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: frame.width, height: short ? 36 : 48),
                                   inputViewStyle: .keyboard, container: self)
        #if !os(visionOS)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        #endif
        ta.sizeToFit()
        inputAccessoryView = ta
        
        //inputAccessoryView?.autAoresizingMask = .flexibleHeight
    }
    
    func setupOptions ()
    {
        setupOptions(width: bounds.width, height: bounds.height)
        layer.backgroundColor = nativeBackgroundColor.cgColor
        nativeBackgroundColor = UIColor.clear
        // The terminal background is provided by `layer.backgroundColor`, and
        // `draw(_:)` paints glyph cells with a transparent backdrop so that the
        // layer colour shows through the gaps. That only works if the view is
        // non-opaque: an opaque view gets an alpha-less graphics context where
        // the transparent fill is a no-op, leaving uninitialised backing-store
        // garbage in every default-background region. When the scroll view blits
        // and re-exposes strips during scrolling, that garbage becomes visible as
        // flickering/striped corruption. Marking the view non-opaque makes the
        // transparent compositing behave as intended.
        isOpaque = false
    }
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: UIColor {
        get { _nativeFg }
        set {
            if settingFg { return }
            settingFg = true
            _nativeFg = newValue
            terminal.foregroundColor = nativeForegroundColor.getTerminalColor ()
            settingFg = false
        }
    }
    
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeBackgroundColor: UIColor {
        get { _nativeBg }
        set {
            if settingBg { return }
            settingBg = true
            _nativeBg = newValue
            terminal.backgroundColor = nativeBackgroundColor.getTerminalColor ()
            colorsChanged()
            settingBg = false
        }
    }

    /// Controls the color for the caret
    public var caretColor: UIColor {
        get { caretView?.caretColor ?? UIColor.black }
        set { caretView?.caretColor = newValue }
    }
    
    /// Controls the color for the text in the caret when using a block cursor, if not set
    /// the cursor will render with the foreground color
    public var caretTextColor: UIColor? {
        get { caretView?.caretTextColor }
        set { caretView?.caretTextColor = newValue }
    }
    
    /// Controls weather to use high ansi colors, if false terminal will use bold text instead of high ansi colors
    public var useBrightColors: Bool = true

    /// When true, block element (U+2580-U+259F) and box drawing (U+2500-U+257F) characters use custom rendering.
    public var customBlockGlyphs: Bool = true {
        didSet {
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }

    /// When true, custom block/box glyphs use anti-aliasing instead of pixel-aligned edges.
    public var antiAliasCustomBlockGlyphs: Bool = false {
        didSet {
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }

    var _selectedTextBackgroundColor = UIColor(red: 0, green: 166.0 / 255.0, blue: 178.0 / 255.0, alpha: 1.0)
    /// The background color used to render the selection.
    public var selectedTextBackgroundColor: UIColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }

    var _selectedTextForegroundColor = UIColor.black
    /// The foreground color used to render selected text.
    public var selectedTextForegroundColor: UIColor {
        get {
            return _selectedTextForegroundColor
        }
        set {
            _selectedTextForegroundColor = newValue
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }
    
    var _selectionHandleColor: UIColor = UIColor.systemBlue
    /// The color used to render the selection handles
    public var selectionHandleColor: UIColor {
        get {
            return _selectionHandleColor
        }
        set {
            _selectionHandleColor = newValue
        }
    }

    /// Whether the terminal currently has an active text selection.
    ///
    /// Exposed publicly so embedders (e.g. a UIScrollView subclass that
    /// hosts the terminal) can veto their own gesture recognisers while
    /// the user is dragging a selection handle. The underlying
    /// `SelectionService` is intentionally `internal`; this read-only
    /// accessor is the minimum public surface needed for the common
    /// "don't scroll while I'm dragging the selection handle" pattern.
    ///
    /// Added by the meshTerm fork (`v1.13.0-meshterm.1`). An upstream
    /// PR has been filed mirroring this accessor; once merged we will
    /// switch back to upstream and drop the fork.
    public var hasActiveSelection: Bool {
        return selection?.active ?? false
    }

    /// Programmatically sets the selection range to the given buffer
    /// positions. Useful for callers that want to highlight a region
    /// without going through a drag gesture — e.g. a search overlay
    /// that wants match cells to light up with the same visual
    /// treatment as a user-driven selection. Coordinates are
    /// buffer-relative `Position` values. The view's internal
    /// selection rendering picks up the change automatically.
    public func setSelectionRange(start: Position, end: Position) {
        selection?.setSelection(start: start, end: end)
    }

    /// Clears any active selection. Companion to `setSelectionRange`
    /// for callers that don't have a UIResponder hook into the menu
    /// system (where `selectNone` would otherwise come from).
    public func clearSelection() {
        selection?.selectNone()
        // Multiplex patch: programmatic clears (the app-owned selection
        // chrome's teardown) must also retire the selection drag recognizer
        // and repaint, or a stale highlight and gesture linger.
        disableSelectionPanGesture()
        queuePendingDisplay()
    }

    /// Programmatically presents SwiftTerm's standard Copy / Paste /
    /// Select All context menu at the given point in the terminal's
    /// coordinate space. Mirrors the path the built-in long-press
    /// gesture takes — becomes first responder, computes the menu
    /// region around the tap point, then calls the existing internal
    /// `showContextMenu(forRegion:pos:)` presenter.
    ///
    /// Useful when a host app replaces the built-in long-press gesture
    /// with custom behaviour (e.g. a cursor-drag mode) but still wants
    /// the existing menu as a fallback for release-without-movement.
    public func showStandardContextMenu(at point: CGPoint) {
        _ = becomeFirstResponder()
        let region = makeContextMenuRegionForTap(point: point)
        let hit = calculateTapHit(point: point)
        showContextMenu(forRegion: region, pos: hit.grid)
    }

    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    var lineLeading: CGFloat = 0
    
    open func bufferActivated(source: Terminal) {
        resetManualScrollTracking()
        updateScroller ()
        // Multiplex patch: entering/leaving the alternate buffer flips
        // whether pans scroll the remote or the local scrollback.
        updateRemotePanGesture ()
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
    
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    open func getOptimalFrameSize () -> CGRect
    {
        return CGRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols), height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    func getImageScale () -> CGFloat {
        self.window?.contentScaleFactor ?? 1
    }
    
    func getEffectiveWidth (size: CGSize) -> CGFloat
    {
        return size.width
    }
    
    func updateDebugDisplay ()
    {
    }
    
    func scale (image: UIImage, size: CGSize) -> UIImage {
        UIGraphicsBeginImageContext(size)
        
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw (in: dstRect)
        
        let ret = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return ret
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        guard let cropCG = image.cgImage?.cropping(to: srcRect) else {
            return nil
        }
        let uicrop = UIImage (cgImage: cropCG)
        
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return nil
        }
        ctx.translateBy(x: 0, y: dstHeight)
        ctx.scaleBy(x: 1, y: -1)

        uicrop.draw(in: destRect)
        
        let stripe = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return stripe
    }

    open func scrolled(source terminal: Terminal, yDisp: Int) {
        //XselectionView.notifyScrolled(source: terminal)
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
    }
    
    open func linefeed(source: Terminal) {
        // Preserve manual selection while output is streaming when mouse reporting is disabled.
        if allowMouseReporting {
            selection.selectNone()
            disableSelectionPanGesture()
        }
    }
    
    func updateScroller ()
    {
        let displayBuffer = terminal.displayBuffer
        contentSize = CGSize (width: CGFloat (displayBuffer.cols) * cellDimension.width,
                              height: CGFloat (displayBuffer.lines.count) * cellDimension.height)
        // Let the gesture own contentOffset while the finger is physically down
        // (isTracking), and while frozen history coasts under momentum —
        // re-asserting it there fights the drag and blocks the user from reaching
        // the bottom. But when following the bottom (userScrolling == false) we
        // must keep pinning to the bottom even during deceleration: otherwise
        // streaming output grows the content faster than the coasting offset, the
        // tail pulls away, and the view falls behind the live output.
        //
        // NOTE: isTracking (finger down), not isDragging — on device isDragging
        // stays true through the whole momentum coast, so it cannot distinguish
        // an active drag from post-lift deceleration. contentSize is still
        // updated above so the newly appended rows remain reachable.
        if isTracking || (userScrolling && isDecelerating) {
            return
        }
        let rowOffset = CGFloat (displayBuffer.yDisp) * cellDimension.height
        let desiredY = userScrolling ? rowOffset + manualScrollOffsetWithinRow : rowOffset
        // Clamp to the scroll view's real maximum so following the bottom rests
        // flush against the last line instead of over-scrolling past it.
        let offsetY = min(desiredY, maxContentOffsetY())
        setContentOffsetFromTerminal(CGPoint (x: 0, y: offsetY))
        //Xscroller.doubleValue = scrollPosition
        //Xscroller.knobProportion = scrollThumbsize
    }

#if canImport(MetalKit)
    func metalVisibleRange() -> ClosedRange<Int>? {
        let buffer = terminal.displayBuffer
        guard buffer.lines.count > 0, cellDimension.height > 0, bounds.height > 0 else {
            return nil
        }
        let contentHeight = CGFloat(buffer.lines.count) * cellDimension.height
        let maxOffset = max(0, contentHeight - bounds.height)
        let offsetY = min(max(0, contentOffset.y), maxOffset)
        let firstRow = max(0, Int(floor(offsetY / cellDimension.height)))
        let lastRow = min(buffer.lines.count - 1,
                          Int(floor((offsetY + bounds.height - 1) / cellDimension.height)))
        if firstRow > lastRow {
            return nil
        }
        return firstRow...lastRow
    }
#endif
    
    var userScrolling = false
    private var updatingContentOffsetFromTerminal = false
    private var manualScrollOffsetWithinRow: CGFloat = 0

    private var contentOffsetTolerance: CGFloat {
        1 / max(backingScaleFactor(), 1)
    }

    private func maxDisplayRow(in displayBuffer: Buffer) -> Int {
        max(0, displayBuffer.lines.count - displayBuffer.rows)
    }

    /// The largest resting `contentOffset.y` the scroll view can actually reach.
    /// This is smaller than `maxDisplayRow * cellHeight` by the partial-row
    /// remainder whenever the viewport height is not an exact multiple of the
    /// cell height, so it — not the row offset — is the true "bottom" of the
    /// content for both follow-mode positioning and at-bottom detection. The
    /// `adjustedContentInset.bottom` term matches UIScrollView's own clamp: with
    /// a bottom inset (accessory view, safe area, keyboard) the resting maximum
    /// shifts, and ignoring it left the user unable to ever reach the bottom to
    /// disengage the freeze — even by overscrolling.
    private func maxContentOffsetY() -> CGFloat {
        max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
    }

    private func setContentOffsetFromTerminal(_ newContentOffset: CGPoint) {
        if abs(contentOffset.x - newContentOffset.x) <= contentOffsetTolerance &&
            abs(contentOffset.y - newContentOffset.y) <= contentOffsetTolerance {
            return
        }

        updatingContentOffsetFromTerminal = true
        contentOffset = newContentOffset
        updatingContentOffsetFromTerminal = false
    }

    private func setManualScrolling(_ enabled: Bool) {
        userScrolling = enabled
        terminal.userScrolling = enabled
        if !enabled {
            manualScrollOffsetWithinRow = 0
        }
    }

    func resetManualScrollOffsetWithinRow() {
        manualScrollOffsetWithinRow = 0
    }

    private func resetManualScrollTracking() {
        setManualScrolling(false)

        let displayBuffer = terminal.displayBuffer
        terminal.setViewYDisp(maxDisplayRow(in: displayBuffer))
        let bottomOffset = min(CGFloat(displayBuffer.yDisp) * cellDimension.height, maxContentOffsetY())
        setContentOffsetFromTerminal(CGPoint(x: 0, y: bottomOffset))
    }

    private func syncYDispFromContentOffset() {
        guard terminal != nil, !updatingContentOffsetFromTerminal, cellDimension.height > 0 else {
            return
        }

        let displayBuffer = terminal.displayBuffer
        let maxRow = maxDisplayRow(in: displayBuffer)
        let maxContentOffset = maxContentOffsetY()
        let offsetY = min(max(contentOffset.y, 0), maxContentOffset)

        // A drag that lands within half a row of the bottom (or overscrolls past
        // it) re-engages auto-follow. A sub-pixel tolerance was too tight —
        // fractional cell heights and contentInset rounding left the user a hair
        // short of the exact maximum, so the freeze never disengaged.
        let atBottomThreshold = max(contentOffsetTolerance, cellDimension.height / 2)
        if offsetY >= maxContentOffset - atBottomThreshold {
            if displayBuffer.yDisp != maxRow {
                terminal.setViewYDisp(maxRow)
            }
            setManualScrolling(false)
            return
        }

        // Freeze auto-follow only while the finger is physically down
        // (isTracking). Excluding the momentum coast is essential: after the
        // finger lifts, deceleration keeps firing sync while streaming output
        // extends the content and the bottom recedes ahead of the coasting
        // offset — treating that "not at the bottom yet" reading as a manual
        // scroll would re-freeze a view the user just flung to the bottom. This
        // must key off isTracking, not isDragging: on device isDragging stays
        // true through the entire coast, so it fails to exclude momentum. It also
        // covers layout/system-driven offset changes (startup sizing, rotation,
        // keyboard insets, buffer shrink), which are never a manual scroll.
        guard isTracking else {
            return
        }

        let row = max(0, min(maxRow, Int(floor((offsetY + contentOffsetTolerance) / cellDimension.height))))
        manualScrollOffsetWithinRow = offsetY - CGFloat(row) * cellDimension.height
        if displayBuffer.yDisp != row {
            terminal.setViewYDisp(row)
        }
        setManualScrolling(true)
    }

    func getCurrentGraphicsContext () -> CGContext?
    {
        UIGraphicsGetCurrentContext ()
    }

    func requestDisplay() {
#if canImport(MetalKit)
        if useMetalRenderer {
            queueMetalDisplay()
            return
        }
#endif
        setNeedsDisplay(bounds)
    }

    func backingScaleFactor () -> CGFloat
    {
        #if os(visionOS)
        1.0
        #else
        UIScreen.main.scale
        #endif
    }
    
    override public func draw (_ dirtyRect: CGRect) {
#if canImport(MetalKit)
        if useMetalRenderer {
            return
        }
#endif
        guard let context = getCurrentGraphicsContext() else {
            return
        }

        // Without these two lines, on font changes, some junk is being displayed
        // Once we test the font change, we could disable these two lines, and
        // enable the #if false in drawterminalContents that should be coping with this now
        nativeBackgroundColor.set ()
        context.fill ([dirtyRect])

        // drawTerminalContents and CoreText expect the AppKit coordinate system
        context.scaleBy (x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)

        drawTerminalContents (dirtyRect: dirtyRect, context: context, bufferOffset: 0)
    }
    open override func layoutSubviews() {
        super.layoutSubviews()
        guard didFinishSetup else { return }

        let currentBounds = bounds
        let sizeChanged = currentBounds.size != lastLayoutBounds.size
        let originChanged = currentBounds.origin != lastLayoutBounds.origin

        if sizeChanged {
            processSizeChange(newSize: currentBounds.size)
            updateCursorPosition()
        }

#if canImport(MetalKit)
        if useMetalRenderer, let metalView = metalView {
            metalView.frame = bounds
            requestMetalDisplay()
        } else {
	    if sizeChanged || originChanged {
                setNeedsDisplay(bounds)
	    }
        }
#else
        if sizeChanged || originChanged {
            setNeedsDisplay(bounds)
	}
#endif

        lastLayoutBounds = currentBounds
    }

    open override var contentOffset: CGPoint {
        didSet {
            syncYDispFromContentOffset()
#if canImport(MetalKit)
            if useMetalRenderer, metalView != nil {
                requestMetalDisplay()
            }
#endif
        }
    }

    open override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let pageHeight = max(bounds.height, cellDimension.height)
        let maxOffsetY = max(0, contentSize.height - bounds.height)
        let targetOffsetY: CGFloat

        switch direction {
        case .down, .right, .next:
            targetOffsetY = min(maxOffsetY, contentOffset.y + pageHeight)
        case .up, .left, .previous:
            targetOffsetY = max(0, contentOffset.y - pageHeight)
        default:
            return super.accessibilityScroll(direction)
        }

        guard targetOffsetY != contentOffset.y else {
            return false
        }

        setContentOffset(CGPoint(x: contentOffset.x, y: targetOffsetY), animated: false)
        setNeedsDisplay(bounds)
        // Based on WWDC 2019 presentation: argument is nil
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }

    // iOS Keyboard input
    
    // UITextInputTraits
    // Multiplex patch: settable so the host app can choose its keyboard
    // policy. Multiplex keeps `.default`, preserving the user's selected
    // language and multistage IME. Was get-only upstream.
    public var keyboardType: UIKeyboardType = .`default`
    
    public var keyboardAppearance: UIKeyboardAppearance = .`default`
    public var returnKeyType: UIReturnKeyType = .`default`
    
    // This is wrong, but I can not find another good one
    public var textContentType: UITextContentType! = .none
    
    public var isSecureTextEntry: Bool = false
    public var enablesReturnKeyAutomatically: Bool = false
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // Multiplex patch: pin on-device intelligence off. At `.default` the
    // system decides per device/OS whether to rewrite input through
    // `replace(_:withText:)` — edits a terminal cannot express (see the tail
    // guard there). Computed: the types postdate the package's floor.
    @available(iOS 17.0, *)
    public var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set { }
    }

    @available(iOS 18.0, visionOS 2.4, *)
    public var writingToolsBehavior: UIWritingToolsBehavior {
        get { .none }
        set { }
    }

    @available(iOS 18.0, *)
    public var mathExpressionCompletionType: UITextMathExpressionCompletionType {
        get { .no }
        set { }
    }


    open override var canBecomeFirstResponder: Bool {
        true
    }
    
    open override var canBecomeFocused: Bool {
        true
    }
    
    /// Multiplex patch: a terminal's document is the remote screen, not this
    /// view's local input mirror, so this always answers true.
    ///
    /// `textInputStorage` holds only what was typed through *this* view's text
    /// input session. Text that arrived any other way — typed before the
    /// attach, sent by another client, echoed by the remote, or left in a
    /// composer when the app reattaches — is on screen and deletable while the
    /// mirror is still empty, so reporting that mirror answered a question
    /// about the wrong document. Backspace is unconditionally meaningful here:
    /// `deleteBackward` sends 0x7f (or the kitty backspace event) and the remote
    /// alone decides what that does. Nothing in SwiftTerm reads this property —
    /// real editing addresses `textInputStorage` through ranges — so it is
    /// advisory to UIKit only.
    ///
    /// ⚠ This does NOT restore held-backspace auto-repeat (tested: no change).
    /// Once iOS accelerates a held delete it deletes word-wise, which reads the
    /// document's actual characters to find boundaries — an empty mirror
    /// starves that regardless of what this property claims. Same root cause as
    /// upstream SwiftTerm #271 ("will not auto-repeat if it encounters a
    /// space"), still open and undiagnosed there. Fixing it needs the document
    /// stocked with real filler characters, which lands on the buffer that also
    /// carries marked text and the Korean resyllabification transaction.
    public var hasText: Bool {
        return true
    }

    // MARK: - Input filler (held-backspace auto-repeat)
    //
    // Multiplex patch: iOS accelerates a held delete key into word-wise
    // deletion, and to find a word boundary it reads the real characters of the
    // `UITextInput` document. `textInputStorage` only ever mirrors what was
    // typed through this view, so for text that came from anywhere else — typed
    // before the attach, sent by another client, echoed by the remote — the
    // document is empty and the repeat starves immediately: every backspace
    // becomes a separate tap. (Upstream SwiftTerm #271 is the milder form,
    // where the repeat dies at a space.) Neither `hasText` nor reporting the
    // delete to `inputDelegate` fixes it; the keyboard wants characters it can
    // consume.
    //
    // So when the buffer holds nothing real, it is stocked with filler, and
    // each filler character the keyboard consumes is converted into one
    // backspace byte for the remote. The load-bearing invariant is that filler
    // exists ONLY while there is no real text: any actual input clears it
    // first. That keeps filler from ever sitting next to typed text (where a
    // word-wise delete spanning the boundary would over-count backspaces) and
    // keeps it away from `.last`/`.suffix()` and the caret-at-end guards that
    // the auto-period and Korean resyllabification paths read.
    //
    // Both constants are tuning knobs. The length bounds how many backspaces a
    // single word-wise delete can emit in one tick; the character must not be a
    // space (spaces are what upstream #271 trips over, and the auto-period path
    // keys on a trailing space) and must not be Hangul (`tryComposeKoreanFinal`
    // inspects the last character).
    static let inputFillerLength = 16
    static let inputFillerCharacter: Character = "x"

    /// Count of filler characters at the head of `textInputStorage`. Non-zero
    /// only while the buffer is *entirely* filler — see the invariant above.
    var inputFillerCount = 0

    /// Stocks the buffer with filler when it holds nothing real, so a held
    /// delete key always has characters to consume. No-op during composition.
    func seedInputFillerIfNeeded () {
        guard _markedTextRange == nil else { return }
        // Only when there is no real text: either empty, or already all filler.
        guard textInputStorage.count == inputFillerCount,
              inputFillerCount < TerminalView.inputFillerLength else { return }
        textInputStorage = String(repeating: TerminalView.inputFillerCharacter,
                                  count: TerminalView.inputFillerLength)
        inputFillerCount = TerminalView.inputFillerLength
        let end = TextPosition(offset: textInputStorage.textInputUTF16Count)
        _selectedTextRange = TextRange(from: end, to: end)
    }

    /// Drops the filler before any real input touches the buffer, restoring the
    /// empty-document state the text input paths were written against.
    func clearInputFiller () {
        guard inputFillerCount > 0 else { return }
        inputFillerCount = 0
        textInputStorage = ""
        let start = TextPosition(offset: 0)
        _selectedTextRange = TextRange(from: start, to: start)
        _markedTextRange = nil
    }

    func isAutoPeriodReplacement(_ text: String) -> Bool {
        text == "." || text == ". "
    }

    private var isKoreanTextInput: Bool {
        textInputMode?.primaryLanguage?.hasPrefix("ko") == true
    }

    private func normalizedTextForPendingAutoPeriodDelete(_ text: String) -> String? {
        switch text {
        case ".":
            // Some keyboards split auto-period into "." followed by " ".
            return " "
        case ". ":
            return "  "
        default:
            return nil
        }
    }

    func normalizedAutoPeriodReplacementText(_ text: String, oldText: Substring, rangeToReplace: TextRange) -> String? {
        if pendingAutoPeriodDeleteWasSpace, let normalized = normalizedTextForPendingAutoPeriodDelete(text) {
            pendingAutoPeriodDeleteWasSpace = false
            uitiLog("auto-period replacement pending text:\(text.debugDescription) -> \(normalized.debugDescription)")
            return normalized
        }
        guard isAutoPeriodReplacement(text) else { return nil }
        guard rangeToReplace.endPosition.offset == textInputStorage.textInputUTF16Count else { return nil }
        guard oldText.count <= 2 else { return nil }
        guard oldText.allSatisfy({ $0 == " " }) else { return nil }
        if text == "." {
            let normalized = oldText.count == 1 ? " " : String(oldText)
            uitiLog("auto-period replacement range text:\(text.debugDescription) old:\(String(oldText).debugDescription) -> \(normalized.debugDescription)")
            return normalized
        }
        if oldText.count == 1 {
            uitiLog("auto-period replacement range text:\(text.debugDescription) old:\(String(oldText).debugDescription) -> \"  \"")
            return "  "
        }
        uitiLog("auto-period replacement range text:\(text.debugDescription) old:\(String(oldText).debugDescription) -> \(String(oldText).debugDescription)")
        return String(oldText)
    }

    private func normalizedAutoPeriodInsertionText(_ text: String, rangeToReplace: TextRange, hadPendingAutoPeriodDelete: Bool) -> String? {
        guard isAutoPeriodReplacement(text) else { return nil }
        if hadPendingAutoPeriodDelete, let normalized = normalizedTextForPendingAutoPeriodDelete(text) {
            pendingAutoPeriodDeleteWasSpace = false
            uitiLog("auto-period insertion pending text:\(text.debugDescription) -> \(normalized.debugDescription)")
            return normalized
        }
        pendingAutoPeriodDeleteWasSpace = false
        guard text == ". " else { return nil }
        guard rangeToReplace.isEmpty else { return nil }
        guard rangeToReplace.endPosition.offset == textInputStorage.textInputUTF16Count else { return nil }
        guard textInputStorage.last == " " else { return nil }
        uitiLog("auto-period insertion range text:\(text.debugDescription) -> \" \"")
        return " "
    }

    private func commitTextInput(_ text: String, applyModifiers: Bool) {
        // Multiplex patch: real input never coexists with the backspace filler —
        // drop it before anything reads the buffer, so every path below sees the
        // empty document it was written against.
        clearInputFiller()
        // Multiplex patch: on iOS-app-on-Mac the Cocoa text system owns
        // hardware Return — Shift+Return never reaches pressesBegan with its
        // modifier and arrives here as a bare "\n". The physical shift state
        // is still readable at the HID layer (same GCKeyboard source as the
        // Ctrl-chord bridge), so rewrite the delivery synchronously — no
        // handler race, and exactly one byte sequence per press. Kitty-aware
        // apps get the CSI 13;2u encoding; everything else gets LF, matching
        // the pressesBegan Shift+Return cases used on real iPads/visionOS.
        if applyModifiers, text == "\n", _markedTextRange == nil, macPhysicalShiftHeld() {
            resetInputBuffer()
            if terminal.keyboardEnhancementFlags.isEmpty {
                send([10])
            } else {
                _ = sendKittyEvent(KittyKeyEvent(key: .functional(.enter),
                                                 modifiers: [.shift],
                                                 eventType: .press,
                                                 text: nil,
                                                 shiftedKey: nil,
                                                 baseLayoutKey: nil,
                                                 composing: false))
            }
            queuePendingDisplay()
            return
        }
        let hadPendingAutoPeriodDelete = pendingAutoPeriodDeleteWasSpace
        if !isAutoPeriodReplacement(text) {
            pendingAutoPeriodDeleteWasSpace = false
        }

        switch processPendingKoreanResyllabification(text) {
        case .completed:
            return
        case .prefixReinserted:
            break
        case .none:
            if tryResyllabifyKoreanFinalBeforeVowel(text) || tryComposeKoreanFinal(text) {
                return
            }
        }

        beginTextInputEdit()

        let rangeToReplace = _markedTextRange ?? _selectedTextRange
        var textToInsert = text
        if let normalized = normalizedAutoPeriodInsertionText(text, rangeToReplace: rangeToReplace, hadPendingAutoPeriodDelete: hadPendingAutoPeriodDelete) {
            textToInsert = normalized
        }
        if textToInsert != text {
            uitiLog("commitTextInput normalized:\(text.debugDescription) -> \(textToInsert.debugDescription)")
        }

        let rangeStartIndex = rangeToReplace.startPosition.offset
        textInputStorage.replaceSubrange(rangeToReplace.fullRange(in: textInputStorage), with: textToInsert)
        _markedTextRange = nil
        // Multiplex patch: all insertText routes converge here; remove the local
        // IME preview before the committed text is sent to the remote terminal.
        updateMarkedTextOverlay()
        let insertedOffset = textInputStorage.textInputValidUTF16Offset(
            rangeStartIndex + textToInsert.textInputUTF16Count,
            rounding: .forward)
        let insertedPosition = TextPosition(offset: insertedOffset)
        _selectedTextRange = TextRange(from: insertedPosition, to: insertedPosition)

        endTextInputEdit()

        if !terminal.keyboardEnhancementFlags.isEmpty {
            sendKittyTextInput(textToInsert, applyModifiers: applyModifiers)
        } else if applyModifiers && (terminalAccessory?.controlModifier ?? controlModifier ?? false) {
            self.send(applyControlToEventCharacters(textToInsert))
            terminalAccessory?.controlModifier = false
            controlModifier = false
        } else if applyModifiers && metaModifier {
            self.send([0x1b])
            self.send(txt: text)
            metaModifier = false
        } else {
            if textToInsert == "\n" {
                resetInputBuffer()
                self.send(data: returnByteSequence [0...])
            } else {
                self.send(txt: textToInsert)
            }
        }

        queuePendingDisplay()
    }

    func insertTextFromAccessory(_ text: String) {
        commitTextInput(text, applyModifiers: false)
    }

    /*
        Soft keyboard input. Hardware keyboard text input is delivered here; special keys are handled in pressesBegan.
    */
    open func insertText(_ text: String) {
        uitiLog("insertText(\(text.debugDescription)) \(textInputStateDescription())")
        // Multiplex patch: direct text input beat the Mac prefix fallback, so
        // preserve UIKit's layout result while retaining HID's key identity.
        // If HID already had to deliver a press, consume its receipt instead.
        if sendPendingMacPrefixTextInput(text) { return }
        guard !consumeMacBridgedText(text) else { return }
        commitTextInput(text, applyModifiers: true)
    }
    private func kittyEncoder() -> KittyKeyboardEncoder {
        KittyKeyboardEncoder(flags: terminal.keyboardEnhancementFlags,
                             applicationCursor: terminal.applicationCursor,
                             backspaceSendsControlH: backspaceSendsControlH)
    }

    private func kittyModifiers(from key: UIKey, includeOption: Bool) -> KittyKeyboardModifiers {
        var modifiers: KittyKeyboardModifiers = []
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }
        if includeOption, key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.super) }
        if key.modifierFlags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        return modifiers
    }

    private func kittyFunctionalKey(for keyCode: UIKeyboardHIDUsage) -> KittyFunctionalKey? {
        switch keyCode {
        case .keyboardCapsLock, .keyboardLockingCapsLock:
            return .capsLock
        case .keyboardLockingNumLock:
            return .numLock
        case .keyboardScrollLock, .keyboardLockingScrollLock:
            return .scrollLock
        case .keyboardLeftShift:
            return .leftShift
        case .keyboardRightShift:
            return .rightShift
        case .keyboardLeftControl:
            return .leftControl
        case .keyboardRightControl:
            return .rightControl
        case .keyboardLeftAlt:
            return .leftAlt
        case .keyboardRightAlt:
            return .rightAlt
        case .keyboardLeftGUI:
            return .leftSuper
        case .keyboardRightGUI:
            return .rightSuper
        case .keyboardUpArrow:
            return .up
        case .keyboardDownArrow:
            return .down
        case .keyboardLeftArrow:
            return .left
        case .keyboardRightArrow:
            return .right
        case .keyboardPageUp:
            return .pageUp
        case .keyboardPageDown:
            return .pageDown
        case .keyboardHome:
            return .home
        case .keyboardEnd:
            return .end
        case .keyboardInsert:
            return .insert
        case .keyboardDeleteForward:
            return .delete
        case .keyboardEscape:
            return .escape
        // Multiplex patch: classify hardware Return so the kitty branch of
        // pressesBegan owns it before UIKit's text-input fallback drops the
        // physical Shift modifier. With enhancement flags active, Shift+Enter
        // encodes as CSI 13;2u (plain Return stays legacy CR per the spec);
        // the flags-empty path has its own Shift+Return case in pressesBegan.
        case .keyboardReturnOrEnter, .keyboardReturn:
            return .enter
        case .keyboardTab:
            return .tab
        case .keyboardF1:
            return .f1
        case .keyboardF2:
            return .f2
        case .keyboardF3:
            return .f3
        case .keyboardF4:
            return .f4
        case .keyboardF5:
            return .f5
        case .keyboardF6:
            return .f6
        case .keyboardF7:
            return .f7
        case .keyboardF8:
            return .f8
        case .keyboardF9:
            return .f9
        case .keyboardF10:
            return .f10
        case .keyboardF11:
            return .f11
        case .keyboardF12:
            return .f12
        case .keyboardF13:
            return .f13
        case .keyboardF14:
            return .f14
        case .keyboardF15:
            return .f15
        case .keyboardF16:
            return .f16
        case .keyboardF17:
            return .f17
        case .keyboardF18:
            return .f18
        case .keyboardF19:
            return .f19
        case .keyboardF20:
            return .f20
        case .keyboardF21:
            return .f21
        case .keyboardF22:
            return .f22
        case .keyboardF23:
            return .f23
        case .keyboardF24:
            return .f24
        case .keypadNumLock:
            return .numLock
        case .keypadSlash:
            return .keypadDivide
        case .keypadAsterisk:
            return .keypadMultiply
        case .keypadHyphen:
            return .keypadSubtract
        case .keypadPlus:
            return .keypadAdd
        case .keypadEnter:
            return .keypadEnter
        case .keypad1:
            return .keypad1
        case .keypad2:
            return .keypad2
        case .keypad3:
            return .keypad3
        case .keypad4:
            return .keypad4
        case .keypad5:
            return .keypad5
        case .keypad6:
            return .keypad6
        case .keypad7:
            return .keypad7
        case .keypad8:
            return .keypad8
        case .keypad9:
            return .keypad9
        case .keypad0:
            return .keypad0
        case .keypadPeriod:
            return .keypadDecimal
        case .keypadEqualSign, .keypadEqualSignAS400:
            return .keypadEqual
        case .keypadComma:
            return .keypadSeparator
        case .keyboardPause:
            return .pause
        case .keyboardPrintScreen:
            return .printScreen
        case .keyboardStop:
            return .mediaStop
        case .keyboardMute:
            return .volumeMute
        case .keyboardVolumeUp:
            return .volumeUp
        case .keyboardVolumeDown:
            return .volumeDown
        case .keyboardApplication:
            return .menu
        case .keyboardMenu:
            return .menu
        default:
            return nil
        }
    }

    private func kittyBaseLayoutKey(for keyCode: UIKeyboardHIDUsage) -> UnicodeScalar? {
        func scalar(_ char: Character) -> UnicodeScalar {
            char.unicodeScalars.first!
        }
        switch keyCode {
        case .keyboardA: return scalar("a")
        case .keyboardB: return scalar("b")
        case .keyboardC: return scalar("c")
        case .keyboardD: return scalar("d")
        case .keyboardE: return scalar("e")
        case .keyboardF: return scalar("f")
        case .keyboardG: return scalar("g")
        case .keyboardH: return scalar("h")
        case .keyboardI: return scalar("i")
        case .keyboardJ: return scalar("j")
        case .keyboardK: return scalar("k")
        case .keyboardL: return scalar("l")
        case .keyboardM: return scalar("m")
        case .keyboardN: return scalar("n")
        case .keyboardO: return scalar("o")
        case .keyboardP: return scalar("p")
        case .keyboardQ: return scalar("q")
        case .keyboardR: return scalar("r")
        case .keyboardS: return scalar("s")
        case .keyboardT: return scalar("t")
        case .keyboardU: return scalar("u")
        case .keyboardV: return scalar("v")
        case .keyboardW: return scalar("w")
        case .keyboardX: return scalar("x")
        case .keyboardY: return scalar("y")
        case .keyboardZ: return scalar("z")
        case .keyboard1: return scalar("1")
        case .keyboard2: return scalar("2")
        case .keyboard3: return scalar("3")
        case .keyboard4: return scalar("4")
        case .keyboard5: return scalar("5")
        case .keyboard6: return scalar("6")
        case .keyboard7: return scalar("7")
        case .keyboard8: return scalar("8")
        case .keyboard9: return scalar("9")
        case .keyboard0: return scalar("0")
        case .keyboardHyphen: return scalar("-")
        case .keyboardEqualSign: return scalar("=")
        case .keyboardOpenBracket: return scalar("[")
        case .keyboardCloseBracket: return scalar("]")
        case .keyboardBackslash: return scalar("\\")
        case .keyboardSemicolon: return scalar(";")
        case .keyboardQuote: return scalar("'")
        case .keyboardGraveAccentAndTilde: return scalar("`")
        case .keyboardComma: return scalar(",")
        case .keyboardPeriod: return scalar(".")
        case .keyboardSlash: return scalar("/")
        case .keyboardSpacebar: return scalar(" ")
        default:
            return nil
        }
    }

    private func isKittyModifierKey(_ key: KittyFunctionalKey) -> Bool {
        switch key {
        case .leftShift, .rightShift,
             .leftControl, .rightControl,
             .leftAlt, .rightAlt,
             .leftSuper, .rightSuper,
             .capsLock, .numLock, .scrollLock,
             .isoLevel3Shift, .isoLevel5Shift:
            return true
        default:
            return false
        }
    }

    private var kittyIsComposing: Bool {
        _markedTextRange != nil
    }

    private func kittyTextEvent(from key: UIKey, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        guard let chars = key.charactersIgnoringModifiers.unicodeScalars.first else {
            return nil
        }
        let baseScalar = String(chars).lowercased().unicodeScalars.first ?? chars
        let shiftedScalar = key.modifierFlags.contains(.shift) ? key.characters.unicodeScalars.first : nil
        let baseLayout = kittyBaseLayoutKey(for: key.keyCode)
        let baseLayoutKey = baseLayout == baseScalar ? nil : baseLayout
        let modifiers = kittyModifiers(from: key, includeOption: optionAsMetaKey)
        return KittyKeyEvent(key: .unicode(baseScalar.value),
                             modifiers: modifiers,
                             eventType: eventType,
                             text: text,
                             shiftedKey: shiftedScalar,
                             baseLayoutKey: baseLayoutKey,
                             composing: kittyIsComposing)
    }

    private func kittyKeyEvent(from key: UIKey, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        if let functionKey = kittyFunctionalKey(for: key.keyCode) {
            let includeOption = optionAsMetaKey || functionKey == .leftAlt || functionKey == .rightAlt
            let modifiers = kittyModifiers(from: key, includeOption: includeOption)
            return KittyKeyEvent(key: .functional(functionKey),
                                 modifiers: modifiers,
                                 eventType: eventType,
                                 text: text,
                                 shiftedKey: nil,
                                 baseLayoutKey: nil,
                                 composing: kittyIsComposing)
        }
        return kittyTextEvent(from: key, eventType: eventType, text: text)
    }

    private func kittyTextEventFromText(_ text: String, modifiers: KittyKeyboardModifiers, eventType: KittyKeyboardEventType) -> KittyKeyEvent {
        return KittyKeyEvent(key: .none,
                             modifiers: modifiers,
                             eventType: eventType,
                             text: text,
                             shiftedKey: nil,
                             baseLayoutKey: nil,
                             composing: kittyIsComposing)
    }

    private func kittyTextForFunctionalKey(_ key: KittyFunctionalKey, uiKey: UIKey) -> String? {
        switch key {
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
             .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
             .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract,
             .keypadAdd, .keypadEqual, .keypadSeparator:
            let text = uiKey.characters
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    @discardableResult
    private func sendKittyEvent(_ event: KittyKeyEvent) -> Bool {
        guard let bytes = kittyEncoder().encode(event) else { return false }
        send(bytes)
        return true
    }

    private func sendKittyTextInput(_ text: String, applyModifiers: Bool) {
        let flags = terminal.keyboardEnhancementFlags
        let controlActive = applyModifiers && (terminalAccessory?.controlModifier ?? controlModifier ?? false)
        let metaActive = applyModifiers && metaModifier
        if controlActive {
            terminalAccessory?.controlModifier = false
            controlModifier = false
        }
        if metaActive {
            metaModifier = false
        }
        let pendingEvent = pendingKittyKeyEvent
        pendingKittyKeyEvent = nil

        if text == "\n" {
            resetInputBuffer()
            if flags.contains(.reportAllKeys) {
                var modifiers: KittyKeyboardModifiers = []
                if controlActive { modifiers.insert(.ctrl) }
                if metaActive { modifiers.insert(.alt) }
                _ = sendKittyEvent(KittyKeyEvent(key: .functional(.enter),
                                                 modifiers: modifiers,
                                                 eventType: .press,
                                                 text: nil,
                                                 shiftedKey: nil,
                                                 baseLayoutKey: nil,
                                                 composing: kittyIsComposing))
            } else {
                send(data: returnByteSequence [0...])
            }
            return
        }

        if controlActive && text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first {
            let baseScalar = String(scalar).lowercased().unicodeScalars.first ?? scalar
            var modifiers: KittyKeyboardModifiers = [.ctrl]
            if metaActive { modifiers.insert(.alt) }
            let event = KittyKeyEvent(key: .unicode(baseScalar.value),
                                      modifiers: modifiers,
                                      eventType: .press,
                                      text: nil,
                                      shiftedKey: nil,
                                      baseLayoutKey: nil,
                                      composing: kittyIsComposing)
            _ = sendKittyEvent(event)
            return
        }

        let event: KittyKeyEvent
        if text.unicodeScalars.count == 1,
           let pendingEvent,
           let kittyEvent = kittyTextEvent(from: pendingEvent.key, eventType: pendingEvent.eventType, text: text) {
            event = kittyEvent
        } else {
            let modifiers: KittyKeyboardModifiers = metaActive ? [.alt] : []
            event = kittyTextEventFromText(text, modifiers: modifiers, eventType: .press)
        }
        _ = sendKittyEvent(event)
    }

    private func sendBackspaceKey() {
        if terminal.keyboardEnhancementFlags.isEmpty {
            send([backspaceSendsControlH ? 8 : 0x7f])
            return
        }
        _ = sendKittyEvent(KittyKeyEvent(key: .functional(.backspace),
                                         modifiers: [],
                                         eventType: .press,
                                         text: nil,
                                         shiftedKey: nil,
                                         baseLayoutKey: nil,
                                         composing: kittyIsComposing))
    }

    // this is necessary because something in the iOS IME seems to prevent
    // the sequence  "ㅇ", "ㅜ", "ㅇ" from becoming "웅", and instead
    // it becomes "우" followed by "ㅇ"
    private func tryComposeKoreanFinal(_ text: String) -> Bool {
        guard isKoreanTextInput else { return false }
        guard _markedTextRange == nil else { return false }
        guard _selectedTextRange.isEmpty, _selectedTextRange.endPosition.offset == textInputStorage.textInputUTF16Count else { return false }
        guard text.count == 1, let jamo = text.first else { return false }
        guard let finalIndex = HangulInput.finalIndexByJamo[jamo] else { return false }
        guard let lastChar = textInputStorage.last else { return false }
        guard let composed = HangulInput.composeSyllable(base: lastChar, finalIndex: finalIndex) else { return false }

        uitiLog("koreanComposeFinal base:\(lastChar) jamo:\(jamo) -> \(composed)")

        beginTextInputEdit()
        textInputStorage.removeLast()
        textInputStorage.append(composed)
        let newOffset = textInputStorage.textInputUTF16Count
        _markedTextRange = nil
        _selectedTextRange = TextRange(from: TextPosition(offset: newOffset), to: TextPosition(offset: newOffset))
        endTextInputEdit()

        sendBackspaceKey()
        send(txt: String(composed))
        queuePendingDisplay()
        return true
    }

    /// Completes the delete -> prefix reinsert -> composed syllable sequence
    /// emitted by the Korean iOS keyboard when it moves a final consonant to
    /// the next syllable. When there was a character before the base syllable,
    /// replace UIKit's reinserted prefix with the complete corrected text. At
    /// the start of the input buffer, append the corrected text directly.
    private func processPendingKoreanResyllabification(_ text: String) -> PendingKoreanResyllabificationResult {
        guard isKoreanTextInput,
              _markedTextRange == nil,
              _selectedTextRange.isEmpty,
              _selectedTextRange.endPosition.offset == textInputStorage.textInputUTF16Count else {
            resetKoreanResyllabificationTransaction()
            return .none
        }

        switch koreanResyllabificationTransaction.consumeInsertion(text) {
        case .noMatch:
            return .none
        case .prefixReinserted:
            return .prefixReinserted
        case let .replacement(edit):
            guard edit.charactersToDelete <= textInputStorage.count else {
                return .none
            }
            if edit.charactersToDelete > 0 {
                let textToReplace = String(textInputStorage.suffix(edit.charactersToDelete))
                guard edit.textToInsert.hasPrefix(textToReplace) else { return .none }
            }

            uitiLog("koreanResyllabifyTransaction delete:\(edit.charactersToDelete) insert:\(edit.textToInsert.debugDescription)")

            beginTextInputEdit()
            for _ in 0..<edit.charactersToDelete {
                textInputStorage.removeLast()
            }
            textInputStorage.append(contentsOf: edit.textToInsert)
            let newOffset = textInputStorage.textInputUTF16Count
            _markedTextRange = nil
            _selectedTextRange = TextRange(from: TextPosition(offset: newOffset), to: TextPosition(offset: newOffset))
            endTextInputEdit()

            for _ in 0..<edit.charactersToDelete {
                sendBackspaceKey()
            }
            send(txt: edit.textToInsert)
            queuePendingDisplay()
            return .completed
        }
    }

    // If a vowel follows a syllable with a final consonant, Korean IMEs can
    // reinterpret that final consonant as the initial consonant of the next
    // syllable. For example, "핫" + "ㅔ" must replace "핫" with "하세",
    // preserving the previous syllable instead of sending only "세".
    private func tryResyllabifyKoreanFinalBeforeVowel(_ text: String) -> Bool {
        guard isKoreanTextInput else { return false }
        guard _markedTextRange == nil else { return false }
        guard _selectedTextRange.isEmpty, _selectedTextRange.endPosition.offset == textInputStorage.textInputUTF16Count else { return false }
        guard text.count == 1, let vowel = text.first else { return false }
        guard HangulInput.vowelIndexByJamo[vowel] != nil else { return false }
        guard let lastChar = textInputStorage.last else { return false }
        guard let edit = HangulInput.resyllabificationEdit(base: lastChar, followingVowel: vowel) else { return false }

        uitiLog("koreanResyllabifyFinal base:\(lastChar) vowel:\(vowel) delete:\(edit.charactersToDelete) insert:\(edit.textToInsert.debugDescription)")

        beginTextInputEdit()
        for _ in 0..<edit.charactersToDelete {
            textInputStorage.removeLast()
        }
        textInputStorage.append(contentsOf: edit.textToInsert)
        let newOffset = textInputStorage.textInputUTF16Count
        _markedTextRange = nil
        _selectedTextRange = TextRange(from: TextPosition(offset: newOffset), to: TextPosition(offset: newOffset))
        endTextInputEdit()

        for _ in 0..<edit.charactersToDelete {
            sendBackspaceKey()
        }
        send(txt: edit.textToInsert)
        queuePendingDisplay()
        return true
    }

    private func trackKoreanResyllabificationDeletion(_ deletedText: Substring, range: TextRange) {
        // Multiplex patch: deleted filler is not text the user composed, so it
        // must never open a resyllabification transaction — the buffer is all
        // filler whenever the count is non-zero.
        guard isKoreanTextInput,
              inputFillerCount == 0,
              _markedTextRange == nil,
              range.endPosition.offset == textInputStorage.textInputUTF16Count else {
            resetKoreanResyllabificationTransaction()
            return
        }

        koreanResyllabificationTransaction.begin(deletedText: String(deletedText))
    }

    func ensureCaretIsVisible ()
    {
        guard !terminal.synchronizedOutputActive else { return }
        let displayBuffer = terminal.displayBuffer
        let realCaret = displayBuffer.y + displayBuffer.yBase
        let viewportEnd = displayBuffer.yDisp + displayBuffer.rows

        if userScrolling || terminal.userScrolling || realCaret >= viewportEnd || realCaret < displayBuffer.yDisp {
            resetManualScrollTracking()
            updateScroller()
        }
    }
    
    open func deleteBackward() {
        uitiLog("deleteBackward() \(textInputStateDescription())")

        // Multiplex patch: make sure a held delete key has something to consume
        // before the ranges below are read. See the input filler section.
        seedInputFillerIfNeeded()

        // after backward deletion, marked range is always cleared, and length of selected range is always zero
        let rangeToDelete = _markedTextRange ?? _selectedTextRange
        var rangeStartPosition = rangeToDelete.startPosition
        var rangeStartIndex = rangeStartPosition.offset
        if rangeToDelete.isEmpty {
            resetKoreanResyllabificationTransaction()
            // If there is no selected text, delete the character before the cursor

            if rangeStartIndex == 0 {
                // This is the case when the user hits backspace, but there is no text in the
                // text input buffer.  This happens for example when text has been pasted.
                // In that scenario, we should just send the backspace character to the terminal
                pendingAutoPeriodDeleteWasSpace = false
                self.sendBackspaceKey()
                uitiLog("deleteBackward() no text to delete, sending backspace")
                return
            }

            beginTextInputEdit()

            guard let deleteRange = textInputStorage.textInputCharacterRange(beforeUTF16Offset: rangeStartIndex) else {
                pendingAutoPeriodDeleteWasSpace = false
                self.sendBackspaceKey()
                uitiLog("deleteBackward() no text to delete, sending backspace")
                endTextInputEdit()
                return
            }
            rangeStartIndex = textInputStorage.textInputUTF16Offset(of: deleteRange.lowerBound)
            let deletedChar = textInputStorage[deleteRange]
            let deletingAtEnd = rangeStartPosition.offset == textInputStorage.textInputUTF16Count
            pendingAutoPeriodDeleteWasSpace = deletingAtEnd && deletedChar == " " && _markedTextRange == nil
            textInputStorage.removeSubrange(deleteRange)
            rangeStartPosition = TextPosition(offset: rangeStartIndex)

            self.sendBackspaceKey()
        } else {
            pendingAutoPeriodDeleteWasSpace = false
            beginTextInputEdit()
            // Send as many backspaces that are in the range to delete. When on auto-repeat, after a some time
            // pressing the backspace, it will delete chunks of text at a time.
            let oldText = textInputStorage[rangeToDelete.fullRange(in: textInputStorage)]
            trackKoreanResyllabificationDeletion(oldText, range: rangeToDelete)
            let backspaces = oldText.count
            for _ in 0..<backspaces {
                self.sendBackspaceKey()
            }

            textInputStorage.removeSubrange(rangeToDelete.fullRange(in: textInputStorage))
        }
        
        _markedTextRange = nil
        // Multiplex patch: deleting a marked range ends composition, so do not
        // leave its purely local preview floating over the terminal.
        updateMarkedTextOverlay()
        _selectedTextRange = TextRange(from: rangeStartPosition, to: rangeStartPosition)

        endTextInputEdit()

        // Multiplex patch: re-stock the filler for the next repeat tick. The
        // buffer is all filler whenever the count is non-zero, so what survived
        // the delete is simply what is left. Restocking happens *after*
        // `endTextInputEdit` on purpose: the keyboard is told the shortened
        // document this delete produced — it has to see the delete do something
        // — and finds a full buffer again on its next read, so a held key never
        // runs the document dry. Deleting the last of the user's own typed text
        // lands here too, which is what lets a hold continue past it into text
        // the remote owns.
        if inputFillerCount > 0 {
            inputFillerCount = textInputStorage.count
        }
        seedInputFillerIfNeeded()
    }

    enum SendData {
        case text(String)
        case bytes([UInt8])
    }
    
    func sendData (data: SendData?)
    {
        switch data {
        case .bytes(let b):
            self.send (b)
        case .text(let txt):
            self.send (txt: txt)
        default:
            break
        }
    }
 
    /// Multiplex patch: claim Escape before the Mac text system applies its
    /// default cancel behavior. The normal `pressesBegan` path owns byte
    /// delivery; this no-op command only keeps the terminal and its window
    /// focused.
    open override var keyCommands: [UIKeyCommand]? {
        guard ProcessInfo.processInfo.isiOSAppOnMac else {
            return super.keyCommands
        }
        var commands = super.keyCommands ?? []
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(consumeMacEscape(_:))
        )
        if #available(iOS 15.0, *) {
            escape.wantsPriorityOverSystemBehavior = true
        }
        commands.append(escape)
        return commands
    }

    @objc private func consumeMacEscape(_ sender: UIKeyCommand) {}

    open override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            caretView?.updateCursorStyle()
            terminal.setTerminalFocus(true)
            // Multiplex patch: route Mac hardware Ctrl+chords to this view
            if ProcessInfo.processInfo.isiOSAppOnMac {
                TerminalView.macControlKeyTarget = self
                TerminalView.setupMacControlKeyBridgeIfNeeded()
            }
        }
        return response
    }
    
    open override func resignFirstResponder() -> Bool {
        let code = super.resignFirstResponder()
        
        if code {
            terminal.setTerminalFocus(false)
            caretView?.disableAnimations()
            caretView?.updateView()
            keyRepeat?.invalidate()
            keyRepeat = nil
            
            terminalAccessory?.cancelTimer()
        }
        return code
    }
    var keyRepeat: Timer?

    private struct PendingKittyKeyEvent {
        let key: UIKey
        let eventType: KittyKeyboardEventType
    }

    private var pendingKittyKeyEvent: PendingKittyKeyEvent?
    
    /// It looks like sending carriage return works on Unix and Windows remote hosts, so add that, but keeping a public
    /// property in case someone needs the return key to send different sequences.
    public var returnByteSequence: [UInt8] = [13]
    
    // Multiplex patch: on iOS-app-on-Mac ("Designed for iPad"), the hardware
    // keyboard is bridged through UIKit's text-input pipeline, and
    // UIKeyboardImpl translates Ctrl+character chords via the Cocoa
    // key-binding table — Ctrl+C resolves to the `noop:` selector (the
    // "Unsupported action selector noop:" log line) and is dropped before
    // pressesBegan, insertText, or responder key commands ever see it.
    // GameController's GCKeyboard observes the keyboard at the HID layer,
    // ahead of that pipeline, so one shared handler routes Ctrl+character
    // chords to whichever TerminalView is first responder. Real iPads keep
    // the pressesBegan path — this bridge never installs there.
    private static weak var macControlKeyTarget: TerminalView?
    private static var macControlKeyBridgeInstalled = false
    private static weak var macSecondaryClickTarget: TerminalView?
    private static var macSecondaryClickBridgeInstalled = false
    private static let macSecondaryClickDedupWindow: TimeInterval = 0.2
    private static let macBridgedPressLifetime: TimeInterval = 0.25
    private static let macPrefixFallbackDelay: TimeInterval = 0.06

    /// One prefix/fallback HID press already delivered by the Mac bridge.
    /// UIKit normally drops Ctrl+character before `pressesBegan`, but OS
    /// revisions can also surface Ctrl+B through `pressesBegan` or
    /// `insertText`. A short-lived receipt consumes that duplicate once.
    private struct MacBridgedPress {
        var hidUsage: Int
        var text: String
        var expiresAt: TimeInterval
    }

    private var macBridgedPresses: [MacBridgedPress] = []
    private var macPrefixFollowUpArmed = false
    private var macPendingPrefixKeyCode: GCKeyCode?
    private var macPendingPrefixFallback = ""
    private var macPendingPrefixShifted = false
    private var macPendingPrefixGeneration = 0

    /// Designed-for-iPad's UIKit pointer recognizer misses some physical Mac
    /// secondary-button reports. GameController sees the mouse at HID level;
    /// combine that button with UIPointerInteraction's absolute location and
    /// route it through the same local action chain. The UIKit recognizer stays
    /// installed for trackpads and synthetic pointer events.
    private static func setupMacSecondaryClickBridgeIfNeeded() {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              !macSecondaryClickBridgeInstalled
        else { return }
        macSecondaryClickBridgeInstalled = true
        for mouse in GCMouse.mice() {
            installMacSecondaryClickHandler(on: mouse)
        }
        for name in [Notification.Name.GCMouseDidConnect,
                     Notification.Name.GCMouseDidBecomeCurrent] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { note in
                installMacSecondaryClickHandler(on: note.object as? GCMouse)
            }
        }
    }

    private static func installMacSecondaryClickHandler(on mouse: GCMouse?) {
        guard let mouse, let button = mouse.mouseInput?.rightButton else { return }
        mouse.handlerQueue = .main
        button.pressedChangedHandler = { _, _, pressed in
            guard pressed,
                  let target = macSecondaryClickTarget,
                  let location = target.lastPointerLocation,
                  target.window != nil,
                  target.bounds.contains(location)
            else { return }
            target.handleSecondaryClick(at: location)
        }
    }

    private static func setupMacControlKeyBridgeIfNeeded() {
        guard ProcessInfo.processInfo.isiOSAppOnMac, !macControlKeyBridgeInstalled else { return }
        macControlKeyBridgeInstalled = true
        installMacControlKeyHandler(on: GCKeyboard.coalesced)
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect,
                                               object: nil, queue: .main) { note in
            installMacControlKeyHandler(on: note.object as? GCKeyboard)
        }
    }

    private static func installMacControlKeyHandler(on keyboard: GCKeyboard?) {
        guard let keyboard, let input = keyboard.keyboardInput else { return }
        // The receipt must exist before UIKit sees the same physical press.
        // GameController defaults to main; state it explicitly so another
        // consumer cannot move this shared keyboard's callbacks off UIKit's
        // ordered input path.
        keyboard.handlerQueue = .main
        input.keyChangedHandler = { input, _, keyCode, pressed in
            guard pressed,
                  let target = macControlKeyTarget,
                  target.isFirstResponder,
                  target.window?.isKeyWindow == true
            else { return }

            let controlHeld = input.button(forKeyCode: .leftControl)?.isPressed == true ||
                input.button(forKeyCode: .rightControl)?.isPressed == true
            let commandHeld = input.button(forKeyCode: .leftGUI)?.isPressed == true ||
                input.button(forKeyCode: .rightGUI)?.isPressed == true
            let optionHeld = input.button(forKeyCode: .leftAlt)?.isPressed == true ||
                input.button(forKeyCode: .rightAlt)?.isPressed == true
            let shiftHeld = input.button(forKeyCode: .leftShift)?.isPressed == true ||
                input.button(forKeyCode: .rightShift)?.isPressed == true

            // A non-modifier after bridged Ctrl+B is part of the same
            // multiplexer chord. UIKit on Designed for iPad can swallow this
            // first ordinary key while unwinding Cocoa's Ctrl+B binding. Give
            // `pressesBegan` one short turn to supply the layout-resolved
            // character; if it never arrives, send printable ANSI from HID.
            // This is deliberately one-key: ordinary typing remains owned by
            // the user's keyboard layout and IME.
            if !isMacModifierKey(keyCode),
               target.takeMacPrefixFollowUp(),
               !controlHeld,
               !commandHeld,
               !optionHeld,
               let character = macPlainCharacter(for: keyCode, shifted: shiftHeld) {
                target.scheduleMacPrefixFollowUp(
                    keyCode: keyCode,
                    fallback: character,
                    shifted: shiftHeld
                )
                return
            }

            guard controlHeld,
                  !commandHeld,
                  let character = macControlCharacter(for: keyCode)
            else { return }
            target.macPrefixFollowUpArmed = false
            target.cancelMacPrefixFollowUpForTextInput()
            if character == "b" {
                target.recordMacBridgedPress(keyCode: keyCode, text: character)
            }
            target.sendMacControl(character)
            if character == "b" {
                // A multiplexer waits for its next key, not for an app-authored
                // deadline. Keep the bridge armed until that one key arrives.
                target.macPrefixFollowUpArmed = true
            }
        }
    }

    private static func isMacModifierKey(_ keyCode: GCKeyCode) -> Bool {
        switch keyCode {
        case .leftControl, .rightControl, .leftShift, .rightShift,
             .leftAlt, .rightAlt, .leftGUI, .rightGUI:
            true
        default:
            false
        }
    }

    /// HID key → the character `applyControlToEventCharacters` expects.
    /// Letters assume an ANSI-ish layout — the same simplification every
    /// terminal makes for control chords.
    private static func macControlCharacter(for keyCode: GCKeyCode) -> String? {
        if keyCode.rawValue >= GCKeyCode.keyA.rawValue && keyCode.rawValue <= GCKeyCode.keyZ.rawValue {
            // HID A–Z are contiguous (0x04–0x1D)
            let scalar = UnicodeScalar(UInt8(ascii: "a") + UInt8(keyCode.rawValue - GCKeyCode.keyA.rawValue))
            return String(scalar)
        }
        switch keyCode {
        case .spacebar:     return " "
        case .openBracket:  return "["
        case .closeBracket: return "]"
        case .backslash:    return "\\"
        case .six:          return "6"   // Ctrl+6 / Ctrl+^ → RS (0x1e)
        case .hyphen:       return "_"   // Ctrl+- / Ctrl+_ → US (0x1f)
        default:            return nil
        }
    }

    /// ANSI printable fallback for the one key following bridged Ctrl+B.
    /// Normal text never takes this path; UIKit still owns layout and IME.
    private static func macPlainCharacter(for keyCode: GCKeyCode, shifted: Bool) -> String? {
        if keyCode.rawValue >= GCKeyCode.keyA.rawValue && keyCode.rawValue <= GCKeyCode.keyZ.rawValue {
            let offset = UInt8(keyCode.rawValue - GCKeyCode.keyA.rawValue)
            let base = shifted ? UInt8(ascii: "A") : UInt8(ascii: "a")
            return String(UnicodeScalar(base + offset))
        }

        let digitKeys: [GCKeyCode] = [
            .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero
        ]
        if let index = digitKeys.firstIndex(of: keyCode) {
            let plain = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
            let upper = ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"]
            return shifted ? upper[index] : plain[index]
        }

        switch keyCode {
        case .spacebar: return " "
        case .hyphen: return shifted ? "_" : "-"
        case .equalSign: return shifted ? "+" : "="
        case .openBracket: return shifted ? "{" : "["
        case .closeBracket: return shifted ? "}" : "]"
        case .backslash: return shifted ? "|" : "\\"
        case .semicolon: return shifted ? ":" : ";"
        case .quote: return shifted ? "\"" : "'"
        case .graveAccentAndTilde: return shifted ? "~" : "`"
        case .comma: return shifted ? "<" : ","
        case .period: return shifted ? ">" : "."
        case .slash: return shifted ? "?" : "/"
        default: return nil
        }
    }

    private func takeMacPrefixFollowUp() -> Bool {
        guard macPrefixFollowUpArmed else { return false }
        macPrefixFollowUpArmed = false
        return true
    }

    private func scheduleMacPrefixFollowUp(
        keyCode: GCKeyCode,
        fallback: String,
        shifted: Bool
    ) {
        pruneMacBridgedPresses()
        let usage = Int(keyCode.rawValue)
        // A new physical key proves UIKit has finished dispatching the Ctrl+B
        // key-down. Do not let that old receipt eat a same-letter follow-up.
        macBridgedPresses.removeAll { $0.hidUsage == usage }
        macPendingPrefixGeneration += 1
        let generation = macPendingPrefixGeneration
        macPendingPrefixKeyCode = keyCode
        macPendingPrefixFallback = fallback
        macPendingPrefixShifted = shifted
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.macPrefixFallbackDelay) { [weak self] in
            guard let self,
                  self.macPendingPrefixGeneration == generation,
                  self.macPendingPrefixKeyCode == keyCode
            else { return }
            self.macPendingPrefixKeyCode = nil
            self.recordMacBridgedPress(keyCode: keyCode, text: fallback)
            self.sendMacPrefixFollowUp(
                keyCode: keyCode,
                text: fallback,
                shifted: shifted
            )
        }
    }

    /// UIKit has a real key event, so cancel the HID timer and let the ordinary
    /// `pressesBegan` pipeline retain layout, IME, and Kitty metadata.
    private func macPrefixFollowUpWillUseUIKit(_ key: UIKey) {
        guard macPendingPrefixKeyCode?.rawValue == key.keyCode.rawValue else { return }
        macPendingPrefixKeyCode = nil
        macPendingPrefixGeneration += 1
    }

    /// Some Mac text-system paths call `insertText` without exposing a
    /// `pressesBegan`. Pair that layout-resolved text with the HID key metadata
    /// rather than degrading it to a paste/text event while a multiplexer is
    /// waiting for a key.
    private func sendPendingMacPrefixTextInput(_ text: String) -> Bool {
        guard let keyCode = macPendingPrefixKeyCode else { return false }
        let fallback = macPendingPrefixFallback
        let shifted = macPendingPrefixShifted
        macPendingPrefixKeyCode = nil
        macPendingPrefixGeneration += 1
        sendMacPrefixFollowUp(
            keyCode: keyCode,
            text: text.isEmpty ? fallback : text,
            shifted: shifted
        )
        return true
    }

    private func cancelMacPrefixFollowUpForTextInput() {
        guard macPendingPrefixKeyCode != nil else { return }
        macPendingPrefixKeyCode = nil
        macPendingPrefixGeneration += 1
    }

    /// A raw printable byte is a text event under Kitty's report-all-keys mode;
    /// Herdr inserts it into the pane and leaves PREFIX armed. Reconstruct the
    /// same Unicode key event UIKit would have emitted so the multiplexer sees
    /// its binding. Legacy terminals still receive the ordinary text byte.
    private func sendMacPrefixFollowUp(
        keyCode: GCKeyCode,
        text: String,
        shifted: Bool
    ) {
        guard !terminal.keyboardEnhancementFlags.isEmpty,
              text.unicodeScalars.count == 1,
              let textScalar = text.unicodeScalars.first,
              let physicalBase = Self.macPlainCharacter(for: keyCode, shifted: false)?
                .unicodeScalars.first
        else {
            send(txt: text)
            return
        }

        let baseScalar = String(textScalar).lowercased().unicodeScalars.first ?? textScalar
        let baseLayoutKey = physicalBase == baseScalar ? nil : physicalBase
        _ = sendKittyEvent(KittyKeyEvent(
            key: .unicode(baseScalar.value),
            modifiers: shifted ? [.shift] : [],
            eventType: .press,
            text: text,
            shiftedKey: shifted ? textScalar : nil,
            baseLayoutKey: baseLayoutKey,
            composing: false
        ))
    }

    private func recordMacBridgedPress(keyCode: GCKeyCode, text: String) {
        pruneMacBridgedPresses()
        let usage = Int(keyCode.rawValue)
        macBridgedPresses.removeAll { $0.hidUsage == usage }
        macBridgedPresses.append(MacBridgedPress(
            hidUsage: usage,
            text: text,
            expiresAt: ProcessInfo.processInfo.systemUptime + Self.macBridgedPressLifetime
        ))
    }

    private func consumeMacBridgedPress(keyCode: UIKeyboardHIDUsage) -> Bool {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return false }
        pruneMacBridgedPresses()
        guard let index = macBridgedPresses.firstIndex(where: {
            $0.hidUsage == Int(keyCode.rawValue)
        }) else { return false }
        macBridgedPresses.remove(at: index)
        return true
    }

    private func consumeMacBridgedText(_ text: String) -> Bool {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return false }
        pruneMacBridgedPresses()
        guard let index = macBridgedPresses.firstIndex(where: { $0.text == text })
        else { return false }
        macBridgedPresses.remove(at: index)
        return true
    }

    private func pruneMacBridgedPresses() {
        let now = ProcessInfo.processInfo.systemUptime
        macBridgedPresses.removeAll { $0.expiresAt < now }
    }

    /// Multiplex patch: synchronous HID-level read of the physical Shift keys
    /// for the commitTextInput Shift+Return rewrite. Mac-only by construction;
    /// Ctrl/Cmd combos keep their existing meanings.
    private func macPhysicalShiftHeld() -> Bool {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        guard input.button(forKeyCode: .leftShift)?.isPressed == true ||
              input.button(forKeyCode: .rightShift)?.isPressed == true else { return false }
        guard input.button(forKeyCode: .leftControl)?.isPressed != true,
              input.button(forKeyCode: .rightControl)?.isPressed != true,
              input.button(forKeyCode: .leftGUI)?.isPressed != true,
              input.button(forKeyCode: .rightGUI)?.isPressed != true else { return false }
        return true
    }

    func sendMacControl(_ character: String) {
        if !terminal.keyboardEnhancementFlags.isEmpty,
           character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first {
            _ = sendKittyEvent(KittyKeyEvent(key: .unicode(scalar.value),
                                             modifiers: [.ctrl],
                                             eventType: .press,
                                             text: nil,
                                             shiftedKey: nil,
                                             baseLayoutKey: nil,
                                             composing: kittyIsComposing))
            return
        }
        let bytes = applyControlToEventCharacters(character)
        if !bytes.isEmpty {
            send(bytes)
        }
    }

    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var didHandleEvent = false
        let wasCommandActive = commandActive
        let kittyFlags = terminal.keyboardEnhancementFlags

        if _markedTextRange != nil {
            pendingKittyKeyEvent = nil
            super.pressesBegan(presses, with: event)
            return
        }
        if !kittyFlags.isEmpty {
            pendingKittyKeyEvent = nil
        }
        
        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardLeftGUI || key.keyCode == .keyboardRightGUI {
                activeCommandKeys.insert(key.keyCode)
            }
            if key.modifierFlags.contains(.command) || !activeCommandKeys.isEmpty {
                commandActive = true
            }
            uitiLog("pressesBegan keyCode:\(key.keyCode) chars:\(key.characters.debugDescription) ignoring:\(key.charactersIgnoringModifiers.debugDescription) modifiers:\(key.modifierFlags)")
            // Multiplex patch: GameController already sent this Mac hardware
            // key. Consume UIKit's duplicate before either the kitty or legacy
            // branch can emit it a second time.
            if consumeMacBridgedPress(keyCode: key.keyCode) {
                didHandleEvent = true
                continue
            }
            macPrefixFollowUpWillUseUIKit(key)
            if !kittyFlags.isEmpty {
                if key.modifierFlags.contains([.alternate, .command]) && key.charactersIgnoringModifiers == "o" {
                    optionAsMetaKey.toggle()
                    didHandleEvent = true
                    continue
                }
                let repeatEventType: KittyKeyboardEventType = kittyFlags.contains(.reportEvents) ? .repeatPress : .press
                if let functionKey = kittyFunctionalKey(for: key.keyCode) {
                    let isModifierKey = isKittyModifierKey(functionKey)
                    if isModifierKey && !kittyFlags.contains(.reportAllKeys) {
                        continue
                    }
                    if (functionKey == .pageUp || functionKey == .pageDown) && !terminal.applicationCursor {
                        if functionKey == .pageUp {
                            pageUp()
                        } else {
                            pageDown()
                        }
                        didHandleEvent = true
                        continue
                    }
                    let includeOption = optionAsMetaKey || functionKey == .leftAlt || functionKey == .rightAlt
                    let modifiers = kittyModifiers(from: key, includeOption: includeOption)
                    let functionKeyText = kittyTextForFunctionalKey(functionKey, uiKey: key)
                    let pressEvent = KittyKeyEvent(key: .functional(functionKey),
                                                   modifiers: modifiers,
                                                   eventType: .press,
                                                   text: functionKeyText,
                                                   shiftedKey: nil,
                                                   baseLayoutKey: nil,
                                                   composing: kittyIsComposing)
                    if sendKittyEvent(pressEvent) {
                        didHandleEvent = true
                        keyRepeat?.invalidate()
                        if !isModifierKey {
                            keyRepeat = Timer(fire: Date(timeInterval: 0.4, since: Date()),
                                              interval: 0.1,
                                              repeats: true) { _ in
                                let repeatEvent = KittyKeyEvent(key: .functional(functionKey),
                                                                modifiers: modifiers,
                                                                eventType: repeatEventType,
                                                                text: functionKeyText,
                                                                shiftedKey: nil,
                                                                baseLayoutKey: nil,
                                                                composing: self.kittyIsComposing)
                                _ = self.sendKittyEvent(repeatEvent)
                            }
                            RunLoop.current.add(keyRepeat!, forMode: .default)
                        }
                    }
                    continue
                }
                if key.modifierFlags.contains(.control) || (optionAsMetaKey && key.modifierFlags.contains(.alternate)) {
                    if let kittyEvent = kittyTextEvent(from: key, eventType: .press),
                       sendKittyEvent(kittyEvent) {
                        didHandleEvent = true
                        let modifiers = kittyEvent.modifiers
                        keyRepeat?.invalidate()
                        keyRepeat = Timer(fire: Date(timeInterval: 0.4, since: Date()),
                                          interval: 0.1,
                                          repeats: true) { _ in
                            let repeatEvent = KittyKeyEvent(key: kittyEvent.key,
                                                            modifiers: modifiers,
                                                            eventType: repeatEventType,
                                                            text: nil,
                                                            shiftedKey: kittyEvent.shiftedKey,
                                                            baseLayoutKey: nil,
                                                            composing: self.kittyIsComposing)
                            _ = self.sendKittyEvent(repeatEvent)
                        }
                        RunLoop.current.add(keyRepeat!, forMode: .default)
                        continue
                    }
                }
                pendingKittyKeyEvent = PendingKittyKeyEvent(key: key, eventType: .press)
                continue
            }
                
            var data: SendData? = nil

            switch key.keyCode {
            case .keyboardCapsLock:
                break // ignored
            case .keyboardLeftAlt:
                break // ignored
            case .keyboardLeftControl:
                break // ignored
            case .keyboardLeftGUI:
                commandActive = true
                break // ignored
            case .keyboardLeftShift:
                break // ignored
            case .keyboardLockingCapsLock:
                break // ignored
            case .keyboardLockingNumLock:
                break // ignored
            case .keyboardLockingScrollLock:
                break // ignored
            case .keyboardRightAlt:
                break // ignored
            case .keyboardRightControl:
                break // ignored
            case .keyboardRightGUI:
                commandActive = true
                break // ignored
            case .keyboardRightShift:
                break // ignored
            case .keyboardScrollLock:
                break // ignored
            case .keyboardUpArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
            case .keyboardDownArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            case .keyboardLeftArrow:
                if key.modifierFlags.contains ([.alternate]) {
                    data = .bytes (EscapeSequences.emacsBack)
                } else if key.modifierFlags.contains ([.control]) {
                    data = .bytes (EscapeSequences.controlLeft)
                } else {
                    data = .bytes (terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
                }
            case .keyboardRightArrow:
                if key.modifierFlags.contains ([.alternate]) {
                    data = .bytes (EscapeSequences.emacsForward)
                } else if key.modifierFlags.contains ([.control]) {
                    data = .bytes (EscapeSequences.controlRight)
                } else {
                    data = .bytes (terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
                }
            case .keyboardPageUp:
                if terminal.applicationCursor {
                    data = .bytes (EscapeSequences.cmdPageUp)
                } else {
                    pageUp()
                }

            case .keyboardPageDown:
                if terminal.applicationCursor {
                    data = .bytes (EscapeSequences.cmdPageDown)
                } else {
                    pageDown()
                }
            case .keyboardHome:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
                
            case .keyboardEnd:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
            case .keyboardDeleteForward:
                data = .bytes (EscapeSequences.cmdDelKey)
                
            case .keyboardEscape:
                data = .bytes ([0x1b])
                
            case .keyboardInsert:
                print (".keyboardInsert ignored")
                break
                
            case .keyboardTab:
                if key.modifierFlags.contains ([.shift]) {
                    data = .bytes (EscapeSequences.cmdBackTab)
                } else {
                    data = .bytes ([9])
                }

            case .keyboardF1:
                data = .bytes (EscapeSequences.cmdF [0])
            case .keyboardF2:
                data = .bytes (EscapeSequences.cmdF [1])
            case .keyboardF3:
                data = .bytes (EscapeSequences.cmdF [2])
            case .keyboardF4:
                data = .bytes (EscapeSequences.cmdF [3])
            case .keyboardF5:
                data = .bytes (EscapeSequences.cmdF [4])
            case .keyboardF6:
                data = .bytes (EscapeSequences.cmdF [5])
            case .keyboardF7:
                data = .bytes (EscapeSequences.cmdF [6])
            case .keyboardF8:
                data = .bytes (EscapeSequences.cmdF [7])
            case .keyboardF9:
                data = .bytes (EscapeSequences.cmdF [8])
            case .keyboardF10:
                data = .bytes (EscapeSequences.cmdF [8])
            case .keyboardF11:
                data = .bytes (EscapeSequences.cmdF [10])
            case .keyboardF12, .keyboardF13, .keyboardF14, .keyboardF15, .keyboardF16,
                 .keyboardF17, .keyboardF18, .keyboardF19, .keyboardF20, .keyboardF21,
                 .keyboardF22, .keyboardF23, .keyboardF24:
                break
            case .keyboardPause, .keyboardStop, .keyboardMute, .keyboardVolumeUp, .keyboardVolumeDown:
                break

            // Multiplex patch: without kitty flags there is no protocol-level
            // Shift+Enter, and UIKit's text-input fallback (insertText "\n")
            // drops the physical Shift modifier — so claim the press here and
            // send LF (Ctrl+J). Every CLI agent composer treats LF as
            // insert-newline (Claude Code, Codex, Pi — verified under tmux
            // 3.6a, which forwards the byte untouched), while shells and
            // full-screen apps treat it like Enter. Unmodified Return keeps
            // the UIKit path so IME commits stay intact.
            case .keyboardReturnOrEnter, .keyboardReturn, .keypadEnter:
                if key.modifierFlags.contains(.shift) {
                    data = .bytes([10])
                } else {
                    fallthrough
                }

            default:
                if key.modifierFlags.contains ([.alternate, .command]) && key.charactersIgnoringModifiers == "o" {
                    optionAsMetaKey.toggle()
                } else if (key.modifierFlags.contains (.alternate) && optionAsMetaKey) || metaModifier {
                    data = .text("\u{1b}\(key.charactersIgnoringModifiers)")
                    metaModifier = false
                } else if key.modifierFlags.contains (.control) {
                    let controlBytes = applyControlToEventCharacters(key.charactersIgnoringModifiers)
                    if !controlBytes.isEmpty {
                        data = .bytes(controlBytes)
                    }
                }
            }
            if let sendableData = data {
                didHandleEvent = true
                keyRepeat?.invalidate()
                keyRepeat = Timer (fire: Date(timeInterval: 0.4, since: Date()),
                                   interval: 0.1,
                                   repeats: true) { timer in
                    self.sendData(data: sendableData)
                }
                RunLoop.current.add(keyRepeat!, forMode: .default)
                sendData (data: sendableData)
            }
        }
        if commandActive != wasCommandActive {
            if let point = lastPointerLocation {
                reportLinkIfNeeded(at: point, modifiers: [.command], force: true)
                updateLinkHighlightIfNeeded(at: point, modifiers: [.command], force: true)
            }
            if linkHighlightMode == .alwaysWithModifier {
                terminal.updateFullScreen()
            }
            if linkHighlightMode == .alwaysWithModifier || linkHighlightMode == .hoverWithModifier {
                queuePendingDisplay()
            }
        }
        if didHandleEvent == false {
            super.pressesBegan(presses, with: event)
        }
    }
    
    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keyRepeat?.invalidate()
        keyRepeat = nil
        let wasCommandActive = commandActive
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardLeftGUI, .keyboardRightGUI:
                activeCommandKeys.remove(key.keyCode)
            default:
                break
            }
        }
        commandActive = !activeCommandKeys.isEmpty
        if !commandActive {
            lastReportedLink = nil
            if linkHighlightMode == .hoverWithModifier {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
            }
        }
        if commandActive != wasCommandActive {
            if linkHighlightMode == .alwaysWithModifier {
                terminal.updateFullScreen()
            }
            if linkHighlightMode == .alwaysWithModifier || linkHighlightMode == .hoverWithModifier {
                queuePendingDisplay()
            }
        }
        let flags = terminal.keyboardEnhancementFlags
        if flags.contains(.reportEvents) {
            for press in presses {
                guard let key = press.key else { continue }
                let hasAltOrCtrl = key.modifierFlags.contains(.control) || (optionAsMetaKey && key.modifierFlags.contains(.alternate))
                let functionKey = kittyFunctionalKey(for: key.keyCode)
                if let functionKey, isKittyModifierKey(functionKey) && !flags.contains(.reportAllKeys) {
                    continue
                }
                if let functionKey,
                   !flags.contains(.reportAllKeys),
                   (functionKey == .tab || functionKey == .enter || functionKey == .backspace) {
                    continue
                }
                let shouldHandle = flags.contains(.reportAllKeys) || hasAltOrCtrl || functionKey != nil
                if shouldHandle, let kittyEvent = kittyKeyEvent(from: key, eventType: .release, text: nil) {
                    _ = sendKittyEvent(kittyEvent)
                }
            }
        }
        super.pressesEnded(presses, with: event)
    }
    
    var pendingSelectionChanged = false
    
    var buttonBackgroundColor: UIColor = .white
    var buttonShadowColor: UIColor = .black
    var buttonColor: UIColor = .black
    var buttonDarkBackgroundColor: UIColor = .systemGray
    func setupKeyboardButtonColors ()
    {
        func getColor (_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            return UIColor (red: r/255.0, green: g/255.0, blue: b/255.0, alpha: 1.0)
        }
        if traitCollection.userInterfaceStyle == .dark {
            buttonBackgroundColor = UIColor (red: 150/255.0, green: 150/255.0, blue: 150/255.0, alpha: 1)
            buttonShadowColor = UIColor (red: 26/255.0, green: 26/255.0, blue: 26/255.0, alpha: 1)
            buttonColor = .white
            buttonDarkBackgroundColor = getColor (117, 117, 117)
        } else {
            buttonBackgroundColor = UIColor (red: 1, green: 1, blue: 1, alpha: 1)
            buttonShadowColor = UIColor (red: 139/255.0, green: 141/255.0, blue: 144/255.0, alpha: 1)
            buttonColor = .black
            buttonDarkBackgroundColor = getColor (180, 184, 193)
        }
    }
    
    open func showCursor(source: Terminal) {
        guard let caretView else { return }
        if caretView.superview == nil {
            addSubview(caretView)
        }
    }

    open func hideCursor(source: Terminal) {
        caretView?.removeFromSuperview()
    }
    
    open func cursorStyleChanged (source: Terminal, newStyle: CursorStyle) {
        caretView?.style = newStyle
        updateCaretView()
    }
    open func bell(source: Terminal) {
        terminalDelegate?.bell (source: self)
    }

    public func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        if Thread.isMainThread {
            handleProgressReport(report)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleProgressReport(report)
            }
        }
    }

    open func selectionChanged(source: Terminal) {
        if pendingSelectionChanged {
            return
        }
        pendingSelectionChanged = true
        DispatchQueue.main.async {
            self.pendingSelectionChanged = false

            self.inputDelegate?.selectionWillChange (self)
            self.inputDelegate?.selectionDidChange(self)

            // Multiplex patch: report the selection's content-coordinate
            // box to the app-owned selection chrome (nil = cleared).
            self.selectionUIHandler?(self.selectionUIRect())
 
#if canImport(MetalKit)
            if self.metalView != nil {
                self.metalDirtyRange = self.metalVisibleRange()
                self.queueMetalDisplay()
            } else {
                self.setNeedsDisplay(self.bounds)
            }
#else
            self.setNeedsDisplay(self.bounds)
#endif
            
            if !self.selection.active {
                // Multiplex patch: route through hideContextMenu so this view's
                // own record of the menu is cleared with it.
                self.hideContextMenu()
                self.selection.selectNone()
                self.disableSelectionPanGesture()
            }
        }
    }

    open func isProcessTrusted(source: Terminal) -> Bool {
        true
    }

    open func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        let scale = getImageScale()
        let width = Int(round(cellDimension.width * scale))
        let height = Int(round(cellDimension.height * scale))
        return (width, height)
    }
    
    open func mouseModeChanged(source: Terminal) {
        // Multiplex patch: pan handling depends on mouse mode *and* the
        // active buffer — recompute both here and in bufferActivated.
        updateRemotePanGesture()
    }
    
    open func setTerminalTitle(source: Terminal, title: String) {
        DispatchQueue.main.async {
            self.terminalDelegate?.setTerminalTitle(source: self, title: title)
        }
    }
  
    open func sizeChanged(source: Terminal) {
        DispatchQueue.main.async {
            self.terminalDelegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
            self.updateScroller()
        }
    }
  
    open func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
  
    // Terminal.Delegate method implementation
    open func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        switch command {
        case .reportTextAreaPixelDimension, .reportTerminalWindowPixelDimension:
            guard let cellSize = cellSizeInPixels(source: source) else { return nil }
            let height = cellSize.height * source.rows
            let width = cellSize.width * source.cols
            return source.cc.CSI + "4;\(height);\(width)t".utf8
        case .reportSizeOfScreenInPixels:
            guard let cellSize = cellSizeInPixels(source: source) else { return nil }
            let height = cellSize.height * source.rows
            let width = cellSize.width * source.cols
            return source.cc.CSI + "5;\(height);\(width)t".utf8
        case .reportCellSizeInPixels:
            guard let cellSize = cellSizeInPixels(source: source) else { return nil }
            return source.cc.CSI + "6;\(cellSize.height);\(cellSize.width)t".utf8
        default:
            return nil
        }
    }
    
    public func clipboardCopy(source: Terminal, content: Data) {
        terminalDelegate?.clipboardCopy(source: self, content: content)
    }
    
    public func clipboardRead(source: Terminal) -> Data? {
        return terminalDelegate?.clipboardRead(source: self)
    }

    public func iTermContent (source: Terminal, content: ArraySlice<UInt8>) {
        terminalDelegate?.iTermContent(source: self, content: content)
    }
}

// Multiplex patch: delegate for the remote-scroll pan. A separate object —
// not TerminalView itself — so UIScrollView's private gesture-delegate
// behavior for its own recognizers is left untouched. Yields when a text
// selection is being dragged, and re-checks the remote-scroll conditions
// live (they can drift between enabling the gesture and the pan starting).
private class RemoteScrollGestureGate: NSObject, UIGestureRecognizerDelegate {
    weak var terminalView: TerminalView?

    init (terminalView: TerminalView) {
        self.terminalView = terminalView
    }

    func gestureRecognizerShouldBegin (_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = terminalView else { return false }
        return view.shouldBeginRemoteScroll(gestureRecognizer)
    }
}

// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {
    public func bell (source: TerminalView)
    {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
        #endif
    }
    
    public func iTermContent (source: TerminalView, content: ArraySlice<UInt8>) {
    }
    
    public func clipboardCopy(source: TerminalView, content: Data) {
    }
    
    public func clipboardRead(source: TerminalView) -> Data? {
        return nil
    }
}

extension TerminalView: UIAccessibilityReadingContent {
    private func accessibilityBaseAttributes() -> [NSAttributedString.Key: Any] {
        getAttributes(CharData.defaultAttr, withUrl: false) ?? [.font: fontSet.normal]
    }

    private func accessibilityAttributedLine(_ row: Int, endCol: Int = -1) -> NSAttributedString {
        guard row >= 0, row < terminal.displayBuffer.lines.count else {
            return NSAttributedString(string: "")
        }

        let line = terminal.displayBuffer.lines[row]
        let rawLimit = endCol == -1 ? line.count : min(endCol, line.count)
        let lineLimit = min(rawLimit, line.getTrimmedLength())
        guard line.hasAnyContent(), lineLimit > 0 else {
            return NSAttributedString(string: "")
        }

        let lineInfo = buildAttributedString(row: row, line: line, cols: lineLimit)
        let result = NSMutableAttributedString()
        for segment in lineInfo.segments {
            result.append(segment.attributedString)
        }
        return result
    }

    private func accessibilityAttributedDisplayText(start: Position, end: Position) -> NSAttributedString {
        let buffer = terminal.displayBuffer
        guard !buffer.lines.isEmpty else {
            return NSAttributedString(string: "")
        }

        var start = start
        var end = end

        switch Position.compare(start, end) {
        case .equal:
            return NSAttributedString(string: "")
        case .after:
            swap(&start, &end)
        case .before:
            break
        }

        guard start.row >= 0, start.row <= buffer.lines.count else {
            return NSAttributedString(string: "")
        }

        if end.row >= buffer.lines.count {
            end.row = buffer.lines.count - 1
        }

        let newline = NSAttributedString(string: "\n", attributes: accessibilityBaseAttributes())
        var lines: [NSMutableAttributedString] = [NSMutableAttributedString()]
        var currentLine = lines[0]
        var blanks: [NSMutableAttributedString] = []

        func addBlanks() {
            guard !blanks.isEmpty else {
                return
            }
            for blank in blanks {
                lines.append(blank)
            }
            currentLine = blanks.last!
            blanks.removeAll()
        }

        var bufferLine = buffer.lines[start.row]
        if bufferLine.hasAnyContent() {
            currentLine.append(accessibilityAttributedLine(start.row, endCol: start.row < end.row ? -1 : end.col))
        }

        var line = start.row + 1
        var isWrapped = false
        while line < end.row {
            bufferLine = buffer.lines[line]
            isWrapped = bufferLine.isWrapped

            if bufferLine.hasAnyContent() {
                addBlanks()

                if !isWrapped {
                    currentLine = NSMutableAttributedString()
                    lines.append(currentLine)
                }

                currentLine.append(accessibilityAttributedLine(line))
            } else {
                if !isWrapped || blanks.isEmpty {
                    blanks.append(NSMutableAttributedString())
                }
            }

            line += 1
        }

        if end.row != start.row {
            bufferLine = buffer.lines[end.row]
            if bufferLine.hasAnyContent() {
                addBlanks()

                isWrapped = bufferLine.isWrapped
                if !isWrapped {
                    currentLine = NSMutableAttributedString()
                    lines.append(currentLine)
                }

                currentLine.append(accessibilityAttributedLine(end.row, endCol: end.col))
            }
        }

        let result = NSMutableAttributedString()
        for (index, attributedLine) in lines.enumerated() {
            if index > 0 {
                result.append(newline)
            }
            result.append(attributedLine)
        }
        return result
    }

    public func accessibilityLineNumber(for point: CGPoint) -> Int {
        return Int(floor(max(point.y,0) / cellDimension.height))
    }
    
    func startingLine(forLineNumber lineNumber: Int) -> Int {
        let lineWidth = terminal.buffer.lines[lineNumber].count
        var startingLine = lineNumber
        while startingLine >= 1 {
            startingLine -= 1
            if terminal.buffer.lines[startingLine + 1].isWrapped {
                continue
            }
            let start = Position(col: 0, row: startingLine)
            let end = Position(col: terminal.buffer.lines[startingLine].count, row: startingLine)
            let text =  terminal.getDisplayText(start: start, end: end)
            if (text.count != terminal.buffer.lines[startingLine].count || text.last != " ") {
                // previous line is incomplete. Don't use it
                startingLine += 1
                break
            }
        }
        return startingLine
    }

    func endingLine(forLineNumber lineNumber: Int) -> Int {
        let lineWidth = terminal.buffer.lines[lineNumber].count
        var endingLine = lineNumber
        while (endingLine < terminal.buffer.lines.count - 1) {
            let start = Position(col: 0, row: endingLine)
            let end = Position(col: terminal.buffer.lines[endingLine].count, row: endingLine)
            let text =  terminal.getDisplayText(start: start, end: end)
            if (text.count != terminal.buffer.lines[endingLine].count || text.last != " ")
            && !terminal.buffer.lines[endingLine + 1].isWrapped {
                // this line is incomplete. We stop here.
                break
            }
            endingLine += 1
        }
        return endingLine
    }

    public func accessibilityContent(forLineNumber lineNumber: Int) -> String? {
        var startingLine = startingLine(forLineNumber: lineNumber)
        var endingLine = endingLine(forLineNumber: lineNumber)
        let start = Position(col: 0, row: startingLine)
        let end = Position(col: terminal.buffer.lines[endingLine].count,
                           row: endingLine)
        var text =  terminal.getDisplayText(start: start, end: end)
        return terminal.getDisplayText(start: start, end: end)
    }

    public func accessibilityFrame(forLineNumber lineNumber: Int) -> CGRect {
        let topVisibleLine = Int(contentOffset.y/cellDimension.height)
        let offset = contentOffset.y - CGFloat(topVisibleLine) * cellDimension.height
        var startingLine = startingLine(forLineNumber: lineNumber)
        var endingLine = endingLine(forLineNumber: lineNumber)
        var verticalWidth = CGFloat(endingLine - startingLine + 1)
        let lineOffset =  cellDimension.height * CGFloat (startingLine - topVisibleLine + 1)
        let lineOrigin = CGPoint(x: 0, y: lineOffset)
        let columnCount = terminal.buffer.lines[lineNumber].count
        var rect = CGRect(
            x: lineOrigin.x,
            y: lineOrigin.y + 3 - offset,
            width: CGFloat(columnCount) * cellDimension.width,
            height: verticalWidth * cellDimension.height)
        return rect
    }

    public func accessibilityPageContent() -> String? {
        let pageHeight = max(bounds.height, cellDimension.height)
        let lines = Int(floor(pageHeight/cellDimension.height))
        let startLine = Int(floor(contentOffset.y / cellDimension.height))
        let start = Position(col: 0, row: startLine)
        let end = Position(col: terminal.buffer.lines[startLine].count,
                           row: startLine + lines)
        return terminal.getDisplayText(start: start, end: end)
    }

    public func accessibilityAttributedContent(forLineNumber lineNumber: Int) -> NSAttributedString? {
        var startingLine = startingLine(forLineNumber: lineNumber)
        var endingLine = endingLine(forLineNumber: lineNumber)
        var start = Position(col: 0, row: startingLine)
        var end = Position(col: terminal.buffer.lines[endingLine].count,
                           row: endingLine)
        return accessibilityAttributedDisplayText(start: start, end: end)
    }

    public func accessibilityAttributedPageContent() -> NSAttributedString? {
        let pageHeight = max(bounds.height, cellDimension.height)
        let lines = Int(floor(pageHeight/cellDimension.height))
        let startLine = Int(floor(contentOffset.y / cellDimension.height))
        let start = Position(col: 0, row: startLine)
        let end = Position(col: terminal.buffer.lines[startLine].count,
                           row: startLine + lines)
        return accessibilityAttributedDisplayText(start: start, end: end)
    }
}


#if canImport(UIKit) && DEBUG
#Preview {
    SwiftUITerminalView { t in
        t.nativeBackgroundColor = UIColor.blue
        t.selectedTextBackgroundColor = UIColor.red
        t.caretColor = UIColor.blue
        t.feed(text: "🖐🏾 or 👩‍👩‍👦‍👦")
    }
}
#endif

#endif
