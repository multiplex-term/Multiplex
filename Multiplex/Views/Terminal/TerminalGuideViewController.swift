import UIKit

/// Gesture field manual opened from a terminal's overflow menu. Content is
/// static; only platform/backend filtering and the responsive plate grid vary.
@MainActor
final class TerminalGuideViewController: UIViewController, AppAppearanceFollowing {
    private enum Layout {
        static let contentMaximumWidth: CGFloat = 680
        static let outerInset: CGFloat = 18
        static let bankSpacing: CGFloat = 24
        static let bankContentSpacing: CGFloat = 10
        static let plateSpacing: CGFloat = 12
        static let twoColumnMinimumWidth: CGFloat = 430
    }

    var onDone: (() -> Void)?
    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private let entries: [TerminalGuideEntry]
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var renderedColumnCount = 0

    init(context: TerminalGuideContext) {
        entries = TerminalGuide.entries(for: context)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Guide")
        view.backgroundColor = GlassPrototype.sheetGround
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel(String(localized: "Guide"), size: 12)
        #endif

        let done = UIBarButtonItem(
            title: String(localized: "Done"),
            style: .plain,
            target: self,
            action: #selector(donePressed)
        )
        done.tintColor = UIKitChassis.signal
        done.accessibilityLabel = String(localized: "Done")
        navigationItem.rightBarButtonItem = done

        configureContent()
        rebuildContent(columnCount: 1)
        applyAppAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = min(
            Layout.contentMaximumWidth,
            max(0, scrollView.bounds.width - Layout.outerInset * 2)
        )
        guard width > 0 else { return }
        let columnCount = width >= Layout.twoColumnMinimumWidth ? 2 : 1
        guard columnCount != renderedColumnCount else { return }
        rebuildContent(columnCount: columnCount)
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
        contentStack.spacing = Layout.bankSpacing
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Layout.outerInset * 2)
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Layout.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Layout.outerInset
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Layout.outerInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Layout.outerInset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Layout.contentMaximumWidth
            ),
            fillVisibleWidth,
        ])
    }

    private func rebuildContent(columnCount: Int) {
        renderedColumnCount = columnCount
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for bank in TerminalGuideBank.allCases {
            let bankEntries = entries.filter { $0.bank == bank }
            guard !bankEntries.isEmpty else { continue }
            contentStack.addArrangedSubview(makeBank(
                bank,
                entries: bankEntries,
                columnCount: columnCount
            ))
        }
    }

    private func makeBank(
        _ bank: TerminalGuideBank,
        entries: [TerminalGuideEntry],
        columnCount: Int
    ) -> UIView {
        let stack = UIStackView(arrangedSubviews: [TerminalGuideBankHeader(bank.title)])
        stack.axis = .vertical
        stack.spacing = Layout.bankContentSpacing

        if bank == .clipboard, let entry = entries.first {
            stack.addArrangedSubview(TerminalGuideClipboardNoteView(entry: entry))
            return stack
        }

        for start in stride(from: 0, to: entries.count, by: columnCount) {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .fill
            row.distribution = .fillEqually
            row.spacing = Layout.plateSpacing
            let end = min(start + columnCount, entries.count)
            for entry in entries[start..<end] {
                row.addArrangedSubview(TerminalGuidePlateView(entry: entry))
            }
            if columnCount == 2, end - start == 1 {
                let empty = UIView()
                empty.isAccessibilityElement = false
                row.addArrangedSubview(empty)
            }
            stack.addArrangedSubview(row)
        }
        return stack
    }

    @objc private func donePressed() {
        if let onDone {
            onDone()
        } else {
            navigationController?.dismiss(animated: true)
        }
    }
}

@MainActor
private final class TerminalGuideBankHeader: UIView {
    init(_ title: String) {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .header
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: UIKitChassis.monoFont(10, weight: .semibold),
                .kern: CGFloat(1),
            ]
        )
        label.textColor = UIKitChassis.signal
        label.isAccessibilityElement = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rule = UIView()
        rule.backgroundColor = UIKitChassis.bezelHi
        rule.isAccessibilityElement = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let row = UIStackView(arrangedSubviews: [label, rule])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
private final class TerminalGuidePlateView: UIKitTallyBorderedView {
    init(entry: TerminalGuideEntry) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        tallyBorderColor = UIKitChassis.bezelHi
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = "\(entry.title). \(entry.bodyText)"

        let figureWell = UIView()
        figureWell.backgroundColor = UIKitChassis.screen
        figureWell.isAccessibilityElement = false

        let figureLabel = UILabel()
        figureLabel.font = UIKitChassis.monoFont(9, weight: .semibold)
        figureLabel.textColor = UIKitChassis.signal3
        figureLabel.text = entry.figure.map { String(format: "FIG %02d", $0) }
        figureLabel.isAccessibilityElement = false
        figureLabel.setContentHuggingPriority(.required, for: .vertical)
        figureLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        figureWell.addSubview(figureLabel)
        figureLabel.translatesAutoresizingMaskIntoConstraints = false

        let pictogram = TerminalGuidePictogramView(entryID: entry.id)
        figureWell.addSubview(pictogram)
        pictogram.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            figureLabel.leadingAnchor.constraint(equalTo: figureWell.leadingAnchor, constant: 9),
            figureLabel.topAnchor.constraint(equalTo: figureWell.topAnchor, constant: 7),
            pictogram.leadingAnchor.constraint(equalTo: figureWell.leadingAnchor, constant: 9),
            pictogram.trailingAnchor.constraint(equalTo: figureWell.trailingAnchor, constant: -9),
            pictogram.topAnchor.constraint(equalTo: figureLabel.bottomAnchor, constant: 3),
            pictogram.bottomAnchor.constraint(equalTo: figureWell.bottomAnchor, constant: -8),
            pictogram.heightAnchor.constraint(equalTo: pictogram.widthAnchor, multiplier: 2 / 3),
        ])

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.isAccessibilityElement = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let copyArea = UIView()
        copyArea.isAccessibilityElement = false
        let copyStack = UIStackView(arrangedSubviews: [
            TerminalGuideTitleRow(title: entry.title, tag: entry.tag),
            TerminalGuideBodyLabel(runs: entry.body),
        ])
        copyStack.axis = .vertical
        copyStack.spacing = 8
        copyArea.addSubview(copyStack)
        copyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            copyStack.leadingAnchor.constraint(equalTo: copyArea.leadingAnchor, constant: 12),
            copyStack.trailingAnchor.constraint(equalTo: copyArea.trailingAnchor, constant: -12),
            copyStack.topAnchor.constraint(equalTo: copyArea.topAnchor, constant: 11),
            copyStack.bottomAnchor.constraint(lessThanOrEqualTo: copyArea.bottomAnchor, constant: -12),
        ])

        let stack = UIStackView(arrangedSubviews: [figureWell, divider, copyArea])
        stack.axis = .vertical
        stack.spacing = 0
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
private final class TerminalGuideTitleRow: UIView {
    init(title: String, tag: String?) {
        super.init(frame: .zero)
        let titleLabel = UILabel()
        titleLabel.attributedText = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: UIKitChassis.monoFont(11, weight: .semibold),
                .kern: CGFloat(1.1),
            ]
        )
        titleLabel.textColor = UIKitChassis.signal
        titleLabel.numberOfLines = 0
        titleLabel.isAccessibilityElement = false

        var views: [UIView] = [titleLabel]
        if let tag {
            let badge = TerminalGuideTagView(tag)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(badge)
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 7
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
private final class TerminalGuideTagView: UIKitTallyBorderedView {
    private let label = UILabel()

    init(_ tag: String) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        tallyBorderColor = UIKitChassis.bezelHi
        layer.cornerRadius = 2
        clipsToBounds = true
        isAccessibilityElement = false

        label.font = UIKitChassis.monoFont(8.5, weight: .medium)
        label.textColor = UIKitChassis.signal2
        label.text = tag
        label.isAccessibilityElement = false
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var forFirstBaselineLayout: UIView { label }
    override var forLastBaselineLayout: UIView { label }
}

@MainActor
private final class TerminalGuideBodyLabel: UILabel {
    private let runs: [TerminalGuideEntry.Run]

    init(runs: [TerminalGuideEntry.Run]) {
        self.runs = runs
        super.init(frame: .zero)
        numberOfLines = 0
        adjustsFontForContentSizeCategory = true
        isAccessibilityElement = false
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitPreferredContentSizeCategory.self,
            GlassAppearanceTrait.self,
        ]) { (label: TerminalGuideBodyLabel, _: UITraitCollection) in
            label.refreshText()
        }
        refreshText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        refreshText()
    }

    private func refreshText() {
        let result = NSMutableAttributedString()
        for run in runs {
            let attributes: [NSAttributedString.Key: Any]
            switch run {
            case .text:
                attributes = [
                    .font: UIFont.preferredFont(forTextStyle: .footnote),
                    .foregroundColor: UIKitChassis.signal2.resolvedColor(
                        with: traitCollection
                    ),
                ]
            case .control:
                attributes = [
                    .font: UIKitChassis.monoFont(10.5, weight: .semibold),
                    .foregroundColor: UIKitChassis.signal.resolvedColor(
                        with: traitCollection
                    ),
                ]
            case .key:
                attributes = [
                    .font: UIKitChassis.monoFont(10.5, weight: .semibold),
                    .foregroundColor: UIKitChassis.signal.resolvedColor(
                        with: traitCollection
                    ),
                    .backgroundColor: UIKitChassis.bezelHi.resolvedColor(
                        with: traitCollection
                    ),
                ]
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        result.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        attributedText = result
    }
}

@MainActor
private final class TerminalGuideClipboardNoteView: UIKitTallyBorderedView {
    init(entry: TerminalGuideEntry) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        tallyBorderColor = UIKitChassis.bezelHi
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false

        let pictogram = TerminalGuidePictogramView(entryID: entry.id)
        pictogram.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pictogram.widthAnchor.constraint(equalToConstant: 80),
            pictogram.heightAnchor.constraint(equalTo: pictogram.widthAnchor, multiplier: 2 / 3),
        ])

        let titleRow = TerminalGuideTitleRow(title: entry.title, tag: entry.tag)
        titleRow.isAccessibilityElement = true
        titleRow.accessibilityLabel = entry.title
        titleRow.accessibilityTraits = .header
        let body = TerminalGuideBodyLabel(runs: entry.body)
        body.isAccessibilityElement = true
        body.accessibilityLabel = entry.bodyText

        let button = TerminalGuideSettingsButton()
        let buttonRow = UIStackView(arrangedSubviews: [button, UIView()])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.spacing = 0

        let copy = UIStackView(arrangedSubviews: [titleRow, body, buttonRow])
        copy.axis = .vertical
        copy.spacing = 8

        let row = UIStackView(arrangedSubviews: [pictogram, copy])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 14
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
private final class TerminalGuideSettingsButton: UIButton {
    private let captionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.bezel
        layer.borderWidth = 1
        layer.cornerRadius = 2
        clipsToBounds = true
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        accessibilityLabel = String(localized: "Open Settings")

        captionLabel.isUserInteractionEnabled = false
        captionLabel.isAccessibilityElement = false
        addSubview(captionLabel)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, GlassAppearanceTrait.self]
        ) { (button: TerminalGuideSettingsButton, _: UITraitCollection) in
            button.refreshAppearance()
        }
        refreshAppearance()
        addAction(UIAction { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        let content = captionLabel.intrinsicContentSize
        return CGSize(width: ceil(content.width + 18), height: ceil(content.height + 10))
    }

    private func refreshAppearance() {
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
        captionLabel.attributedText = NSAttributedString(
            string: "OPEN SETTINGS",
            attributes: [
                .font: UIKitChassis.monoFont(9.5, weight: .semibold),
                .kern: CGFloat(0.95),
                .foregroundColor: UIKitChassis.signal2.resolvedColor(
                    with: traitCollection
                ),
            ]
        )
        invalidateIntrinsicContentSize()
    }
}
