# Native panes (a tab that draws its backend's panes itself)

Split from AGENTS.md. Read before touching `PaneLayout`,
`PanedTerminalTransport`, `TerminalScreen`, `PaneSplitView`, or the paned
half of `TerminalSessionController` / `TerminalSurfaceView`. The first (and
so far only) backend that uses it is Rex — its own facts are in
`backends-and-probe.md`.

- **Two kinds of tab.** A tmux, herdr, shell or mosh tab carries ONE byte
  stream: the multiplexer on the far side composes its panes into it, and
  the tab is one emulator. A **paned** tab carries one stream PER PANE and
  the layout they sit in, and the app draws them — one emulator each, lines
  between, resize by dragging. Which kind a tab is, is the route's fact
  (`TerminalSessionController.drawsPanes`), never a setting.
- **Four pieces, and what each may know.**
  - `PaneLayout` (Models, pure): a binary tree of splits with a `PaneID` at
    every leaf, its geometry (`frames`, `ratio(forDividerAt:)`), and what a
    tab can ask for (`PaneCommand`). No backend's vocabulary: an axis is
    `sideBySide` or `stacked` because Rex, tmux and herdr do not agree
    which of those is "horizontal".
  - `PanedTerminalTransport` (Services, protocol) + `PaneEvents`: what a
    backend that hands its panes out separately looks like to a tab —
    write / resize per pane, `perform(PaneCommand)`, and four events
    (`arrange`, `output`, `grid`, `close`). `RexSession` conforms; nothing
    above it names Rex except the three places that are Rex features
    (Switch Terminal, a pane's working directory, the route).
  - `TerminalScreen` (Services): ONE emulator endpoint — the SwiftTerm
    view, its output coalescer, its ordered input and resize pumps, its grid
    pin. A single-stream tab has exactly one (`soleScreen`); a paned tab
    one per pane. It writes through two closures, so it does not know which
    kind of transport it belongs to.
  - `PaneSplitView` (Views): the cells, the lines, the focus frame. It sits
    exactly where the one `TerminalView` sits in `TerminalSurfaceView`, so
    keyboard avoidance, bottom chrome and the safe-area edges move it the
    same way and need no second version.
- **"The terminal" of a tab is the pane the keyboard is on.**
  `TerminalSessionController.terminalView` is an observed mirror of the
  active screen's view, moved by `activate`. Everything above the emulator
  already read it lazily — the key rail, the ornament cluster, Talkback,
  dictation, file drops, links, the agent strip — so a paned tab needed no
  second chrome. Three things cached the view and had to learn to follow:
  the iPad rail (`TerminalKeyBar.retarget`; a CTRL latch does NOT travel),
  the surface's own coordinator (keyboard avoidance asks "is MY terminal
  the first responder"), and the pane's two selection overlays
  (`overlayTerminal` — left behind, they answered the old pane's presses).
  The window observes `activePaneID` so the agent strip and the visionOS
  cluster re-read.
- **The tab's focus is the tab's own.** `PaneCommand.focus` tells the
  transport where the person is; what a backend makes of that is its
  business. Rex only remembers it (see `backends-and-probe.md` for why it
  is never `session.focus_block`). The transport moves the tab's focus only
  with a reason, by naming a pane in `PaneArrangement.focus`: the attach's
  target, a pane the tab just made, the neighbour of one that closed
  (`PaneLayout.neighbor(ofClosing:)`), a terminal chosen from the panel.
  nil leaves it where the person put it.
- **The keyboard follows the focus only if the tab had it.**
  `TerminalSurfaceView.syncPanes` claims the new pane's view when the pane
  being left was the first responder, or when there was none (the attach —
  what a single emulator does when its surface is installed). A tab that
  did not have the keyboard never takes it because its layout changed
  somewhere else. A touch moves focus at touch DOWN
  (`TouchDownGestureRecognizer`, which neither cancels nor delays
  anything): the tap's release is too late — a long press raises the
  selection menu of whichever pane is active, and it has to be the one
  under the finger. Touch-down moves the keyboard only if the tab had it;
  the tap (`reclaimFocus`) is still what summons a dismissed keyboard.
- ⚠ **A pane is laid out BEFORE its terminal is opened, and the transport
  waits for that.** `PaneEvents.arrange` is async and answers with the grid
  each pane measured: the controller makes the screens, the surface's
  `observePaneLayout` hook lays them out synchronously (`layoutIfNeeded` —
  SwiftTerm measures its grid from its frame in that pass), and only then
  does the transport claim, size and render. A screen fetched for one size
  and drawn at another is the stray-character bug `backends-and-probe.md`
  records; without a mounted surface (a tab opened in the background) the
  answer is the emulator's default grid and the first real layout resizes
  it, which is no worse than a single-stream tab opened unseen.
  - A pane's pumps start at the arrangement, not at `.live`: its size has
    to reach the transport while its terminal is still being opened. The
    transport keeps the newest size it was told per pane even before it
    knows the pane (`RexSession.requestedSizes`) and prefers it over what
    `arrange` returned — the pump's word is the later one.
- **Zoom is the tab's own picture, and no backend is asked.**
  `zoomedPaneID` draws the pane the keyboard is on over the whole split
  (`PaneSplitView`: that cell gets the view's bounds, the others are
  HIDDEN). Hidden is not gone: the other cells stay laid out where the
  split has them, so their terminals keep the size they will be shown at
  again and keep taking their output — leaving the zoom redraws nothing
  and resizes only the pane that was zoomed. It ends when the tab's focus
  goes to another pane, however that happens (a split made while zoomed, a
  terminal chosen from the panel, the zoomed pane closing): the pane the
  keyboard goes to has to be on screen, which is tmux's and Rex's own
  rule. A layout change that leaves the focus alone leaves the zoom. A
  bar over the pane (`TerminalContextBarView.zoomed`: ZOOMED + ALL PANES)
  says so and is the way back — the panes it covers cannot be seen to be
  missed. Why not the backend's own zoom: for Rex it cannot be aimed at
  the tab's focus (`backends-and-probe.md`); a backend whose zoom CAN be
  would state it in the arrangement instead, which nothing here forbids.
- **A session can have more windows than the tab draws.** A tab draws
  one; `PaneCommand.newWindow(from:)` asks for another holding one pane,
  and the transport moves the tab there by sending that window's
  arrangement — the same road a terminal chosen from the panel's switch
  list takes. Which word the row wears is the backend's (`PaneShortcut
  .newWindow` is "New Window"; Rex's row is titled New Tab).
- **A file dropped on a pane lands in that pane.** The drop moves the
  tab's focus to the pane under it first (`PaneSplitView.pane(at:)`), so
  the upload goes to that pane's directory and the path is typed there —
  the same road a path pressed in a pane takes, because a press moves the
  focus too.
- **A drag moves the tab first and asks the backend second.**
  `setPaneRatio` updates `paneLayout`, relays out synchronously, and queues
  `.setRatio`. Commands leave through ONE ordered pump
  (`startPaneCommandPump`): a drag makes dozens, and a `Task` per event let
  an older ratio land last. The transport then owes two things, both
  measured against Rex: send only the newest ratio while one is in flight,
  and do not let the backend's answer to an EARLIER ask drag the line back
  (`pendingRatios`, `floorRevision`).
  - ⚠ The line is dragged by a press with NO delay
    (`UILongPressGestureRecognizer`, `minimumPressDuration` 0), not a pan.
    A pan begins only once the finger has travelled some way and reports
    the travel from there — by position and by `translation` alike: with a
    real touch a 180 pt drag moved the line 158. The strip is the line's
    alone, so the drag can start where the finger lands; a touch that never
    moves sends nothing.
  - The strip a finger can take hold of reaches 8 pt onto each pane beside
    the line, and sits above the panes: without it the terminal's own
    gestures took the touch.
- **One pane cannot be opened: say so in the pane, keep the tab.** The
  attach fails only when no pane opened. A pane that could not — sshd's
  `MaxSessions` (10 channels a connection: the control pipe and nine
  panes), a refused stream — gets one line in its own emulator and is not
  retried on every layout change.
- **A reconnect keeps the screens.** `endPanedRun` drops the transport and
  the pumps, not the `TerminalScreen`s: the next arrangement finds the same
  panes by id and redraws into the same emulators (RIS + rendering), so
  scrollback and the views survive a link drop the way a single emulator's
  do.
- ⚠ **A moved tab has two surfaces for a moment.** The window it left gets
  one last `update`; if that surface made cells it would adopt the emulator
  views back out of the window the tab arrived in. `observePaneLayout(as:)`
  records whose hook is installed and `syncPanes` does nothing for anyone
  else. (The single-emulator path has the same guard as `isDescendant(of:)`.)
- **Colors inside the split are the terminal theme's**, not the chassis's:
  lines at 20 % of the theme foreground, the focus frame at 60 %. The frame
  lies ON the lines beside the pane (`frameOutset` = half the gap), so the
  focused pane reads as one rectangle; a tab with one pane draws neither
  and is pixel-for-pixel the single emulator.
- **What a second backend has to do** — nothing above the transport:
  1. Conform to `PanedTerminalTransport`; map its ids to `PaneID` and its
     layout to `PaneLayout` (an n-ary row nests: `a | (b | c)`, ratios from
     cell counts).
  2. Call `arrange` at the attach and on every layout change, and open a
     pane's stream only after it returns.
  3. Make `drawsPanes` true for its route and start it from
     `TerminalSessionController.run` through `runPanes(over:generation:
     open:)` — that function has no Rex in it.
  - **tmux control mode (`tmux -CC`)**, if it is ever wanted: `%output
    %<pane>` is `output`, `%layout-change` an arrangement, `send-keys -t
    %<pane> -H` a write, `split-window` / `kill-pane` / `resize-pane` the
    commands. The one real difference: tmux sizes panes itself from the
    client's WHOLE size. That adapter sums the panes' measured grids into
    one `refresh-client -C` and pins every pane to the grid tmux answers
    with through `PaneEvents.grid` — the road a Rex terminal already takes
    while another client owns its size. Not measured; nothing was built.
  - **herdr** (a core that serves panes apart from its TUI): not measured,
    nothing built. What `HerdrProbe` already reads from the snapshot API is
    half of an adapter — pane ids, each pane's rectangle, which is focused,
    and close verbs by id. The other half is the part that decides it: a
    stream per pane, and input addressed to one.
- Not built, on purpose: moving or swapping panes, a pane title
  strip, hardware-keyboard chords for pane focus (a paned tab has no prefix
  key to hang them on), and a pool of SSH connections past `MaxSessions`.
- Tests: `PaneLayoutTests` (tree + geometry), `TerminalPaneSplitUIKitTests`
  (the real controller and surface over a recording transport —
  `runPanesForTesting`), `RexSessionTests` (the Rex adapter against an
  in-process server with a real layout tree). Real touches —
  the tap that moves focus, the finger on a line — are
  `MultiplexUITests/RexPanesUITests`, outside the unit scheme and CI like
  the Arrange Keys one: it needs a Rex server (`TEST_RUNNER_MULTIPLEX_SEED
  _HOST` + `TEST_RUNNER_MULTIPLEX_REX_SESSION`), and each step waits out
  XCUITest's 60 s idle timeout because a terminal never idles, so one run
  is about twelve minutes. Headless, without touches:
  `MULTIPLEX_AUTO_PANE_ACTIONS` (`e2e-headless.md`).
