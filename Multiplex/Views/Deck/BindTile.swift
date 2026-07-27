import SwiftUI

/// A machine materializing on the wall. Dashed bezel, not the `NO SIGNAL`
/// hatch — hatching is failure vocabulary, while a dash reads provisional:
/// this monitor is not real yet. The screen shows the machine's own words
/// (what `mpx bind` printed about itself), and the PIN goes in on the tile,
/// so binding never leaves the wall.
struct BindTile: View {
    var pending: BindController.Pending
    var compact: Bool
    var setPIN: (String) -> Void
    var confirm: () -> Void
    var dismiss: () -> Void

    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            screen
            umdRow
            actionRow
        }
        .padding(5)
        .background(Theme.bezel)
        .overlay(
            Rectangle().strokeBorder(
                borderColor,
                style: StrokeStyle(lineWidth: 1, dash: isSolid ? [] : [5, 4])
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pending.name) is asking to bind")
    }

    private var isSolid: Bool {
        if case .bound = pending.stage { return true }
        return false
    }

    private var borderColor: Color {
        switch pending.stage {
        case .failed: Theme.caution
        case .bound: Theme.bezelHi
        default: Theme.signal3
        }
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("mpx bind")
                .font(.mono(compact ? 8.5 : 10))
                .foregroundStyle(Theme.miniText)
            Text(verbatim: "\(pending.user.isEmpty ? "?" : pending.user) @ \(pending.name)")
                .font(.mono(compact ? 8.5 : 10))
                .foregroundStyle(Theme.miniText)
            Text(pending.addressSummary)
                .font(.mono(compact ? 8 : 9))
                .foregroundStyle(Theme.signal3)
            if let fingerprint = pending.fingerprint {
                Text(fingerprint)
                    .font(.mono(compact ? 7.5 : 8.5))
                    .foregroundStyle(Theme.signal3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if case .failed(let message) = pending.stage {
                Text(message)
                    .font(.mono(compact ? 7.5 : 8.5))
                    .foregroundStyle(Theme.caution)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: compact ? 64 : 96, alignment: .top)
        .background(Theme.screen.opacity(0.65))
        .overlay(
            Rectangle().strokeBorder(
                Theme.bezelHi, style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        )
    }

    private var umdRow: some View {
        HStack(spacing: 8) {
            ChassisLabel(pending.name, size: compact ? 10 : 12)
            Spacer(minLength: 4)
            switch pending.stage {
            case .bound:
                TallyLamp(caption: "BOUND")
            case .failed:
                TallyLamp(caption: "FAILED", color: Theme.caution)
            default:
                if pending.isBusy {
                    TallyLamp(caption: pending.statusCaption, color: Theme.caution)
                } else {
                    ChassisLabel(pending.statusCaption, size: compact ? 9 : 10, color: Theme.signal3)
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 7)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var actionRow: some View {
        switch pending.stage {
        case .bound:
            EmptyView()
        case .binding, .enrolling, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(busyCaption)
                    .font(.mono(compact ? 8.5 : 9.5))
                    .foregroundStyle(Theme.signal2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 3)
        default:
            HStack(spacing: 8) {
                if pending.needsPIN {
                    pinField
                }
                Spacer(minLength: 0)
                ChassisChip("DISMISS", action: dismiss)
                    .accessibilityLabel("Dismiss \(pending.name)")
                ChassisChip(retryLabel, prominent: pending.canSubmit, action: confirm)
                    .disabled(!pending.canSubmit)
                    .accessibilityLabel("\(retryLabel) \(pending.name)")
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 3)
        }
    }

    private var retryLabel: String {
        if case .failed = pending.stage { return "RETRY" }
        return "ENROLL"
    }

    private var busyCaption: String {
        switch pending.stage {
        case .binding: "Proving the PIN…"
        case .enrolling: "Enrolling this device’s key…"
        case .checking: "Checking the connection…"
        default: ""
        }
    }

    /// Six digits, typed into one mono field styled as the tile's own boxes.
    /// A tile is deck chrome, not a terminal, so ordinary focus applies.
    private var pinField: some View {
        HStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { index in
                let digits = Array(pending.pin)
                Text(index < digits.count ? String(digits[index]) : "·")
                    .font(.mono(compact ? 11 : 13))
                    .foregroundStyle(index < digits.count ? Theme.signal : Theme.signal3)
                    .frame(width: compact ? 15 : 17, height: compact ? 19 : 22)
                    .background(Theme.screen)
                    .overlay(Rectangle().strokeBorder(
                        pinFocused ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
            }
        }
        .overlay {
            // The real field is invisible and sits on top: the boxes are the
            // rendering, this is the input.
            TextField("", text: Binding(get: { pending.pin }, set: setPIN))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($pinFocused)
                .font(.mono(compact ? 11 : 13))
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("PIN from \(pending.name)’s terminal")
        }
        .onTapGesture { pinFocused = true }
    }
}
