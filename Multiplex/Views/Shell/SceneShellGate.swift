import OSLog
import SwiftUI
import UIKit

/// Resolves shell mode once, when this SwiftUI scene first acquires its
/// UIWindowScene. The result intentionally does not follow live multitasking
/// setting changes; reconnecting the scene on the next launch re-evaluates it.
struct SceneShellGate<Classic: View, Shell: View>: View {
    @State private var usesShell: Bool?

    private let classic: Classic
    private let shell: Shell

    init(
        @ViewBuilder classic: () -> Classic,
        @ViewBuilder shell: () -> Shell
    ) {
        self.classic = classic()
        self.shell = shell()
    }

    var body: some View {
        Group {
            switch usesShell {
            case true:
                shell
            case false:
                classic
            case nil:
                Theme.chassis
                    .ignoresSafeArea()
                    .background(SceneConnectionReader(resolve: resolve))
            }
        }
    }

    private func resolve(_ scene: UIWindowScene) {
        guard usesShell == nil else { return }

        #if os(visionOS)
        let platform = ShellModeDecision.Platform.visionOS
        // A spatial window has no iPad-style full-screen/windowed mode.
        let isFullScreen = false
        #else
        let platform = ShellModeDecision.Platform.iOS
        let isFullScreen = scene.isFullScreen
        #endif

        let idiom = ShellModeDecision.Idiom(scene.traitCollection.userInterfaceIdiom)
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["MULTIPLEX_FORCE_SHELL"]
        #else
        let override: String? = nil
        #endif
        let decision = ShellModeDecision.usesSingleWindowShell(
            platform: platform,
            idiom: idiom,
            isFullScreen: isFullScreen,
            environmentOverride: override
        )
        let overrideLabel = override ?? "none"

        Self.logger.info(
            "decision shell=\(decision, privacy: .public) idiom=\(idiom.logLabel, privacy: .public) isFullScreen=\(isFullScreen, privacy: .public) override=\(overrideLabel, privacy: .public)"
        )
        usesShell = decision
    }

    private static var logger: Logger {
        Logger(
            subsystem: "app.multiplexterm.multiplex",
            category: "shell"
        )
    }
}

private extension ShellModeDecision.Idiom {
    init(_ idiom: UIUserInterfaceIdiom) {
        switch idiom {
        case .phone: self = .phone
        case .pad: self = .pad
        default: self = .other
        }
    }

    var logLabel: String {
        switch self {
        case .phone: "phone"
        case .pad: "pad"
        case .other: "other"
        }
    }
}

/// A zero-size UIKit probe that reports the hosting scene at connect time.
private struct SceneConnectionReader: UIViewRepresentable {
    var resolve: @MainActor (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReporterView {
        ReporterView(resolve: resolve)
    }

    func updateUIView(_ view: ReporterView, context: Context) {
        view.resolve = resolve
        view.reportIfConnected()
    }

    @MainActor
    final class ReporterView: UIView {
        var resolve: @MainActor (UIWindowScene) -> Void

        init(resolve: @escaping @MainActor (UIWindowScene) -> Void) {
            self.resolve = resolve
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportIfConnected()
        }

        func reportIfConnected() {
            guard let scene = window?.windowScene else { return }
            resolve(scene)
        }
    }
}
