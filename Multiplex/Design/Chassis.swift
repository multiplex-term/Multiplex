import Observation
import UIKit

// MARK: - UIKit chassis primitives

/// UIKit spelling of the shared TALLY chassis primitives. Callers receive
/// trait-dynamic UIColors so every screen follows the selected appearance.
@MainActor
enum UIKitChassis {
    static var chassis: UIColor { TallyPalette.chassis }
    // PROTOTYPE(GLASS): raised chrome and screens resolve to the smoke
    // materials at this one switch point. `chassis` deliberately does not —
    // sheets, forms, and the launch handoff stay opaque (plan §2); the few
    // full-bleed chassis layers are gated at their own sites instead.
    static var bezel: UIColor {
        GlassPrototype.enabled ? GlassPrototype.strata : TallyPalette.bezel
    }
    static var bezelHi: UIColor {
        GlassPrototype.enabled ? GlassPrototype.line : TallyPalette.bezelHi
    }
    static var screen: UIColor {
        GlassPrototype.enabled ? GlassPrototype.screenGlass : TallyPalette.screen
    }
    static var signal: UIColor { TallyPalette.signal }
    // PROTOTYPE(GLASS): secondary inks ride the mock's alpha ramp on glass
    // (light ink at 0.60 / 0.36); the primary ink stays as shipped.
    static var signal2: UIColor {
        GlassPrototype.enabled ? GlassPrototype.signal2 : TallyPalette.signal2
    }
    static var signal3: UIColor {
        GlassPrototype.enabled ? GlassPrototype.signal3 : TallyPalette.signal3
    }

    static func uiFont(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size * Theme.typeScale, weight: weight)
    }

    static func monoFont(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size * Theme.typeScale, weight: weight)
    }

    static func compressedLabelFont(_ size: CGFloat) -> UIFont {
        .systemFont(
            ofSize: size * Theme.typeScale,
            weight: .bold,
            width: .compressed
        )
    }

    static func configureSheetNavigationBar(_ navigationBar: UINavigationBar) {
        let appearance = UINavigationBarAppearance()
        // PROTOTYPE(GLASS): on glass the sheet root carries the smoke and the
        // bar goes transparent over it; opaque chassis otherwise.
        if GlassPrototype.enabled && GlassSelectionState.shared.isGlass {
            appearance.configureWithTransparentBackground()
        } else {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = chassis
        }
        appearance.shadowColor = bezelHi
        appearance.titleTextAttributes = [.foregroundColor: signal]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.tintColor = signal
    }
}

extension UIView {
    /// Re-applies text-bearing dynamic colors after an in-place appearance
    /// override. visionOS redraws dynamic view grounds when a window is
    /// switched directly between LIGHT and DARK, but UILabel can retain the
    /// color it resolved for the previous traits. Reassigning its authored
    /// color payload after trait propagation makes UIKit resolve it against
    /// the appearance the view now carries.
    fileprivate func refreshDynamicTextColors() {
        if let label = self as? UILabel {
            // UILabel can synthesize attributedText for a plain `text` value,
            // so refresh both payloads: textColor owns plain ink, while an
            // explicit foreground attribute owns tracked/mixed ink.
            label.textColor = label.textColor
            if let attributedText = label.attributedText {
                label.attributedText = NSAttributedString(
                    attributedString: attributedText
                )
            }
            label.setNeedsDisplay()
        }
        subviews.forEach { $0.refreshDynamicTextColors() }
    }
}

extension UIViewController {
    /// The override write and its trait delivery finish after the current
    /// UIKit callback. Refresh on the following main-actor turn, when labels
    /// (including ones rebuilt by that callback) carry their final traits.
    func refreshDynamicTextColorsAfterTraitPropagation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            viewIfLoaded?.refreshDynamicTextColors()
            if let navigationController {
                navigationController.viewIfLoaded?.refreshDynamicTextColors()
                UIKitChassis.configureSheetNavigationBar(
                    navigationController.navigationBar
                )
            }
        }
    }
}

/// Compressed bold caps, proportional
/// tracking, one line. Accessibility text deliberately keeps the caller's
/// original capitalization instead of reading the visual all-caps treatment.
@MainActor
final class UIKitChassisLabel: UILabel {
    private var sourceText: String
    private let pointSize: CGFloat
    private var ink: UIColor

    init(_ text: String, size: CGFloat = 12, color: UIColor? = nil) {
        sourceText = text
        pointSize = size
        ink = color ?? UIKitChassis.signal
        super.init(frame: .zero)
        numberOfLines = 1
        lineBreakMode = .byTruncatingTail
        accessibilityLabel = text
        refreshAttributedText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setText(_ text: String) {
        sourceText = text
        accessibilityLabel = text
        refreshAttributedText()
    }

    /// Changes only the label's ink while preserving its UIKit identity and
    /// layout subtree. Interactive controls use this instead of replacing a
    /// label that may still be participating in the current touch/layout pass.
    func setInk(_ color: UIColor) {
        ink = color
        refreshAttributedText()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshAttributedText()
    }

    /// The ink is baked into the attributed string as a RESOLVED color, and
    /// a label built before its window exists resolves against placeholder
    /// traits — a popover panel's dim annotations shipped the LIGHT ink onto
    /// a dark panel this way (trait-change delivery while detached is not
    /// guaranteed). Window attach is the reliable moment the real traits
    /// exist; one refresh there covers every presentation shape.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        refreshAttributedText()
    }

    private func refreshAttributedText() {
        let scaled = pointSize * Theme.typeScale
        attributedText = NSAttributedString(
            string: sourceText.uppercased(),
            attributes: [
                .font: UIKitChassis.compressedLabelFont(pointSize),
                .kern: scaled * 0.09,
                .foregroundColor: ink.resolvedColor(with: traitCollection),
            ]
        )
    }
}

/// Square one-point outline whose dynamic color follows an in-place appearance
/// switch. `CALayer.borderColor` stores a CGColor snapshot, so unlike view
/// backgrounds it must be refreshed when traits change.
@MainActor
class UIKitTallyBorderedView: UIView {
    var tallyBorderColor = UIKitChassis.bezelHi {
        didSet { refreshBorder() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.borderWidth = 1
        refreshBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshBorder()
    }

    private func refreshBorder() {
        layer.borderColor = tallyBorderColor.resolvedColor(with: traitCollection).cgColor
    }
}

/// Native square chassis badge used as a control.
/// Its custom content view keeps the same 9×typeScale symbol, five-point gap,
/// 9/5 padding, monospace caption, square ground, and one-point border.
@MainActor
final class UIKitChassisChip: UIKitTallyBorderedView {
    private let symbolView = UIImageView()
    private let captionLabel = UILabel()
    private let contentStack = UIStackView()
    private let action: () -> Void
    private var caption = ""
    var isProminent: Bool {
        didSet {
            tallyBorderColor = isProminent ? UIKitChassis.signal2 : UIKitChassis.bezelHi
            symbolView.tintColor = isProminent ? UIKitChassis.signal : UIKitChassis.signal2
            refreshCaption()
        }
    }

    init(
        _ caption: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.action = action
        isProminent = prominent
        super.init(frame: .zero)
        // PROTOTYPE(GLASS): chips are strata over the smoke, not chassis
        // cuts; pinned LIGHT keeps the chassis ground (§8 v1).
        backgroundColor = GlassPrototype.enabled
            ? GlassPrototype.material(
                GlassPrototype.strataMaterial,
                fallback: TallyPalette.chassis
            )
            : UIKitChassis.chassis
        tallyBorderColor = prominent ? UIKitChassis.signal2 : UIKitChassis.bezelHi
        isAccessibilityElement = true
        accessibilityTraits = .button
        self.accessibilityLabel = accessibilityLabel
        hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 5
        contentStack.isUserInteractionEnabled = false
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = isProminent ? UIKitChassis.signal : UIKitChassis.signal2
        contentStack.addArrangedSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
            symbolView.heightAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
        ])

        captionLabel.numberOfLines = 1
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentStack.addArrangedSubview(captionLabel)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        addGestureRecognizer(tap)
        setContent(caption: caption, systemImage: systemImage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setContent(caption: String, systemImage: String?) {
        self.caption = caption
        symbolView.isHidden = systemImage == nil
        symbolView.image = systemImage.flatMap {
            UIImage(
                systemName: $0,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            )
        }
        refreshCaption()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let content = contentStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        return CGSize(
            width: ceil(content.width + 18),
            height: ceil(content.height + 10)
        )
    }

    /// A chassis chip participates in text-baseline rows through its caption,
    /// just as the original SwiftUI `ChassisChip` did. Without forwarding the
    /// baseline, UIKit treats this bordered wrapper's bottom edge as the
    /// baseline and drops SHELL below the status/menu centerline.
    override var forFirstBaselineLayout: UIView { captionLabel }
    override var forLastBaselineLayout: UIView { captionLabel }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        symbolView.tintColor = isProminent ? UIKitChassis.signal : UIKitChassis.signal2
        refreshCaption()
    }

    override func accessibilityActivate() -> Bool {
        action()
        return true
    }

    @objc private func pressed() {
        action()
    }

    private func refreshCaption() {
        captionLabel.attributedText = NSAttributedString(
            string: caption,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: (isProminent ? UIKitChassis.signal : UIKitChassis.signal2)
                    .resolvedColor(with: traitCollection),
            ]
        )
    }
}

/// The lit lamp + caption, the one spelling every surface uses. Tally red is
/// always captioned so it can never read as an error; other states reuse the
/// same anatomy — a 7×typeScale dot with its own glow, a five-point gap, and a
/// monospace caption in the lamp's own color.
@MainActor
final class UIKitTallyLamp: UIView {
    private let dot = UIView()
    private let captionLabel = UILabel()
    private let caption: String
    private let color: UIColor

    init(caption: String, color: UIColor) {
        self.caption = caption
        self.color = color
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = caption.lowercased()

        // The dot tracks the type scale with its caption so the lamp keeps its
        // proportions on iOS-on-Mac.
        let diameter = 7 * Theme.typeScale
        dot.backgroundColor = color
        dot.layer.cornerRadius = diameter / 2
        dot.layer.shadowOpacity = 0.7
        dot.layer.shadowRadius = 4
        dot.layer.shadowOffset = .zero
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: diameter),
            dot.heightAnchor.constraint(equalToConstant: diameter),
        ])

        // The caption is the lamp's meaning — it must win layout compression,
        // or a crowded row shows an uncaptioned red dot.
        captionLabel.isAccessibilityElement = false
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [dot, captionLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 5
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// A lamp stands beside prose in baseline-aligned rows (INVALID + its
    /// explanation), so the caption carries the baseline; this wrapper's own
    /// bottom edge would drop the sentence beside it.
    override var forFirstBaselineLayout: UIView { captionLabel }
    override var forLastBaselineLayout: UIView { captionLabel }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshInk()
    }

    /// The dot's fill follows the appearance on its own; the glow's CGColor
    /// does not — it flattens whatever traits are current when it is taken,
    /// and these lamps are built from observation renders rather than a UIKit
    /// callback. Resolve both against this view's traits and re-resolve
    /// whenever the appearance flips.
    private func refreshInk() {
        let resolved = color.resolvedColor(with: traitCollection)
        dot.layer.shadowColor = resolved.cgColor
        captionLabel.attributedText = NSAttributedString(
            string: caption,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .bold),
                .kern: 1.2,
                .foregroundColor: resolved,
            ]
        )
    }
}

/// One native TALLY form section: bezel title/header, one chassis row, square
/// divider/border, and the optional explanatory postscript below it.
@MainActor
final class UIKitTallyFormSectionView: UIView {
    private let titleLabel = UIKitChassisLabel("", size: 10)
    private let detailLabel = UILabel()
    private let detailContainer = UIView()

    init(title: String, detail: String?, contentView: UIView) {
        super.init(frame: .zero)

        titleLabel.setText(title)
        titleLabel.accessibilityTraits.insert(.header)

        let header = UIView()
        header.backgroundColor = UIKitChassis.bezel
        header.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
        ])

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let row = UIView()
        row.backgroundColor = GlassPrototype.clearedChassis
        row.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            contentView.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            contentView.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            contentView.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
        ])

        let cardStack = UIStackView(arrangedSubviews: [header, divider, row])
        cardStack.axis = .vertical
        cardStack.spacing = 0

        let card = UIKitTallyBorderedView()
        card.addSubview(cardStack)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let sectionStack = UIStackView(arrangedSubviews: [card])
        sectionStack.axis = .vertical
        sectionStack.spacing = 8

        detailLabel.font = UIKitChassis.uiFont(10)
        detailLabel.textColor = UIKitChassis.signal2
        detailLabel.numberOfLines = 0
        detailContainer.addSubview(detailLabel)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -2),
            detailLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        sectionStack.addArrangedSubview(detailContainer)
        setDetail(detail)

        addSubview(sectionStack)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sectionStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            sectionStack.topAnchor.constraint(equalTo: topAnchor),
            sectionStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setTitle(_ title: String) {
        titleLabel.setText(title)
    }

    func setDetail(_ detail: String?) {
        detailLabel.text = detail
        detailContainer.isHidden = detail == nil
    }

}

// MARK: - Appearance follow-through

extension AppAppearance {
    /// The style a scene carries for this choice — what
    /// `UIKitSceneRootViewController` writes onto its root and window.
    var interfaceStyle: UIUserInterfaceStyle {
        switch resolvedOverride {
        case nil: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Reads the style back off a scene window. Style alone cannot distinguish
    /// DARK from GLASS — both pin dark traits — so a store-free presenter gets
    /// `.dark`; `GlassAppearanceTrait` carries the independent material choice
    /// onto its hosting window beside this style mapping.
    init(sceneWindowStyle style: UIUserInterfaceStyle) {
        switch style {
        case .light: self = .light
        case .dark: self = .dark
        default: self = .system
        }
    }
}

extension UIViewController {
    /// The nearest explicit appearance override at or above this controller,
    /// falling back to the hosting window's. A popover presented from
    /// ornament-mounted content lands in a window of its own on visionOS, so
    /// it inherits nothing — it must carry this forward or a pinned
    /// LIGHT/DARK presents in the platform's native style. `.unspecified`
    /// (SYSTEM everywhere) stays `.unspecified`, which keeps the popover on
    /// its own window's native appearance.
    var inheritedInterfaceStyleOverride: UIUserInterfaceStyle {
        var candidate: UIViewController? = self
        while let controller = candidate {
            if controller.overrideUserInterfaceStyle != .unspecified {
                return controller.overrideUserInterfaceStyle
            }
            candidate = controller.parent
        }
        return viewIfLoaded?.window?.overrideUserInterfaceStyle ?? .unspecified
    }
}

/// Keeps one presented surface in step with `ThemeStore.appearance`.
/// Observation callbacks are one-shot, so each pass registers the next — the
/// same loop `UIKitSceneRootViewController` runs for the scene window.
@MainActor
final class AppAppearanceFollower {
    private weak var themes: ThemeStore?
    private var apply: ((AppAppearance) -> Void)?
    private var generation = 0

    /// Applies the current choice now and re-applies it on every later change.
    func follow(_ themes: ThemeStore, apply: @escaping (AppAppearance) -> Void) {
        self.themes = themes
        self.apply = apply
        generation &+= 1
        observe(generation: generation)
    }

    /// Drops the link — a surface handed a one-off appearance instead.
    func stop() {
        generation &+= 1
        themes = nil
        apply = nil
    }

    private func observe(generation: Int) {
        guard generation == self.generation, let themes, let apply else { return }
        let appearance = withObservationTracking {
            themes.appearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe(generation: generation)
            }
        }
        apply(appearance)
    }
}

/// A presented chassis surface that follows the app's appearance choice — the
/// UIKit counterpart of the retired SwiftUI `followsAppAppearance()`.
///
/// Two things make this structural rather than per-call-site. A sheet's own
/// `overrideUserInterfaceStyle` outranks its window's, so a surface that only
/// snapshots the choice as it is presented never hears a flip made while it is
/// open (Settings in another iPad window, or the debug appearance hook). And a
/// presenter that forgets to hand the choice over leaves the default `.system`
/// writing `.unspecified` over the scene's pinned override, dropping LIGHT or
/// DARK for the whole window. Conformers keep their `appAppearance` property —
/// assigning it directly still works; the link just keeps assigning it.
@MainActor
protocol AppAppearanceFollowing: AnyObject {
    /// The choice this surface paints with.
    var appAppearance: AppAppearance { get set }
    /// Storage for the link — one line per conformer:
    /// `let appAppearanceFollower = AppAppearanceFollower()`.
    var appAppearanceFollower: AppAppearanceFollower { get }
}

extension AppAppearanceFollowing where Self: UIViewController {
    /// Live link: the surface paints the current choice and keeps following it.
    func followAppAppearance(_ themes: ThemeStore) {
        appAppearanceFollower.follow(themes) { [weak self] appearance in
            self?.appAppearance = appearance
        }
    }

    /// Store-free seed for a presenter that has no `ThemeStore` in hand: the
    /// scene window the presenter lives in already carries the applied choice.
    /// Exact, but a snapshot — it cannot follow a later flip.
    func adoptAppAppearance(presentedFrom presenter: UIViewController) {
        appAppearanceFollower.stop()
        appAppearance = AppAppearance(
            sceneWindowStyle: presenter.viewIfLoaded?.window?.overrideUserInterfaceStyle
                ?? .unspecified
        )
    }

    /// Whichever of the two the presenter can supply.
    func followAppAppearance(_ themes: ThemeStore?, presentedFrom presenter: UIViewController) {
        if let themes {
            followAppAppearance(themes)
        } else {
            adoptAppAppearance(presentedFrom: presenter)
        }
    }

    /// The write a presented chassis surface makes: pin itself and the
    /// navigation controller it is hosted in, then re-tint the opaque sheet
    /// navigation bar. `pinsHostingChrome` is false for a pushed screen, whose
    /// hosting chrome belongs to the root of that stack.
    func applyAppAppearance(pinsHostingChrome: Bool = true) {
        let style = appAppearance.interfaceStyle
        overrideUserInterfaceStyle = style
        if pinsHostingChrome {
            navigationController?.overrideUserInterfaceStyle = style
            pinHostingWindow(to: style)
        }
        if let navigationBar = navigationController?.navigationBar {
            UIKitChassis.configureSheetNavigationBar(navigationBar)
        }
        refreshDynamicTextColorsAfterTraitPropagation()
    }

    /// visionOS hosts a sheet in a window of its own, which misses the override
    /// already in place when it presents — that window needs the write. A sheet
    /// sharing the scene's window (every iOS presentation) must not clear an
    /// override it does not own; the scene root writes that one.
    private func pinHostingWindow(to style: UIUserInterfaceStyle) {
        guard let window = viewIfLoaded?.window else { return }
        // PROTOTYPE(GLASS): a sheet hosted in its OWN window carries the
        // glass trait too ("all modals need apply"). A presentation sharing
        // the scene's window must not write it — the scene root owns that
        // trait, and terminal scenes deliberately never carry it.
        if window !== presentingViewController?.viewIfLoaded?.window {
            window.traitOverrides[GlassAppearanceTrait.self] =
                GlassPrototype.enabled && GlassSelectionState.shared.isGlass
        }
        guard style != .unspecified
            || window !== presentingViewController?.viewIfLoaded?.window
        else { return }
        window.overrideUserInterfaceStyle = style
    }
}

// MARK: - Keyboard clearance

extension UIViewController {
    /// Spends a docked keyboard as CONTENT inset on a form's scroll view, never
    /// as that scroll view's frame — the one shape every chassis form shares.
    ///
    /// The trap it replaces: `keyboardLayoutGuide` rests on the BOTTOM
    /// SAFE-AREA edge while no keyboard is up, so a scroll view whose frame is
    /// pinned to the guide ends there — content clipped mid-glyph above a dead
    /// home-indicator band (user-reported on the New Session sheet). The frame
    /// spans the window instead and `contentInsetAdjustmentBehavior` already
    /// pays the safe area, so only the overlap BEYOND that band is added here
    /// and the two can never charge for it twice. Undocked keyboards leave the
    /// guide where it is (`followsUndockedKeyboard` is false), which is the
    /// app's floating-keyboard rule for free.
    ///
    /// Call it from `viewDidLayoutSubviews`: the guide's own constants dirty
    /// this view's layout, so the pass runs inside the keyboard's animation and
    /// the inset rides along with it.
    func applyKeyboardContentInset(to scrollView: UIScrollView) {
        let guideTop = view.keyboardLayoutGuide.layoutFrame.minY
        // A guide the engine has not measured yet reports an empty frame; a
        // resting one always sits below the window's own top edge.
        guard !view.bounds.isEmpty, guideTop > 0 else { return }
        let inset = max(0, view.bounds.maxY - guideTop - view.safeAreaInsets.bottom)
        guard abs(scrollView.contentInset.bottom - inset) > 0.5 else { return }
        scrollView.contentInset.bottom = inset
        scrollView.verticalScrollIndicatorInsets.bottom = inset
    }
}
