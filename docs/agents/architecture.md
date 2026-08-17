# Architecture — full component map

```
UIKit scene runtime (MultiplexSceneDelegate + UIKitSceneRootViewController;
         SwiftUI survives ONLY where visionOS's ornament API needs a View):
         classic Deck window + N Terminal windows, or one adaptive Shell
         (real FleetWall + one ordered TerminalWindowRoute tab set);
         a terminal window/shell = ordered tabs, each tab a TerminalRoute
  BindController     Bind Host: candidates, enrollment, offline-payload key
                     rotation (.shared; the mounted deck attaches HostStore
                     + EntitlementStore)
    BindDiscovery    NWBrowser over _multiplex-bind._tcp while the Bind pane
                     is open — no entitlement, no background socket
    BindClient       one NWConnection running the sealed handshake
    Bind* models     payload/TXT codec, CBOR subset, X25519+HKDF+ChaCha20
                     channel, ed25519 OpenSSH keygen — pure, pinned to the
                     CLI's bytes by vendored vectors
  HostStore          hosts.json local cache; secrets + host records sync via
                     iCloud Keychain (KeychainStore); host records include
                     per-host agent command configuration
  ThemeStore         terminal color schemes (themes.json); device-local
  KeyCommandStore    the app-wide hold-CTRL Key Commands set (.shared;
                     keycommands.json + ONE synchronizable Keychain item,
                     last writer wins by updatedAt); KeyCommand/KeyChord/
                     KeyTextSnippet pure; KeyCommandDispatcher sends through
                     TerminalView.send, chords encoded by the fork at press
                     time (TerminalView.bytes(for:)); the tier's cap rides
                     KeyCommandPlan from the terminal window (which holds
                     EntitlementStore) down to the rail / cluster presenter
  AgentCommandConfiguration  pure per-host Bar/More overrides + ordered
                     custom helpers; shared UUIDs mirror between profiles
  ConnectionHub      one HostConnectionModel per host — the probe connection;
                     ONE exec round-trip per monitored backend carries
                     sessions + a clipped ps table + capture tails, polled
                     ~5s by FleetWall while frontmost (background re-probes
                     never surface .probing)
    SessionKey       (backend, name) — the identity every per-session map
                     keys by; persisted maps use its `storageKey` (pure)
    BackendDiscovery the other backend's rider on the primary probe's own
                     channel: installed? how many sessions? (pure)
    DeckSnapshotStore  last-known wall state per host (device-local) — cold
                     launches paint instantly; attention is never cached
    TmuxProbe        tmux list/capture/ps command builders + parsers (pure)
    AgentSignature   classifies a pane's CLI agent; helper command sets (pure)
  AppLockStore       optional biometric app lock (device-local, free): locks
                     at launch + didEnterBackground (never resign-active);
                     AppLockGate veils every scene root and flips
                     TerminalFocusArbiter.inputSuppressed; a passcode-less
                     device fails OPEN
  EntitlementStore   the Pro gate — StoreKit 2 ownership, purchase/restore,
                     the daily agent-helper meter; injected ProStoreClient
                     keeps commerce state testable
  ExternalActionRouter  one queue for widget deep links (multiplex:// via
                     onOpenURL on every scene root), App Shortcuts, and
                     automation; the mounted DeckWindow attaches a Context
                     and ExternalActionPerformer runs the status-guarded
                     flows (refreshAndWait → connected → focus/attach/create
                     + agent launch). Failures alert on the deck; ASK mode
                     presents AgentPromptSheet; a deckless scene raises the
                     one deck scene to drain.
  SharedStateStore   secret-free App Group projection (widget-state.json)
                     for the widget process; ConnectionHub publishes (2s
                     debounce, content-hash-gated WidgetCenter reloads);
                     DeckWindow republishes on host-list changes
  MultiplexWidgets   WidgetKit target (compiles ONLY Multiplex/Shared):
                     HostWidget + FleetWidget. Widgets never connect, show
                     no tally red / NEEDS YOU, carry a relative SEEN stamp,
                     timeline .never (app pushes reloads). WidgetTheme PINS
                     dark graphite on visionOS (the environment lies about
                     interface style); views draw through the resolved
                     WidgetPalette, and ACCENTED draws white-with-opacity
                     only — the channel the tint remap preserves.
  TerminalWorkspace  tab controllers keyed by tab id — merge/split move
                     tabs across windows, shells stay live
    ViewportController   one per ⌗ viewport tab; owns the WKWebView so
                     moves re-parent the live page; in-memory only
    FileViewerController one per ▤ file-viewer tab; dials its OWN lazy
                     SSHConnection; in-memory only (shares the
                     isAuxiliaryPane rules with the viewport); its
                     Document owns the PDF / audio clip, so a moved tab
                     keeps page and position
  TerminalSessionController  one per tab; input pump + TerminalView
    TalkbackDraft        the tab's chat-style message box (text +
                         attachments; pure) beside its observed talkbackOpen
                         — sendTalkback = one paste + CR through the pump,
                         attachTalkbackFiles = the drop path's one upload
                         primitive, held until SEND; rendered by
                         TalkbackComposerViewController (window-docked on
                         iPad/iPhone, an ornament slab on visionOS)
    TerminalTransport    the tab's byte pipe; picked by host.useMosh
                         (exec + SFTP stay SSH-only capabilities)
    SessionResumePolicy  pure: suspension damage vs user-ended session
    SSHConnection (actor)  Citadel → SwiftNIO SSH; exec channel (probe,
                     mosh bootstrap, drops) + PTY shell ⇄ SwiftTerm
    MoshSession (actor)  UDP socket + MoshTransportEngine; bootstrapped
                     over a throwaway SSHConnection
      Mosh/*         clean-room mosh stack, pure + unit-tested against
                     RFC 7253 / real mosh-server
  TerminalFocusArbiter  app-wide single owner of keyboard focus
```

Layer rule: **Views → Services → Models**; Models have no UIKit/SwiftTerm
imports. `TmuxProbe`, `TerminalRoute`, and the models are pure and are where
logic belongs — keep parsing/command-building out of views.
