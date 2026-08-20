import UIKit

/// Upload progress/failure surface used directly by the native terminal pane.
/// It preserves the compact TALLY pill metrics and combined
/// accessibility announcement.
@MainActor
final class DropStatusPillView: UIView {
    private let stack = UIStackView()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let failureDot = UIView()
    private let label = UILabel()

    init(state: TerminalSessionController.DropState) {
        super.init(frame: .zero)
        backgroundColor = TallyPalette.bezel
        layer.borderWidth = 1
        isAccessibilityElement = true

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        progress.progressTintColor = TallyPalette.signal
        progress.trackTintColor = TallyPalette.signal3
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(progress)

        failureDot.backgroundColor = TallyPalette.caution
        failureDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            failureDot.widthAnchor.constraint(equalToConstant: 5),
            failureDot.heightAnchor.constraint(equalToConstant: 5),
        ])
        stack.addArrangedSubview(failureDot)

        label.font = .monospacedSystemFont(
            ofSize: 10 * Theme.typeScale,
            weight: .regular
        )
        label.textColor = TallyPalette.signal2
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(label)

        apply(state)
        refreshResolvedLayerColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ state: TerminalSessionController.DropState) {
        switch state {
        case .uploading(let name, let fraction):
            progress.isHidden = false
            failureDot.isHidden = true
            progress.setProgress(Float(fraction), animated: false)
            label.text = "\(name) · \(Int(fraction * 100))%"
        case .failed(let message):
            progress.isHidden = true
            failureDot.isHidden = false
            label.text = message
        }
        accessibilityLabel = label.text
        invalidateIntrinsicContentSize()
    }

    func fittingSize(maximumWidth: CGFloat?) -> CGSize {
        let contentSize = stack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        let natural = CGSize(width: contentSize.width + 24, height: contentSize.height + 14)
        guard let maximumWidth else { return natural }
        return CGSize(width: min(natural.width, maximumWidth), height: natural.height)
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(maximumWidth: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshResolvedLayerColors()
    }

    private func refreshResolvedLayerColors() {
        layer.borderColor = TallyPalette.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}

/// Full-pane upload target highlight used by the native terminal pane.
@MainActor
final class DropTargetVeilView: UIView {
    private let icon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TallyPalette.chassis.withAlphaComponent(0.35)
        isUserInteractionEnabled = false
        layer.borderWidth = 2

        icon.image = UIImage(
            systemName: "arrow.down.doc",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 22 * Theme.typeScale,
                weight: .semibold
            )
        )
        icon.tintColor = TallyPalette.signal
        icon.contentMode = .scaleAspectFit

        let caption = UILabel()
        let scaled = 11 * Theme.typeScale
        caption.attributedText = NSAttributedString(
            string: "DROP TO UPLOAD",
            attributes: [
                .font: UIFont.systemFont(
                    ofSize: scaled,
                    weight: .bold,
                    width: .compressed
                ),
                .kern: scaled * 0.09,
                .foregroundColor: TallyPalette.signal2,
            ]
        )
        caption.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [icon, caption])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Drop to upload")
        refreshResolvedLayerColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshResolvedLayerColors()
    }

    private func refreshResolvedLayerColors() {
        layer.borderColor = TallyPalette.signal2
            .resolvedColor(with: traitCollection).cgColor
    }
}
