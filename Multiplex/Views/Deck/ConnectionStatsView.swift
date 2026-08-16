import Observation
import UIKit

/// The Connection Stats board (Pro): one strip per host — identity, a
/// segmented meter of recent RTT samples, and the headline numbers — with an
/// in-place drill-in that adds the instrument cluster (big numeral, echo /
/// loss / stability / volume, and the per-transport honesty line). Strips
/// stay visible while one is expanded, because the fleet question is
/// comparative: "which host is slow?"
///
/// Reads `ConnectionStatsCenter` only — no hub dependency, so the deck and a
/// terminal window can both present it. Presenters own the Pro gate and the
/// setting gate; this sheet assumes both passed.
@MainActor
final class ConnectionStatsViewController: UIViewController, AppAppearanceFollowing {
    static let preferredSheetSize = CGSize(width: 720, height: 900)

    var onDone: (() -> Void)?

    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private struct BoardSnapshot {
        var hosts: [Host]
        var collecting: Bool
        var networkChanges: Int
    }

    private let store: HostStore
    private var expandedHostID: UUID?
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let summaryLabel = UILabel()
    private let footerLabel = UILabel()
    private var stripViews: [UUID: ConnectionStatsStripView] = [:]
    private var observationGeneration = 0

    init(store: HostStore, focusedHostID: UUID? = nil) {
        self.store = store
        expandedHostID = focusedHostID
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSheetSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connection Stats"
        view.backgroundColor = GlassPrototype.sheetGround
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel("Connection Stats", size: 12)
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
        observe()
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

        summaryLabel.font = UIKitChassis.monoFont(11)
        summaryLabel.textColor = UIKitChassis.signal2
        summaryLabel.numberOfLines = 1
        summaryLabel.adjustsFontSizeToFitWidth = true
        summaryLabel.minimumScaleFactor = 0.8

        footerLabel.font = UIKitChassis.monoFont(8)
        footerLabel.textColor = UIKitChassis.signal3
        footerLabel.numberOfLines = 0
        footerLabel.text = "MOSH SAMPLES EVERY DATAGRAM · SSH HAS NO KEEPALIVE — "
            + "RTT IS THE DECK PROBE · ECHO MEASURED WHILE YOU TYPE · "
            + "SESSION-ONLY, NOTHING LEAVES THIS DEVICE"

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 8
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -18),
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
        ])
    }

    private func observe() {
        observationGeneration += 1
        let generation = observationGeneration
        let center = ConnectionStatsCenter.shared
        let snapshot = withObservationTracking {
            // `revision` is the board's coarse heartbeat — the sheet is the
            // one surface that genuinely wants every host's pushes.
            _ = center.revision
            return BoardSnapshot(
                hosts: store.hosts,
                collecting: center.isCollecting,
                networkChanges: center.networkChanges
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observe()
            }
        }
        render(snapshot)
    }

    private func render(_ snapshot: BoardSnapshot) {
        var views: [UIView] = [summaryLabel]

        guard snapshot.collecting else {
            summaryLabel.text = "COLLECTION IS OFF"
            let notice = UILabel()
            notice.font = UIKitChassis.uiFont(13)
            notice.textColor = UIKitChassis.signal2
            notice.numberOfLines = 0
            notice.text = "Connection stats are turned off in Settings."
            views.append(notice)
            replaceContent(with: views)
            return
        }

        let now = Date()
        let center = ConnectionStatsCenter.shared
        let rows = snapshot.hosts.map { host in
            (host: host, stats: center.snapshot(for: host.id))
        }

        let live = rows.filter { $0.stats?.headlineRTT(now: now) != nil }.count
        var summary = "\(live) \(live == 1 ? "LINK" : "LINKS")"
        if snapshot.networkChanges > 0 {
            summary += " · \(snapshot.networkChanges) NET "
                + (snapshot.networkChanges == 1 ? "CHANGE" : "CHANGES")
        }
        summaryLabel.text = summary
        summaryLabel.accessibilityLabel = summary.lowercased()

        if rows.isEmpty {
            let empty = UILabel()
            empty.font = UIKitChassis.uiFont(13)
            empty.textColor = UIKitChassis.signal2
            empty.text = "No hosts yet."
            views.append(empty)
        }
        for row in rows {
            let strip = stripViews[row.host.id] ?? ConnectionStatsStripView()
            stripViews[row.host.id] = strip
            strip.configure(
                host: row.host,
                stats: row.stats,
                networkChanges: snapshot.networkChanges,
                expanded: expandedHostID == row.host.id,
                now: now,
                toggle: { [weak self] in
                    guard let self else { return }
                    self.expandedHostID = self.expandedHostID == row.host.id
                        ? nil : row.host.id
                    self.observe()
                }
            )
            views.append(strip)
        }
        let liveIDs = Set(snapshot.hosts.map(\.id))
        for key in Array(stripViews.keys) where !liveIDs.contains(key) {
            stripViews.removeValue(forKey: key)
        }
        views.append(footerLabel)
        replaceContent(with: views)
    }

    /// Same reconciliation the wall uses: leave the hierarchy alone when the
    /// arrangement is identical (the common case — strips are cached per
    /// host), otherwise rebuild the order wholesale. Strip state lives in
    /// the cached views, so a re-add loses nothing.
    private func replaceContent(with views: [UIView]) {
        let alreadyArranged = contentStack.arrangedSubviews.count == views.count
            && zip(contentStack.arrangedSubviews, views).allSatisfy { $0 === $1 }
        guard !alreadyArranged else { return }
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        views.forEach(contentStack.addArrangedSubview)
    }

    @objc private func donePressed() {
        onDone?()
    }
}

// MARK: - Host strip

/// One host's board row. Collapsed: identity · meter · headline run.
/// Expanded: the instrument cluster in place, other strips untouched.
@MainActor
private final class ConnectionStatsStripView: UIKitTallyBorderedView {
    /// More than any meter width can draw; the view suffixes to fit.
    private static let meterSampleLimit = 96

    private let headerRow = UIStackView()
    private let nameLabel = UIKitChassisLabel("", size: 12)
    private let addressLabel = UILabel()
    private let transportBadge = SettingsBadgeView("MOSH")
    private let meter = ConnectionStatsMeterView()
    private let runLabel = UILabel()
    private let sourceLabel = UILabel()
    private let clusterStack = UIStackView()
    private var toggle: () -> Void = {}
    private var expanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.bezel

        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addressLabel.font = UIKitChassis.monoFont(10.5)
        addressLabel.textColor = UIKitChassis.signal3
        addressLabel.numberOfLines = 1
        addressLabel.lineBreakMode = .byTruncatingTail

        let identity = UIStackView(arrangedSubviews: [nameLabel, addressLabel])
        identity.axis = .vertical
        identity.alignment = .leading
        identity.spacing = 3
        identity.widthAnchor.constraint(equalToConstant: 168).isActive = true

        runLabel.font = UIKitChassis.monoFont(11)
        runLabel.textColor = UIKitChassis.signal
        runLabel.numberOfLines = 1
        sourceLabel.font = UIKitChassis.monoFont(8)
        sourceLabel.textColor = UIKitChassis.signal3
        sourceLabel.numberOfLines = 1
        let trailing = UIStackView(arrangedSubviews: [runLabel, sourceLabel])
        trailing.axis = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 3
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        meter.heightAnchor.constraint(equalToConstant: 26).isActive = true
        meter.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 14
        headerRow.isLayoutMarginsRelativeArrangement = true
        headerRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 10, leading: 12, bottom: 10, trailing: 12)
        headerRow.addArrangedSubview(identity)
        headerRow.addArrangedSubview(transportBadge)
        headerRow.addArrangedSubview(meter)
        headerRow.addArrangedSubview(trailing)

        clusterStack.axis = .vertical
        clusterStack.alignment = .fill
        clusterStack.spacing = 0

        let column = UIStackView(arrangedSubviews: [headerRow, clusterStack])
        column.axis = .vertical
        column.alignment = .fill
        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        headerRow.isAccessibilityElement = true
        headerRow.accessibilityTraits = .button
        let tap = UITapGestureRecognizer(target: self, action: #selector(headerTapped))
        headerRow.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(
        host: Host,
        stats: HostLinkStats?,
        networkChanges: Int,
        expanded: Bool,
        now: Date,
        toggle: @escaping () -> Void
    ) {
        self.toggle = toggle
        self.expanded = expanded
        tallyBorderColor = expanded ? UIKitChassis.signal2 : UIKitChassis.bezelHi

        nameLabel.setText(host.name)
        nameLabel.setInk(host.isEnabled ? UIKitChassis.signal : UIKitChassis.signal3)
        addressLabel.text = host.address
        transportBadge.isHidden = !host.useMosh

        let headline = stats?.headlineRTT(now: now)
        let usingMosh = headline?.source == .moshSRTT
        meter.setSamples(Self.meterSamples(stats, usingMosh: usingMosh))

        var run: [String] = []
        if let headline {
            run.append(ConnectionStatsFormat.milliseconds(headline.milliseconds))
        }
        if let mosh = stats?.latestMosh, usingMosh {
            run.append(ConnectionStatsFormat.lossPercent(mosh.lossFraction))
            if mosh.roamCount > 0 { run.append("\(mosh.roamCount) RM") }
        } else if let relinks = stats?.relinks, relinks > 0 {
            run.append("\(relinks) RELINK\(relinks == 1 ? "" : "S")")
        }
        if run.isEmpty {
            let unreachable = stats?.lastFailure?.isEmpty == false
            run.append(unreachable ? "NO ROUTE" : "—")
        }
        runLabel.text = run.joined(separator: " · ")

        if headline != nil {
            sourceLabel.text = usingMosh ? "SRC · MOSH SRTT · LIVE" : "SRC · DECK PROBE"
        } else if let probed = stats?.lastProbeAt {
            sourceLabel.text = "LAST SEEN "
                + ConnectionStatsFormat.age(now.timeIntervalSince(probed)) + " AGO"
        } else {
            // Never measured — a source line would be a claim with nothing
            // behind it.
            sourceLabel.text = ""
        }

        headerRow.accessibilityLabel = "\(host.name), "
            + (runLabel.text ?? "").lowercased()
            + (expanded ? ", expanded" : "")
        headerRow.accessibilityHint = expanded
            ? "Collapses connection details" : "Expands connection details"

        rebuildCluster(
            stats: stats,
            headline: headline,
            networkChanges: networkChanges,
            now: now
        )
    }

    /// The one derivation both meters share — the collapsed strip and the
    /// expanded tall meter must never disagree about which series a host is
    /// showing. Stale mosh samples still beat an empty probe ring.
    private static func meterSamples(
        _ stats: HostLinkStats?, usingMosh: Bool
    ) -> [Double] {
        guard let stats else { return [] }
        let primary = usingMosh ? stats.moshRTT : stats.probeRTT
        let samples = primary.recentValues(limit: meterSampleLimit)
        guard samples.isEmpty, !usingMosh else { return samples }
        return stats.moshRTT.recentValues(limit: meterSampleLimit)
    }

    private func rebuildCluster(
        stats: HostLinkStats?,
        headline: (milliseconds: Double, source: HostLinkStats.RTTSource)?,
        networkChanges: Int,
        now: Date
    ) {
        clusterStack.arrangedSubviews.forEach {
            clusterStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard expanded else { return }

        let usingMosh = headline?.source == .moshSRTT
        let mosh = usingMosh ? stats?.latestMosh : nil
        let uptime = stats?.liveSince.map {
            "UP " + ConnectionStatsFormat.age(now.timeIntervalSince($0))
        }

        // SIGNAL — big numeral, the tall meter, and the felt-experience column.
        let value = UILabel()
        value.font = UIKitChassis.monoFont(34)
        value.textColor = UIKitChassis.signal
        value.text = headline.map { String(Int($0.milliseconds.rounded())) } ?? "—"
        let valueCaption = label(size: 8, ink: UIKitChassis.signal3)
        if let mosh {
            valueCaption.text = "MS · SRTT ±"
                + String(Int(mosh.rttVarianceMilliseconds.rounded()))
        } else {
            valueCaption.text = headline == nil ? "NO SIGNAL" : "MS · PROBE"
        }
        let numeral = UIStackView(arrangedSubviews: [value, valueCaption])
        numeral.axis = .vertical
        numeral.alignment = .leading
        numeral.spacing = 2

        let tallMeter = ConnectionStatsMeterView()
        tallMeter.heightAnchor.constraint(equalToConstant: 44).isActive = true
        tallMeter.setSamples(Self.meterSamples(stats, usingMosh: usingMosh))

        var miniLines: [String] = []
        if let echo = stats?.latestEcho {
            miniLines.append("ECHO \(ConnectionStatsFormat.milliseconds(echo.value))")
        } else {
            miniLines.append("ECHO — TYPE TO SAMPLE")
        }
        if let mosh {
            miniLines.append("LOSS \(ConnectionStatsFormat.lossPercent(mosh.lossFraction))")
            miniLines.append("QUEUE \(mosh.unackedEvents) UNACKED")
        } else {
            if let probed = stats?.lastProbeAt {
                miniLines.append("SEEN "
                    + ConnectionStatsFormat.age(now.timeIntervalSince(probed)) + " AGO")
            }
            if let uptime { miniLines.append(uptime) }
        }
        let minis = UIStackView(
            arrangedSubviews: miniLines.map { label($0, size: 10) })
        minis.axis = .vertical
        minis.alignment = .trailing
        minis.spacing = 5
        minis.setContentCompressionResistancePriority(.required, for: .horizontal)

        let signalRow = UIStackView(
            arrangedSubviews: [slabCaption("SIGNAL"), numeral, tallMeter, minis])
        signalRow.axis = .horizontal
        signalRow.alignment = .center
        signalRow.spacing = 14
        clusterStack.addArrangedSubview(hairline())
        clusterStack.addArrangedSubview(padded(signalRow))

        // STABILITY — relinks, roams, network changes, the last drop reason.
        var stability: [String] = []
        stability.append("RELINKS \(stats?.relinks ?? 0)")
        if let report = stats?.latestMosh {
            stability.append("ROAMS \(report.roamCount)")
        }
        stability.append("NET \(networkChanges)")
        if mosh != nil, let uptime { stability.append(uptime) }
        var stabilityLines = [label(stability.joined(separator: " · "), size: 10.5, fitting: true)]
        if let drop = stats?.lastDropReason {
            stabilityLines.append(
                label("LAST DROP — " + drop.uppercased(), size: 9, ink: UIKitChassis.signal3, lines: 2))
        } else if let failure = stats?.lastFailure {
            stabilityLines.append(
                label("FAILED — " + failure.uppercased(), size: 9, ink: UIKitChassis.signal3, lines: 2))
        }
        clusterStack.addArrangedSubview(hairline())
        clusterStack.addArrangedSubview(slabRow("STABILITY", stabilityLines))

        // VOLUME — session bytes, probe payload, and the connect split.
        var volume: [String] = []
        volume.append("IN " + ConnectionStatsFormat.bytes(stats?.bytesIn ?? 0))
        volume.append("OUT " + ConnectionStatsFormat.bytes(stats?.bytesOut ?? 0))
        if let payload = stats?.probePayloadBytes {
            volume.append("PROBE " + ConnectionStatsFormat.bytes(payload) + "/CYCLE")
        }
        var volumeLines = [label(volume.joined(separator: " · "), size: 10.5, fitting: true)]
        if let keys = stats?.connectSecretsMilliseconds,
           let ssh = stats?.connectSSHMilliseconds {
            var split = "KEYS \(ConnectionStatsFormat.milliseconds(keys))"
                + " · SSH \(ConnectionStatsFormat.milliseconds(ssh))"
            if let at = stats?.lastConnectAt {
                split += " · " + ConnectionStatsFormat.age(
                    now.timeIntervalSince(at)) + " AGO"
            }
            volumeLines.append(
                label(split, size: 9, ink: UIKitChassis.signal3, lines: 2))
        }
        clusterStack.addArrangedSubview(hairline())
        clusterStack.addArrangedSubview(slabRow("VOLUME", volumeLines))

        // The honesty line: what this host's numbers actually are.
        let honesty = label(size: 8, ink: UIKitChassis.signal3, lines: 0)
        honesty.text = mosh != nil
            ? "MOSH LINK — SRTT FROM EVERY DATAGRAM · LOSS FROM SEQUENCE GAPS"
            : "SSH LINK — NO KEEPALIVE · RTT SAMPLED BY THE DECK PROBE · "
                + "ECHO MEASURED WHILE YOU TYPE"
        clusterStack.addArrangedSubview(hairline())
        clusterStack.addArrangedSubview(padded(honesty))
    }

    // MARK: Cluster furniture

    /// One caption-plus-lines slab row — STABILITY and VOLUME are the same
    /// shape with different strings.
    private func slabRow(_ caption: String, _ lines: [UILabel]) -> UIView {
        let stack = UIStackView(arrangedSubviews: lines)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        let row = UIStackView(arrangedSubviews: [slabCaption(caption), stack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 14
        return padded(row)
    }

    private func slabCaption(_ text: String) -> UILabel {
        let caption = UILabel()
        caption.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.2,
                .foregroundColor: UIKitChassis.signal3,
            ]
        )
        caption.widthAnchor.constraint(equalToConstant: 76).isActive = true
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        return caption
    }

    /// The cluster's one label factory — every stat line is mono ink with a
    /// size, differing only in ink, wrap, and shrink-to-fit.
    private func label(
        _ text: String? = nil,
        size: CGFloat,
        ink: UIColor? = nil,
        lines: Int = 1,
        fitting: Bool = false
    ) -> UILabel {
        let view = UILabel()
        view.font = UIKitChassis.monoFont(size)
        view.textColor = ink ?? UIKitChassis.signal2
        view.numberOfLines = lines
        if fitting {
            view.adjustsFontSizeToFitWidth = true
            view.minimumScaleFactor = 0.8
        }
        view.text = text
        return view
    }

    private func padded(_ view: UIView) -> UIView {
        let container = UIView()
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = UIKitChassis.bezelHi
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    @objc private func headerTapped() {
        toggle()
    }
}

// MARK: - Sample meter

/// Segmented sample columns — the tile spine's vocabulary applied to a time
/// series. Newest sample at the right edge in primary ink; a sample past the
/// caution threshold wears caution (a state, captioned by the strip's run);
/// no samples at all shows the wall's NO SIGNAL hatch.
@MainActor
private final class ConnectionStatsMeterView: UIView {
    /// A sample above this is marked caution — a genuinely slow round-trip
    /// on any transport, not a relative judgement.
    private static let cautionThresholdMS: Double = 250
    private static let barWidth: CGFloat = 4
    private static let barGap: CGFloat = 2

    private var samples: [Double] = []
    /// The dead-meter well: the shared NO SIGNAL hatch in a bordered frame.
    private let emptyWell = UIKitTallyBorderedView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false

        let hatch = UIKitTallyHatchView()
        emptyWell.addSubview(hatch)
        hatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hatch.leadingAnchor.constraint(equalTo: emptyWell.leadingAnchor, constant: 1),
            hatch.trailingAnchor.constraint(equalTo: emptyWell.trailingAnchor, constant: -1),
            hatch.topAnchor.constraint(equalTo: emptyWell.topAnchor, constant: 1),
            hatch.bottomAnchor.constraint(equalTo: emptyWell.bottomAnchor, constant: -1),
        ])
        addSubview(emptyWell)
        emptyWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyWell.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyWell.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyWell.topAnchor.constraint(equalTo: topAnchor),
            emptyWell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setSamples(_ samples: [Double]) {
        self.samples = samples
        emptyWell.isHidden = !samples.isEmpty
        setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !samples.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let slot = Self.barWidth + Self.barGap
        let capacity = max(1, Int(bounds.width / slot))
        let visible = samples.suffix(capacity)
        let scale = max(visible.max() ?? 1, 60) * 1.05

        let base = UIKitChassis.signal3.resolvedColor(with: traitCollection)
        let newest = UIKitChassis.signal.resolvedColor(with: traitCollection)
        let caution = TallyPalette.caution.resolvedColor(with: traitCollection)

        var x = bounds.width - CGFloat(visible.count) * slot + Self.barGap
        for (index, sample) in visible.enumerated() {
            let height = max(2, CGFloat(sample / scale) * bounds.height)
            let color: UIColor
            if sample > Self.cautionThresholdMS {
                color = caution
            } else if index == visible.count - 1 {
                color = newest
            } else {
                color = base
            }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(
                x: x,
                y: bounds.height - height,
                width: Self.barWidth,
                height: height
            ))
            x += slot
        }
    }
}
