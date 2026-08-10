# Links, viewport & file viewer

Load-bearing decisions split from AGENTS.md — read before touching terminal
link/path resolution, the ⌗ viewport, or the ▤ file viewer.

- **A terminal link is confirmed, never followed** (`TerminalLink`, pure +
  tested; `TerminalLinkSheet`). Long press is the activation route on
  every platform — it is local at any mouse mode, while a tap belongs to
  the remote under mouse tracking (tap activates only without it). Rules:
  the scheme allowlist handed to the system is `http`/`https`/`mailto`
  and nothing else — notably NOT `multiplex:`, which
  `ExternalActionRouter` would accept, so pane output can't launch an
  agent on another host. A valid local-authority `file:` URI is the one
  terminal-only handoff: activation asks `TerminalPathTarget` FIRST and
  confirms the decoded absolute path through the file-viewer sheet;
  malformed/non-local file URIs remain blocked + copy-only here.
  Filesystem-path matches otherwise resolve to nil here (they confirm
  through that same path sheet); interior whitespace disqualifies
  (`warning: unused variable` is not a `warning:` link). **Schemeless URLs
  resolve as links too**
  (`TerminalLink.schemelessLink`): the authority must be domain-shaped
  (≥2 ASCII labels, alphabetic ≥2-char TLD) or dotted-quad IPv4
  (`ViewportReach.isIPv4Literal`, the one parser), with URL evidence
  beyond the dot (`/`/`?`/`#` rest or `www.` — a markdown link's
  `setup.md` stays a document), userinfo rejected; the scheme defaults by
  reach (`ViewportReach.classify(host:)`: http for LAN/loopback, https
  elsewhere) and `raw` is the *composed* URL so the sheet states the
  chosen scheme. Markdown destinations opt out
  (`resolve(_:schemelessHosts: false)` — a schemeless href is a relative
  reference by spec). A dotted non-allowlisted-scheme candidate declines
  to nil. The sheet renders the resolved target with the host on its own
  line (which is what exposes `https://github.com@evil.example/x`);
  blocked/malformed targets still get a sheet with COPY. The target is an
  editable field (`TerminalSheetEditableValueBox`): every keystroke
  re-runs resolve, and the actions carry the *resolved* value. ⚠ OSC 8
  does not survive a tmux attach today — tmux 3.6a emits hyperlinks only
  to terminals advertising `Hls`, and the app requests
  `TERM=xterm-256color` — so implicit detection is the live path in tmux
  tabs. Don't "fix" it with a server-scoped `terminal-features` default
  (the leak the per-host conf documents). On visionOS links glow under
  the eye (`TerminalLinkHoverOverlay`, a `TerminalView` subview): system
  hover regions stood over the fork's link enumeration, rebuilt debounced
  on output/scroll — deferred while keystrokes flow (the fork's send-path
  stamp via `hasRecentUserInput`; typing echoes retrigger the debounce
  ~3×/s for no visible benefit), and an unchanged region set is a
  comparison, never a rebuild (each region is a cross-process
  hover-effect registration). Hover regions ARE hit regions — a pinch on a lit link
  outranks the remote click on those cells (accepted trade); only targets
  `resolve` would confirm get a region; obscured tabs clear theirs. Full
  record: `local-plan/terminal-links.md`.
- **The viewport is summoned, never restored** (`TerminalRoute.Mode
  .viewport`; `ViewportReach`/`ViewportOffer` pure + tested; bake-off in
  `local-plan/viewport-bakeoff/`): a *confirmed* web link docks as a ⌗ tab
  beside its session; the WKWebView is controller-owned and re-parents
  through merge/split (live page, HMR socket included, survives); its cell
  never wears a tally dot. The link sheet stays the only gate and grows a
  REACH row: `localhost` printed in a pane is the *host's* loopback — the
  chip becomes `⌗ OPEN VIA <host>` and rewrites the authority to
  `Host.hostname`, said in the open. The rail readout is tap-to-edit: a
  typed address is the user's own intent, so it skips the sheet but rides
  the same admit path (`ViewportOffer.fromTypedInput`; web schemes only,
  schemeless defaulted by reach, loopback rewritten); the editor lives in
  the pane's TOP contextual slot (the pane opts out of keyboard
  avoidance). Controllers live only in `TerminalWorkspace`'s memory and
  register BEFORE the tab enters any route, so `syncTabs` strips exactly
  the tabs a dead process restored, never a live move.
- **Classic visionOS moves both auxiliary rails into the bottom ornament**
  (2026-08-10): the ▤ rail rides above the UMD row in one slab, the ⌗ rail
  becomes three slabs with the address readout as the window identity.
  Inventory, sizing rules, and the resize-bar/anchor traps live in
  `input-and-windows.md`; Shell/iPad keep the in-window rails.
  `WKNavigationDelegate` re-applies the allowlist per navigation
  (`multiplex:` never navigable; mailto re-presents the sheet); no JS
  bridge, no send path into any terminal. One app-scoped persistent
  `WKWebsiteDataStore` shared by every viewport; **Clear Browsing Data…**
  on the readout's long-press menu wipes it globally after a confirmation.
  A viewport never claims `TerminalFocusArbiter` (switching to ⌗ releases
  the previous responder). ATS is relaxed for web content only
  (`NSAllowsArbitraryLoadsInWebContent`); app networking keeps full ATS.
  Load failures render a chassis NO ROUTE panel naming the network.
- **The file viewer is the viewport's sibling for paths — and path presses
  confirm instead of falling to selection** (`TerminalRoute.Mode
  .fileViewer`; pure models in `Models/FileViewer/`; records in
  `local-plan/file-viewer-bakeoff/` + `local-plan/file-viewer.md`). Two
  summons: + TAB ▸ File Viewer roots at the pane cwd ($HOME when no pane
  answers), and a long-pressed path (`TerminalPathTarget`; `:12[:col]` and
  tool-call-style `:12-18[:col]` suffixes ride as line targets) raises
  `TerminalFilePathSheet` → ▤
  VIEW. `file:///absolute/path` and `file://localhost/absolute/path` take
  the same road: percent escapes decode to the REMOTE path, URI syntax
  proves spaces/trailing marks are filename bytes (no prose trimming),
  and query/fragment/non-local-authority shapes stay blocked + copy-only.
  This file-URI check MUST precede `TerminalLink`, while ordinary links
  MUST precede ordinary paths so `example.com/docs` stays a URL. Only text
  BOTH resolvers decline ($VAR/…, colon prose, whitespace in a
  bare-relative shape) still falls to selection. Paths with spaces resolve
  when rooted by a base marker (`/`, `~/`, `./`, `$HOME/`); bare relatives
  keep the prose guard. `trimmingProseTail` sheds trailing
  chunks carrying neither `/` nor `.` — hence the sheet's OPENS row
  (verbatim mono) whenever the resolved spelling differs from the field.
  Split panes: detection is pane-aware in the fork (a border-glyph row
  scopes matching + wrap-joining to the pressed pane's columns — see
  `swiftterm-fork.md`), and a path press carries its screen cell so a
  relative path resolves against the PRESSED pane's cwd
  (`TmuxProbe.parsePathAnchorDirectory` / `HerdrProbe
  .parsePaneWorkingDirectory`, rect-containment with active/focused-pane
  fallback — a split's panes routinely sit in different repos). The cell
  lives in `TerminalSessionController.pathPressScreenCell`, overwritten
  per press rather than cleared with the sheet (the ▤ VIEW confirm reads
  it after dismissal), and rides the summon (`anchorCell`) so the mosh
  re-ask aims at the same pane; + TAB browse and the debug hooks pass no
  cell and keep the active-pane anchor.
  Wrapped-row glue: hard wraps leave no seam space, so `LinkMatch
  .rowTexts` carries per-row fragments (built only for multi-row matches;
  deliberately NOT via the OSC-8-authored `params` dictionary) and
  `WrappedRowGlue.cutTarget` (pure + tested) cuts at the first seam whose
  butting chunk carries neither `/` nor `.`; the cut suffix resolves
  link-then-path with the join as fallback, so a wrong cut can never kill
  a working press. Accepted trade: a bare path whose whole first segment
  sat on the upper row (`local-p`⏎`lan/x`) cuts wrong — visible in the
  editable field. `strippingWrappedProseHead` is the textual fallback for
  seamless callers (edited field, gaze regions). visionOS gaze regions
  stay URL-only on purpose (hover regions are hit regions; build logs are
  walls of paths). Details: **the viewer dials its own SSHConnection** —
  never the probe's (a disabled host must not be revived) and never the
  tab's transport (merge/split moves the viewer) — redialed once per op
  after suspension; works for mosh hosts (SSH stays the control plane).
  A mosh summon carries its full `SessionKey`, so that connection re-asks
  tmux's active pane or herdr's focused pane for the cwd before `$HOME` — a
  bare session name regressed herdr to home when backend support landed.
  **SFTP for listings/bytes** (structural, never parse `ls`; reads fill
  fixed chunks concurrently — sequential chunk walks cost seconds per MB
  at real RTT). **Exec for git**: Citadel's `executeCommand` THROWS on
  nonzero exit, so every git command tails `printf '\nMPXFV_EXIT:%s' "$?"`
  (`GitCommands.splitExit`) — "not a repo" ≠ "empty diff", and
  `--no-index` exits 1 routinely; `-c core.quotepath=false`,
  `--no-ext-diff`. **Rendering is zero-dependency on purpose** (2026
  survey: no maintained pure-Swift highlighter exists): `CodeHighlighter`
  (line-oriented, carry state survives breaks — diff rows highlight
  per-side), `MarkdownDocument` (GFM subset), `GitDiff`/`GitFileStatus`,
  all fixture-tested; graduation seam is exactly
  `CodeHighlighter.highlight(_:language:)`. **Code/diff screens are ONE
  selectable TextKit 2 view** (`FileViewerTextView`, content assembled
  off-main): the text is exactly what a copy should carry; numbers,
  grounds, and washes are decor drawn by pinned companion views,
  unselectable by construction. Traps on record: the
  `usingTextLayoutManager:` convenience init crashes a Swift subclass
  (hand-build the stack), and a `path:12` / `path:12-18` centered scroll
  (the range starts centered and every requested row is washed) must defer
  one main-queue hop past first layout. Rendered markdown keeps SwiftUI
  blocks; a rail SELECT chip re-hosts the raw source on the selectable
  screen. **A markdown image is a captioned placeholder that a press turns
  into the picture, in place** (`MarkdownInline.image(alt:destination:)`;
  `FileViewerController.InlineImage`): rendering a document still fetches
  nothing — the press is the only thing that does, and it SHOWS rather
  than navigates (the tab stays on the README). The caption is the switch:
  `⟨image: alt⟩` in link ink while hidden, `⌄ image: alt` above the
  picture once shown, pressed again to put it away. A web URL is not a
  file this viewer fetches — it goes to the link sheet exactly as it does
  in prose, with both ⌗ VIEWPORT and the external OPEN handoff — and a
  destination-less `![alt]()` stays the inert caption it
  always was. Load-bearing details:
  - **Pictures ride INSIDE the block that names them**
    (`FileViewerMarkdownProseBlockView`), never as extra rows of the
    document stack: that stack is index-paired with `blocks`, and
    mounting, restyling, and the reader's scroll anchor all count on it.
  - **The height is a constraint re-derived from the width Auto Layout
    actually gave the view**, never a cached `intrinsicContentSize`. The
    column's width arrives after the picture does, and one stale
    measurement leaves the picture floating in a band of empty chassis —
    shipped and caught on the sim, 2026-08-08. Fit is the column, capped
    by the picture's own pixels (never upscaled) and by
    `maximumHeight` (one figure can't take the whole screen); tapping it
    opens the full ▤ screen, where zoom lives.
  - Decoded at `inlineImageMaxPixelEdge` (1600, against the full screen's
    4096) because a README shows many at once; keyed by the destination as
    written, so one fetch serves every repeat of it, and cleared when the
    screen moves to another document.
  - `FileTree.resolve(reference:from:)` is the one resolver the picture
    and link roads share — percent escapes decode to the REMOTE path,
    `#anchor` is dropped (there is nothing to scroll to), an anchor-only
    reference resolves to nothing; `MarkdownDocument` sheds the two
    decorations CommonMark allows around a target (a `"title"` and `<…>`
    brackets) so a press can't aim at a path the document never named.
  - A picture this screen can't draw (an SVG, a PDF, a stat failure) says
    so where it would have been, with an OPEN FILE chip onto the ▤ screen
    — a press is never a dead end. Table cells keep the old road outright
    (a picture would wreck the measured column widths). Honesty rules: NUL-sniff says BINARY; >1.5 MB renders its head
  under TRUNCATED; a deleted file's row opens its diff; failures name the
  cause. A browse summon starts the drawer OPEN (the tree is the subject
  until a file is chosen). `FileTree.hiddenNames` hides only the
  editor-default set (.git/.svn/.hg/CVS/.DS_Store/Thumbs.db — NOT all
  dotfiles; content untouched). **Watching is polling, the deck's way**
  (never a remote inotify/fswatch — nothing long-running is assumed onto
  the host): active tab + `applicationState == .active` → a 5 s tick runs
  ONE combined git exec (`GitCommands.watchProbe`/`parseWatchProbe`) plus
  one SFTP stat; expanded listings sweep every third tick. Results land
  as QUIET swaps (no .loading, no scroll reset) and a `contentGeneration`
  counter drops stale results. Known blind spot: a net-zero-delta edit
  under an unchanged porcelain line escapes the repo-wide diff until
  REFRESH; a vanished watched document flips to FILE GONE, transport
  blips change nothing. Shared auxiliary-pane rules with the viewport: no
  tally dot, no focus claim, `syncTabs` strips controller-less tabs and
  must NEVER mint a `TerminalSessionController` for an auxiliary route.
  **Reading size is a quantized ladder, app-wide and device-local**
  (`FileViewerTextScale` pure + tested; `FileViewerTextScaleStore`, the
  `ThemeStore` precedent): it multiplies the *authored* size,
  `Theme.typeScale` still last. A pinch snaps to a rung and writes only on a
  change (`FileViewerTextScalePinch` — a rung costs a rebuild, so never a
  continuous multiplier); A− / A+ ride the tab's UMD rail
  (`ViewportUMDConfiguration.textScale`) on EVERY platform —
  Designed-for-iPad has no pinch — with the percentage in front of them,
  readout and reset, only off 100%; a ⌗ viewport tab passes nil. The pane
  reads the store inside its observation, so one pinch resizes every open ▤
  tab, and the size stays out of `BodyKey`: the live screen rebuilds in
  place, scroll position and selection with it. Three measured rules keep
  that rebuild off a second (iPad sim, 2026-08-06). **Clear a TextKit view
  before refilling it** (`FileViewerTextView.setContent`): assigning over a
  populated document makes TextKit reconcile the two — 1.4 s for 8 000 lines
  against 1 + 10 ms, and every screen swap pays it, watch ticks included.
  **A rendered-markdown resize restyles mounted blocks in place, near the
  viewport first** (`restyleNearViewport`/`restyleAhead`), the rest catching
  up as they are scrolled toward with the anchor block held still —
  remounting costs the whole scroll depth (2.7 s for 160 blocks: every block
  above the reader is rebuilt before theirs has a position). Only fences and
  tables are rebuilt, their geometry being measured into constraints.
  **`FileViewerMarkdownTextView` caches its height per width** — a stack
  view asks EVERY arranged subview for its intrinsic size on any layout
  pass, so one restyled block re-ran CoreText over the whole screen.
  ⚠ `mountBlocksIfNeeded` must `setNeedsLayout` the scroll view before
  reading `contentSize`, or a teardown's stale tall height reads as a full
  viewport and the screen stays BLANK until the reader scrolls.
