import UIKit

extension ReleaseNotePlatform {
    /// Resolved in the view layer — the models import no UIKit. An
    /// iOS-app-on-Mac binary reports the iPad idiom, which is right: it wears
    /// the iPad chrome the notes describe.
    static var current: ReleaseNotePlatform {
        #if os(visionOS)
        return .vision
        #else
        return UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad
        #endif
    }
}

// MARK: - The launch card

/// What's New, as the one screen a launch interruption is worth: the release's
/// own promise line, the four changes this platform actually gets, an honest
/// count of what is left, and the road to the rest.
///
/// It carries no navigation bar on purpose — DONE is one of its two chips, and
/// a system bar above a card this short reads as chrome for nothing.
@MainActor
final class WhatsNewViewController: UIViewController, AppAppearanceFollowing {
    private enum Metrics {
        static let contentMaximumWidth: CGFloat = 560
        static let outerInset: CGFloat = 24
        // Tight on purpose: the card's whole claim is that it ends inside one
        // phone screen, and these two are what buy that at 375 pt.
        static let sectionSpacing: CGFloat = 15
        static let rowVerticalPadding: CGFloat = 9
        static let rowSpacing: CGFloat = 4
    }

    /// iPad form sheets and visionOS both honor this; iPhone sizes itself to
    /// the content instead (`updateCompactDetent`).
    static let preferredSheetSize = CGSize(width: 620, height: 560)

    var onDone: (() -> Void)?
    /// The road to the full record. The presenter decides how — the deck
    /// swaps this card for the log rather than stacking a second sheet on it.
    var onFullNotes: (() -> Void)?

    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    let platform: ReleaseNotePlatform
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var compactContentHeight: CGFloat = 0

    init(platform: ReleaseNotePlatform = .current) {
        self.platform = platform
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSheetSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GlassPrototype.sheetGround
        configureContent()
        applyAppAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureCompactSheetIfNeeded()
        applyAppAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCompactDetent()
    }

    // MARK: Content

    private func configureContent() {
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = GlassPrototype.clearedChassis
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
        ])

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Metrics.sectionSpacing
        contentStack.addArrangedSubview(makeIdentityRail())
        contentStack.addArrangedSubview(makePromise())
        contentStack.addArrangedSubview(makeHighlights())
        if let also = ReleaseNotes.alsoLine(for: platform) {
            contentStack.addArrangedSubview(makeAlsoLine(also))
        }
        contentStack.addArrangedSubview(makeActions())

        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -Metrics.outerInset * 2
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Metrics.contentMaximumWidth
            ),
            fillVisibleWidth,
        ])
    }

    /// The app mark and the release it is announcing, on the same raised rail
    /// a host wears on the wall.
    private func makeIdentityRail() -> UIView {
        let mark = UIKitChassisLabel("Multiplex", size: 12)
        let version = UILabel()
        version.font = UIKitChassis.monoFont(11)
        version.textColor = UIKitChassis.signal2
        version.text = ReleaseNotes.version
        version.accessibilityLabel = "Version \(ReleaseNotes.version)"

        let row = UIStackView(arrangedSubviews: [mark, ReleaseNotesChrome.spacer(), version])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

        let rail = UIKitTallyBorderedView(frame: .zero)
        rail.backgroundColor = GlassPrototype.strataChassis
        rail.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            row.topAnchor.constraint(equalTo: rail.topAnchor),
            row.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
        ])
        return rail
    }

    private func makePromise() -> UIView {
        ReleaseNotesChrome.label(
            ReleaseNotes.promise,
            style: .title3,
            weight: .medium,
            color: UIKitChassis.signal
        )
    }

    private func makeHighlights() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        let highlights = ReleaseNotes.highlights(for: platform)
        for (index, highlight) in highlights.enumerated() {
            stack.addArrangedSubview(ReleaseNotesChrome.rule())
            stack.addArrangedSubview(makeHighlightRow(highlight))
            if index == highlights.count - 1 {
                stack.addArrangedSubview(ReleaseNotesChrome.rule())
            }
        }
        return stack
    }

    private func makeHighlightRow(_ highlight: ReleaseNoteHighlight) -> UIView {
        let heading = ReleaseNotesChrome.heading(highlight.title, tag: highlight.tag, size: 11.5)
        let body = ReleaseNotesChrome.label(
            highlight.body,
            style: .subheadline,
            color: UIKitChassis.signal2
        )
        let row = UIStackView(arrangedSubviews: [heading, body])
        row.axis = .vertical
        row.alignment = .fill
        row.spacing = Metrics.rowSpacing
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(
            top: Metrics.rowVerticalPadding,
            left: 0,
            bottom: Metrics.rowVerticalPadding,
            right: 0
        )
        row.isAccessibilityElement = true
        row.accessibilityLabel = [highlight.title, highlight.tag, highlight.body]
            .compactMap { $0 }
            .joined(separator: ", ")
        return row
    }

    private func makeAlsoLine(_ text: String) -> UIView {
        ReleaseNotesChrome.label(text, style: .footnote, color: UIKitChassis.signal3)
    }

    private func makeActions() -> UIView {
        let fullNotes = UIKitChassisChip(
            "FULL NOTES",
            accessibilityLabel: "Full notes"
        ) { [weak self] in
            self?.onFullNotes?()
        }
        let done = UIKitChassisChip(
            "DONE",
            prominent: true,
            accessibilityLabel: "Done"
        ) { [weak self] in
            self?.onDone?()
        }
        fullNotes.accessibilityIdentifier = "whatsNew.fullNotes"
        done.accessibilityIdentifier = "whatsNew.done"

        let row = UIStackView(arrangedSubviews: [
            ReleaseNotesChrome.spacer(), fullNotes, done,
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        return row
    }

    // MARK: Compact sizing

    #if os(visionOS)
    // Sheet detents do not exist on visionOS, which sizes from
    // `preferredContentSize` instead. Nothing here is reachable there.
    private func configureCompactSheetIfNeeded() {}
    private func updateCompactDetent() {}
    #else
    private static let detentIdentifier = UISheetPresentationController
        .Detent.Identifier("whatsNew.card")

    /// iPhone sizes the sheet to the card instead of parking it at a stock
    /// detent: the whole point of this shape is that it ends where it ends.
    private func configureCompactSheetIfNeeded() {
        guard traitCollection.horizontalSizeClass == .compact,
              let sheet = sheetPresentationController else { return }
        sheet.prefersGrabberVisible = false
        sheet.detents = [
            .custom(identifier: Self.detentIdentifier) { [weak self] context in
                guard let self, compactContentHeight > 0 else {
                    return context.maximumDetentValue * 0.7
                }
                return min(compactContentHeight, context.maximumDetentValue)
            },
        ]
    }

    private func updateCompactDetent() {
        guard traitCollection.horizontalSizeClass == .compact,
              let sheet = sheetPresentationController,
              view.bounds.width > 0 else { return }
        let available = min(
            Metrics.contentMaximumWidth,
            view.bounds.width - Metrics.outerInset * 2
        )
        guard available > 0 else { return }
        let fitting = contentStack.systemLayoutSizeFitting(
            CGSize(width: available, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = fitting.height + Metrics.outerInset * 2 + view.safeAreaInsets.bottom
        guard abs(height - compactContentHeight) > 0.5 else { return }
        compactContentHeight = height
        sheet.animateChanges { sheet.invalidateDetents() }
    }
    #endif
}

// MARK: - The full record

/// Every change in the release, banked and platform-filtered. Reached from the
/// card’s FULL NOTES chip and from Settings ▸ About ▸ What’s New — which is
/// what keeps the launch card from being the only road to any of it.
@MainActor
final class ReleaseLogViewController: UIViewController, AppAppearanceFollowing {
    private enum Metrics {
        static let contentMaximumWidth: CGFloat = 680
        static let outerInset: CGFloat = 18
        static let bankSpacing: CGFloat = 22
        static let entrySpacing: CGFloat = 12
    }

    static let preferredSheetSize = CGSize(width: 720, height: 900)

    var onDone: (() -> Void)?

    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    let platform: ReleaseNotePlatform
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    init(platform: ReleaseNotePlatform = .current) {
        self.platform = platform
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSheetSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "What’s New"
        view.backgroundColor = GlassPrototype.sheetGround
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel("What’s New", size: 12)
        #endif

        let done = UIBarButtonItem(
            title: "Done",
            style: .plain,
            target: self,
            action: #selector(donePressed)
        )
        done.tintColor = UIKitChassis.signal
        done.accessibilityLabel = "Done"
        navigationItem.rightBarButtonItem = done

        configureContent()
        applyAppAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppAppearance()
    }

    private func configureContent() {
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = GlassPrototype.clearedChassis
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
        ])

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Metrics.bankSpacing
        contentStack.addArrangedSubview(makeHeader())
        for bank in ReleaseNotes.banks(for: platform) {
            contentStack.addArrangedSubview(makeBank(bank.bank, entries: bank.entries))
        }

        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -Metrics.outerInset * 2
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Metrics.contentMaximumWidth
            ),
            fillVisibleWidth,
        ])
    }

    private func makeHeader() -> UIView {
        let mark = UIKitChassisLabel("Multiplex \(ReleaseNotes.version)", size: 18)
        mark.numberOfLines = 0
        let promise = ReleaseNotesChrome.label(
            ReleaseNotes.promise,
            style: .subheadline,
            color: UIKitChassis.signal
        )
        let stack = UIStackView(arrangedSubviews: [mark, promise])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 7
        return stack
    }

    private func makeBank(_ bank: ReleaseNoteBank, entries: [ReleaseNoteEntry]) -> UIView {
        let title = UIKitChassisLabel(bank.title, size: 9.5, color: UIKitChassis.signal2)
        let rule = ReleaseNotesChrome.rule()
        let header = UIStackView(arrangedSubviews: [title, rule])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10

        let stack = UIStackView(arrangedSubviews: [header])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Metrics.entrySpacing
        for entry in entries {
            stack.addArrangedSubview(makeEntry(entry))
        }
        return stack
    }

    private func makeEntry(_ entry: ReleaseNoteEntry) -> UIView {
        let heading = ReleaseNotesChrome.heading(entry.title, tag: entry.tag, size: 11)
        let body = ReleaseNotesChrome.label(
            entry.body,
            style: .subheadline,
            color: UIKitChassis.signal2
        )
        let copy = UIStackView(arrangedSubviews: [heading, body])
        copy.axis = .vertical
        copy.alignment = .fill
        copy.spacing = 4
        copy.isAccessibilityElement = true
        copy.accessibilityLabel = [entry.title, entry.tag, entry.body]
            .compactMap { $0 }
            .joined(separator: ", ")

        // The bank's entries hang off one vertical line — the spine anatomy
        // the wall's tiles already use to say "these belong to that".
        let spine = UIView()
        spine.backgroundColor = UIKitChassis.bezelHi
        spine.translatesAutoresizingMaskIntoConstraints = false
        spine.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let row = UIStackView(arrangedSubviews: [spine, copy])
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 11
        return row
    }

    @objc private func donePressed() {
        onDone?()
    }
}

// MARK: - Shared chrome

/// The few pieces both renderings share. Kept together so the card and the log
/// cannot drift into two different voices for the same content.
@MainActor
private enum ReleaseNotesChrome {
    static func label(
        _ text: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        // Body copy keeps Dynamic Type; the Mac's point-grid boost is applied
        // once at the scene root, so it must not be multiplied in again here.
        let pointSize = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: pointSize, weight: weight)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    /// A change's name, with the platform tag only where the change is scoped
    /// to one — an "every platform" badge would be a row spent saying nothing.
    static func heading(_ title: String, tag: String?, size: CGFloat) -> UIView {
        let label = UIKitChassisLabel(title, size: size)
        label.numberOfLines = 0
        guard let tag else { return label }
        // Verbatim, not upper-cased: the chassis voice is caps, but "iPad"
        // and "iPhone" are product names that keep their own capitalization.
        let badge = SettingsBadgeView(tag)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, badge, spacer()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    static func rule() -> UIView {
        let rule = UIView()
        rule.backgroundColor = UIKitChassis.bezelHi
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rule.setContentCompressionResistancePriority(.required, for: .vertical)
        return rule
    }

    static func spacer() -> UIView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }
}
