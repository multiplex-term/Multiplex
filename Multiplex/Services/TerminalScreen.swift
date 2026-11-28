import Foundation
import SwiftTerm

/// One emulator of a terminal tab, and the plumbing between it and the far
/// side: the SwiftTerm view, the output on its way in, the ordered pumps
/// for input and size on their way out, and the grid it is held to.
///
/// A tab has exactly one — `paneID` nil — unless its transport hands its
/// panes out separately (`PanedTerminalTransport`), in which case it has
/// one per pane and `TerminalSessionController` moves `terminalView` between
/// them with the tab's focus. Everything the controller does to "the
/// terminal" it does to its active screen, so a paned tab needed no second
/// version of the chrome above it.
///
/// What a screen writes to is two closures, so it does not know which kind
/// of transport it belongs to.
@MainActor
final class TerminalScreen {
    /// The pane this screen draws; nil for a tab's only screen.
    let paneID: PaneID?

    /// Strongly owned (SwiftTerm's delegate back-reference is weak): the
    /// view carries the terminal buffer and scrollback, and tabs move
    /// between windows — the adopting window re-parents this same view, so
    /// what's on screen survives a merge/split.
    private(set) var terminalView: TerminalView?
    private var pendingOutput: [UInt8] = []
    /// One short-delay drain per transport run replaces a MainActor Task
    /// and a Data→Array copy for every network chunk. Parsing remains on
    /// the main actor because SwiftTerm's view/delegate/display machinery
    /// is UIKit.
    var outputCoalescer: TerminalOutputCoalescer?
    /// Pinged after every coalesced output flush reaches the terminal —
    /// visionOS's gaze link-hover overlay debounces its region rebuild
    /// behind this, so affordances follow the screen without polling.
    var onOutputFlushed: (() -> Void)?

    /// Whatever grid the emulator has — under a pin, somebody else's.
    private(set) var cols = 80
    private(set) var rows = 24
    /// The grid of the terminal on show while the far side dictates it (a
    /// Rex terminal another client owns the size of). The surface lays the
    /// emulator out at it; nil is the surface's own grid.
    private(set) var gridPin: TerminalGrid?
    /// The surface's side of `gridPin`. It must have the emulator at the
    /// new grid by the time it returns — the screen drawn next is for it.
    var onGridPinChanged: (() -> Void)?
    /// The last grid the surface measured for itself: what this screen
    /// asks its terminal to be.
    private(set) var ownSize: TerminalGrid?
    private var isSettlingGridPin = false
    /// The title the program last set (OSC 0/2).
    var title = ""

    private var inputTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?
    private var resizeTask: Task<Void, Never>?
    private var resizeContinuation: AsyncStream<TerminalGrid>.Continuation?

    init(paneID: PaneID? = nil) {
        self.paneID = paneID
    }

    /// The grid a transport opens this screen's terminal at.
    var openingSize: TerminalGrid {
        ownSize ?? TerminalGrid(cols: cols, rows: rows)
    }

    var hasPumps: Bool { inputContinuation != nil }

    // MARK: Output

    /// Takes the view a surface made (or adopted from another window) and
    /// draws whatever arrived before there was one.
    func attach(_ view: TerminalView) {
        terminalView = view
        if !pendingOutput.isEmpty {
            view.feed(byteArray: pendingOutput[...])
            pendingOutput.removeAll()
        }
    }

    func feed(_ bytes: [UInt8]) {
        guard let terminalView else {
            pendingOutput.append(contentsOf: bytes)
            return
        }
        terminalView.feed(byteArray: bytes[...])
        onOutputFlushed?()
    }

    // MARK: Pumps

    /// Keystrokes flow through one AsyncStream consumed by a single task —
    /// yield order is preserved, unlike a Task spawned per keystroke, and
    /// the terminal thread never waits on the network.
    ///
    /// Resize callbacks can arrive for every layout pass while a window is
    /// dragged. Only the newest dimensions are kept and one ordered task
    /// talks to the transport, rather than an unbounded task per callback.
    func startPumps(
        write: @escaping @Sendable (Data) async throws -> Void,
        resize: @escaping @Sendable (TerminalGrid) async throws -> Void,
        openedAt size: TerminalGrid
    ) {
        stopPumps()
        let (input, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        self.inputContinuation = inputContinuation
        inputTask = Task {
            for await chunk in input {
                try? await write(chunk)
            }
        }
        let (sizes, resizeContinuation) = AsyncStream.makeStream(
            of: TerminalGrid.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.resizeContinuation = resizeContinuation
        resizeTask = Task {
            for await size in sizes {
                try? await resize(size)
            }
        }
        // Layout may have changed while the handshake/open call was
        // awaiting; reconcile once with the newest geometry before normal
        // coalescing.
        if gridPin == nil, cols != size.cols || rows != size.rows {
            resizeContinuation.yield(TerminalGrid(cols: cols, rows: rows))
        }
    }

    func stopPumps() {
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
        resizeContinuation?.finish()
        resizeContinuation = nil
        resizeTask?.cancel()
        resizeTask = nil
    }

    /// Joins the ordered input pump. False when there is none — the caller
    /// has bytes that must not be dropped (the handoff re-type) and writes
    /// them itself.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let inputContinuation else { return false }
        inputContinuation.yield(data)
        return true
    }

    // MARK: Size

    /// The emulator measured a grid; false when it is the one it had. The
    /// far side is told only a grid that is this screen's own ask — one
    /// taken from another client is the emulator's, not this tab's — and
    /// only while there is a far side: the pumps live exactly as long as
    /// the transport does.
    @discardableResult
    func resized(cols: Int, rows: Int) -> Bool {
        guard cols != self.cols || rows != self.rows else { return false }
        self.cols = cols
        self.rows = rows
        if gridPin == nil, !isSettlingGridPin {
            let size = TerminalGrid(cols: cols, rows: rows)
            ownSize = size
            resizeContinuation?.yield(size)
        }
        return true
    }

    /// Gives the emulator another client's grid, or its own back.
    ///
    /// The surface changes the text size and the frame to do it, and each
    /// of those makes SwiftTerm report a grid on the way — none of them the
    /// screen's own, so none is sent on. Once the surface has settled back
    /// on its own grid, that one is: the window may have been resized
    /// meanwhile.
    func setGridPin(_ grid: TerminalGrid?) {
        guard grid != gridPin else { return }
        gridPin = grid
        isSettlingGridPin = true
        onGridPinChanged?()
        isSettlingGridPin = false
        // With no surface to lay out, the emulator is still at the grid it
        // was given and `ownSize` already holds the screen's last own one.
        guard grid == nil, onGridPinChanged != nil else { return }
        let own = TerminalGrid(cols: cols, rows: rows)
        ownSize = own
        resizeContinuation?.yield(own)
    }

    /// The emulator's visible rows as text, and whether a full-screen
    /// program has it. Copied reads: the terminal lives behind SwiftTerm's
    /// lock, and its parse runs on the feed thread.
    func snapshot() -> (lines: [String], isAlternate: Bool) {
        guard let terminalView else { return ([], false) }
        let rows = max(0, terminalView.terminalDimensions.rows)
        let lines = terminalView.visibleRowsText(0..<rows)
        return (lines, terminalView.isAlternateBufferActive)
    }
}

/// Hands each pane's output to its screen, from whatever isolation the
/// transport delivers on. The tab's main-actor side says which panes exist;
/// output for a pane it has dropped goes nowhere.
final class PaneOutputRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [PaneID: TerminalOutputCoalescer] = [:]

    func set(_ sink: TerminalOutputCoalescer?, for pane: PaneID) {
        lock.withLock { sinks[pane] = sink }
    }

    func removeAll() {
        lock.withLock { sinks.removeAll() }
    }

    func append(_ data: Data, to pane: PaneID) {
        lock.withLock { sinks[pane] }?.append(data)
    }
}
