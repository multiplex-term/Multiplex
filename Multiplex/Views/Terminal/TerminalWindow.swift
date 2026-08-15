import Foundation
#if DEBUG
import notify
#endif

#if DEBUG
extension Notification.Name {
    static let multiplexDebugNewTab = Notification.Name("MultiplexDebugNewTab")
    static let multiplexDebugHerdrTab = Notification.Name("MultiplexDebugHerdrTab")
    static let multiplexDebugMessageJump = Notification.Name("MultiplexDebugMessageJump")
    static let multiplexDebugMessageJumpBack = Notification.Name(
        "MultiplexDebugMessageJumpBack"
    )
    static let multiplexDebugLink = Notification.Name("MultiplexDebugLink")
    static let multiplexDebugLinkOpen = Notification.Name("MultiplexDebugLinkOpen")
    static let multiplexDebugViewportOpen = Notification.Name("MultiplexDebugViewportOpen")
    static let multiplexDebugLinkRegions = Notification.Name("MultiplexDebugLinkRegions")
    static let multiplexDebugFileViewer = Notification.Name("MultiplexDebugFileViewer")
    static let multiplexDebugPathView = Notification.Name("MultiplexDebugPathView")
    static let multiplexDebugFileViewerRepoDiff = Notification.Name(
        "MultiplexDebugFileViewerRepoDiff"
    )
    static let multiplexDebugFileViewerSelect = Notification.Name(
        "MultiplexDebugFileViewerSelect"
    )
    static let multiplexDebugFileViewerImage = Notification.Name(
        "MultiplexDebugFileViewerImage"
    )
    static let multiplexDebugFileViewerPlay = Notification.Name(
        "MultiplexDebugFileViewerPlay"
    )
}

/// `….debug.fileviewer` runs the focused window's + TAB ▸ File Viewer
/// action (pane-cwd resolve → controller registration → tab dock);
/// `….debug.pathview` runs the path sheet's ▤ VIEW for the pending path a
/// prior `….debug.link` raised over path-shaped text — together the
/// headless walk of both summon doors. `….debug.fvselect` toggles the
/// active viewer's rendered-markdown SELECT mode (the rail chip the
/// simulator can't tap). `….debug.fvimage` presses the first image
/// placeholder on the rendered markdown screen — the same destination →
/// resolve → open path a finger takes, which no sim tap can drive.
/// `….debug.fvplay` presses PLAY/PAUSE on the active viewer's sound screen
/// (the panel's own chip action; proof is the PLAYING lamp and a moving
/// clock in the next screenshot).
@MainActor
enum FileViewerDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var openToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fileviewer", &openToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugFileViewer, object: nil)
        }
        var viewToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.pathview", &viewToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugPathView, object: nil)
        }
        var repoDiffToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fvrepodiff", &repoDiffToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugFileViewerRepoDiff, object: nil
            )
        }
        var selectToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fvselect", &selectToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugFileViewerSelect, object: nil
            )
        }
        var imageToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fvimage", &imageToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugFileViewerImage, object: nil
            )
        }
        var playToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fvplay", &playToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugFileViewerPlay, object: nil
            )
        }
    }
}

/// `….debug.link` activates the first link on the focused terminal's visible
/// screen — the same resolve → policy → confirmation path a long press takes,
/// which is the only way to drive it headlessly (no sim tap injection exists,
/// and ornament/gesture input can't be synthesized). `….debug.linkopen` then
/// runs the sheet's OPEN action, so a screenshot shows Safari with the target.
@MainActor
enum TerminalLinkDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var findToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.link", &findToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugLink, object: nil)
        }
        var openToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.linkopen", &openToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugLinkOpen, object: nil)
        }
        var viewportToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.viewportopen", &viewportToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugViewportOpen, object: nil)
        }
        var regionsToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.linkregions", &regionsToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugLinkRegions, object: nil)
        }
    }
}

/// Headless-verification hooks, same shape as `AgentChipDebugHook`:
/// `xcrun simctl spawn <udid> notifyutil -p app.multiplexterm.multiplex.debug.newtab`
/// runs the focused window's + TAB New Session action — control-connection
/// exec → mint → tab append → attach, on either backend, without touching
/// the screen. `….debug.herdrtab` runs the herdr-only New Tab in Workspace
/// entry; proof is host-side (the session's snapshot gains a tab, no
/// session is minted) and no Multiplex tab appears.
@MainActor
enum NewTabDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.newtab", &token, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugNewTab, object: nil)
        }
        var herdrToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.herdrtab", &herdrToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugHerdrTab, object: nil)
        }
    }
}

/// `….debug.msgjump` jumps the focused Claude Code terminal to its oldest
/// session-file prompt; `….debug.msgjumpback` runs BACK TO LIVE. Host-side
/// capture-pane proves both: the old prompt appears, then the live tail
/// returns.
@MainActor
enum MessageJumpDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var jumpToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.msgjump", &jumpToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugMessageJump, object: nil
            )
        }
        var backToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.msgjumpback", &backToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugMessageJumpBack, object: nil
            )
        }
    }
}
#endif
