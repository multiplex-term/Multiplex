import Foundation

/// A tab's link to a backend that hands its panes out separately — one byte
/// stream each — and leaves drawing them to the app.
///
/// The other transports (`TerminalTransport`: an SSH PTY, mosh) carry ONE
/// stream, and a multiplexer on the far side composes its panes into it. A
/// paned transport carries no composed screen at all: it says how the panes
/// are arranged (`PaneArrangement`), streams each pane's output apart, and
/// takes input and a size per pane. The tab gives every pane its own
/// emulator (`TerminalScreen`) and lays them out itself (`PaneSplitView`).
///
/// Nothing here is Rex's. `RexSession` is the first conformer; what a second
/// one would map onto it:
/// - **tmux control mode** (`tmux -CC`): `%output %<pane>` is `output`,
///   `%layout-change` an arrangement, `send-keys -t %<pane> -H` a write,
///   `split-window` / `kill-pane` / `resize-pane` the commands. tmux sizes
///   its panes itself from the client's whole size, so that adapter would
///   answer `resize(pane:)` by summing to a `refresh-client -C`, and pin
///   every pane to the grid tmux gives it through `grid` — the same road a
///   Rex terminal takes while another client owns its size.
/// - **herdr**, once it serves pane streams: pane ids, a split tree and
///   close/split verbs are in its snapshot API already.
protocol PanedTerminalTransport: Actor {
    /// What was typed into one pane. Queues and returns, like every
    /// transport's write: the tab's input pump awaits each call.
    func write(_ data: Data, to pane: PaneID) async throws
    /// The grid the tab measured for one pane.
    func resize(pane: PaneID, cols: Int, rows: Int) async throws
    /// Change the backend's layout. The result is not returned: it arrives
    /// as the next arrangement, as a change made by anyone else would.
    func perform(_ command: PaneCommand) async throws
    func close() async
}

/// What a paned transport tells its tab. Every closure may be called from
/// any isolation.
struct PaneEvents: Sendable {
    /// The panes and how they are arranged — at the attach, and whenever
    /// that changes. The tab lays them out and answers with the grid it
    /// measured for each; the transport waits for that before it opens a
    /// new pane's stream, because a screen is fetched for the size it will
    /// be drawn at.
    var arrange: @Sendable (PaneArrangement) async -> [PaneID: TerminalGrid]
    /// One pane's output, in order.
    var output: @Sendable (PaneID, Data) -> Void
    /// The grid a pane's emulator must have before the bytes that follow
    /// are drawn: one the backend dictates, or nil for the pane's own
    /// again. Awaited — nothing more is sent for that pane until it
    /// returns.
    var grid: @Sendable (PaneID, TerminalGrid?) async -> Void
    /// The link ended on its own, at most once; nil for a clean end.
    var close: @Sendable (String?) -> Void
}
