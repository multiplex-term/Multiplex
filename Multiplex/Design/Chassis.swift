import UIKit

// MARK: - UIKit chassis primitives

/// UIKit spelling of the shared TALLY chassis primitives. Callers receive
/// trait-dynamic UIColors so every screen follows the selected appearance.
@MainActor
enum UIKitChassis {
    static var chassis: UIColor { TallyPalette.chassis }
    static var bezel: UIColor { TallyPalette.bezel }
    static var bezelHi: UIColor { TallyPalette.bezelHi }
    static var screen: UIColor { TallyPalette.screen }
    static var signal: UIColor { TallyPalette.signal }
    static var signal2: UIColor { TallyPalette.signal2 }
    static var signal3: UIColor { TallyPalette.signal3 }

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
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = chassis
        appearance.shadowColor = bezelHi
        appearance.titleTextAttributes = [.foregroundColor: signal]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.tintColor = signal
    }
}
/// Compressed bold caps, proportional
/// tracking, one line. Accessibility text deliberately keeps the caller's
/// original capitalization instead of reading the visual all-caps treatment.
@MainActor
final class UIKitChassisLabel: UILabel {
    private var sourceText: String
    private let pointSize: CGFloat
    private let ink: UIColor

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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
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
        backgroundColor = UIKitChassis.chassis
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
        row.backgroundColor = UIKitChassis.chassis
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
