import UIKit

/// The parts of a live take's chrome shared by the pane's LISTENING bar and
/// the Talkback composer's eyebrow: the captioned lamps, the heard-not-yet-
/// delivered queue, and the language chip.
@MainActor
enum DictationChrome {
    enum Surface {
        /// The pane's context bar: full-size chip, 12 pt queue.
        case paneBar
        /// The composer's 20 pt eyebrow: trimmed chip, 10 pt queue.
        case composer

        fileprivate var languageIdentifier: String {
            switch self {
            case .paneBar: "terminalPane.dictation.language"
            case .composer: "terminal.talkback.dictation.language"
            }
        }
    }

    static func listeningLamp() -> UIKitTallyLamp {
        UIKitTallyLamp(caption: "LISTENING", color: TallyPalette.tally)
    }

    static func failureLamp() -> UIKitTallyLamp {
        UIKitTallyLamp(caption: "DICTATION", color: TallyPalette.caution)
    }

    /// A TALLY-bordered face over a native `UIMenu` — the rows are the
    /// system's, so padding, checkmarks, and dismissal come for free.
    static func languageButton(
        language: DictationLanguageChoice,
        choices: [DictationLanguageChoice],
        on surface: Surface,
        select: @escaping (DictationLanguageChoice) -> Void
    ) -> UIView {
        let button = UIButton(type: .custom)
        button.accessibilityIdentifier = surface.languageIdentifier
        button.accessibilityLabel = String(
            localized: "Dictation language: \(language.name) \(language.region). Change"
        )
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(
            title: String(localized: "Dictation language"),
            options: .singleSelection,
            children: choices.map { choice in
                UIAction(
                    title: choice.region.isEmpty
                        ? choice.name
                        : "\(choice.name) (\(choice.region))",
                    state: choice.id == language.id ? .on : .off
                ) { _ in select(choice) }
            }
        )

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "globe",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9 * Theme.typeScale,
                weight: .semibold
            )
        )
        switch surface {
        case .paneBar:
            config.imagePadding = 5
            config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)
        case .composer:
            config.imagePadding = 4
            config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        }
        var title = AttributedString(language.tag)
        title.font = UIKitChassis.monoFont(9, weight: .semibold)
        title.kern = 0.7
        title.foregroundColor = UIKitChassis.signal2
        config.attributedTitle = title
        button.configuration = config
        button.tintColor = UIKitChassis.signal2
        button.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )

        // The chip family's dress: one-point border on strata ground.
        let shell = UIKitTallyBorderedView()
        shell.backgroundColor = GlassPrototype.enabled
            ? GlassPrototype.material(
                GlassPrototype.strataMaterial,
                fallback: TallyPalette.chassis
            )
            : UIKitChassis.chassis
        shell.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            button.topAnchor.constraint(equalTo: shell.topAnchor),
            button.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
        ])
        return shell
    }
}

/// What has been heard and not yet delivered, drawn dimmer than delivered
/// text and truncated at the head — the tail is the part still being refined.
@MainActor
final class DictationPendingLabel: UILabel {
    var pending = "" {
        didSet {
            text = pending
            accessibilityLabel = String(localized: "Heard, not typed yet: \(pending)")
        }
    }

    init(on surface: DictationChrome.Surface) {
        super.init(frame: .zero)
        font = UIKitChassis.monoFont(surface == .paneBar ? 12 : 10)
        textColor = UIKitChassis.signal3
        lineBreakMode = .byTruncatingHead
        numberOfLines = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}
