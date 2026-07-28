import SwiftUI
import UIKit
#if !os(visionOS)
import VisionKit
#endif

/// The whole bind flow, on one surface: the commands to run on the machine,
/// the machines heard answering, and the PIN that finishes it. It lives as a
/// segment of Add Host rather than a sheet of its own plus tiles on the wall
/// — binding *is* adding a host, and splitting one flow across two surfaces
/// meant the deck asked for a PIN while a modal explained what a PIN was.
///
/// Discovery is scoped to this pane being on screen (`BindController
/// .bindSurfaceOpen`): with no ghost tiles on the wall there is nothing for a
/// background browse to feed, and a device that never opens this pane never
/// raises the local-network prompt.
struct BindPane: View {
    @Environment(BindController.self) private var bind

    @State private var showingScanner = false
    @State private var pasteFailed = false

    var body: some View {
        VStack(spacing: 18) {
            machineSection
            incomingSection
            elsewhereSection
            footer
        }
        .task {
            bind.bindSurfaceOpen = true
        }
        // A machine killed outright never withdrew its announcement, so no
        // browse change will ever retire that row — only its age can. Slow
        // on purpose: this is arithmetic, not a network call.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                bind.syncDiscovered()
            }
        }
        .onDisappear {
            // Enrollment outlives this pane (the controller owns the task and
            // saves the host either way), so the browser it needs for an
            // endpoint is kept alive by `pending`, not by this flag.
            bind.bindSurfaceOpen = false
        }
        #if !os(visionOS)
        .sheet(isPresented: $showingScanner) {
            BindScannerSheet { payload in
                showingScanner = false
                bind.submit(payloadText: payload)
            }
        }
        #endif
    }

    // MARK: On the machine

    private var machineSection: some View {
        TallyFormSection(
            "On the machine",
            detail: "Copy a line, run it in a terminal on the machine you "
                + "want to add, then leave mpx bind running. Nothing here "
                + "runs on this device."
        ) {
            TallyFormRow {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(HostGuide.mpxInstall) { entry in
                        CopyableCommandField(
                            label: entry.label,
                            command: entry.command
                        )
                    }
                    CopyableCommandField(
                        label: HostGuide.mpxBind.label,
                        command: HostGuide.mpxBind.command
                    )
                }
            }
        }
    }

    // MARK: Machines answering

    private var incomingSection: some View {
        TallyFormSection("Asking to bind", detail: incomingDetail) {
            if bind.pending.isEmpty {
                TallyFormRow {
                    HStack(spacing: 10) {
                        TallyLamp(caption: "LISTENING", color: Theme.caution)
                        Text("No machine has answered yet.")
                            .font(.ui(11))
                            .foregroundStyle(Theme.signal2)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ForEach(bind.pending) { candidate in
                    BindCandidateRow(
                        pending: candidate,
                        setPIN: { bind.setPIN($0, for: candidate.id) },
                        confirm: { bind.confirm(id: candidate.id) },
                        dismiss: { bind.dismiss(id: candidate.id) }
                    )
                }
            }
        }
    }

    private var incomingDetail: String {
        guard !bind.pending.isEmpty else {
            return "Machines running mpx bind on this network appear here on "
                + "their own. Confirm each one with the 6-digit PIN its "
                + "terminal printed."
        }
        let discovered = bind.pending.contains {
            if case .discovered = $0.source { return true }
            return false
        }
        return discovered
            ? "Heard on your network. Check the address and fingerprint "
                + "against the terminal, then type its PIN."
            : "From a scanned or pasted bind code."
    }

    // MARK: Machines this network can't hear

    private var elsewhereSection: some View {
        TallyFormSection(
            "Somewhere else",
            detail: "A machine on another network — a VPS, a box behind a "
                + "firewall — can't announce itself here. Scan or paste the "
                + "code its terminal printed instead."
        ) {
            TallyFormRow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        #if !os(visionOS)
                        // visionOS App Store apps have no camera access, so
                        // the scan affordance genuinely does not exist there.
                        if DataScannerViewController.isSupported {
                            ChassisChip("SCAN QR", systemImage: "qrcode.viewfinder") {
                                showingScanner = true
                            }
                        }
                        #endif
                        // A system paste control, not a chip that reads the
                        // pasteboard: reading it in code raises iOS's "Allow
                        // Paste?" alert every time, and the clipboard here may
                        // hold a key. The system styling is the cost of not
                        // prompting.
                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first else { return }
                            Task { @MainActor in accept(text) }
                        }
                        .buttonBorderShape(.roundedRectangle(radius: 4))
                        .tint(Theme.bezelHi)
                        Spacer(minLength: 0)
                    }
                    if pasteFailed {
                        Text("The clipboard doesn’t hold a bind code. Copy the multiplex:// line the CLI printed.")
                            .font(.ui(10))
                            .foregroundStyle(Theme.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("Binding never sends a private key: this device makes its own key and the machine adds the public half to authorized_keys. `mpx unbind` removes it.")
            .font(.ui(10))
            .foregroundStyle(Theme.signal3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    private func accept(_ text: String) {
        guard BindPayload(string: text) != nil else {
            pasteFailed = true
            return
        }
        pasteFailed = false
        bind.submit(payloadText: text)
    }
}

/// One machine offering to bind, as a form row. It shows the machine's own
/// words — user@name, address, SSH fingerprint — so an unexpected entry can
/// be checked against the terminal that printed them before anything is
/// enrolled, and it takes the PIN in place.
struct BindCandidateRow: View {
    var pending: BindController.Pending
    var setPIN: (String) -> Void
    var confirm: () -> Void
    var dismiss: () -> Void

    @FocusState private var pinFocused: Bool

    var body: some View {
        TallyFormRow {
            VStack(alignment: .leading, spacing: 10) {
                header
                identity
                if case .failed(let message) = pending.stage {
                    Text(message)
                        .font(.ui(10))
                        .foregroundStyle(Theme.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionRow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pending.name) is asking to bind")
    }

    private var header: some View {
        HStack(spacing: 10) {
            ChassisLabel(pending.name, size: 12)
            Spacer(minLength: 4)
            switch pending.stage {
            case .bound:
                TallyLamp(caption: "BOUND", color: Theme.ok)
            case .failed:
                TallyLamp(caption: "FAILED", color: Theme.caution)
            default:
                if pending.isBusy {
                    TallyLamp(caption: pending.statusCaption, color: Theme.caution)
                } else {
                    ChassisLabel(pending.statusCaption, size: 9, color: Theme.signal3)
                }
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(pending.user.isEmpty ? "?" : pending.user) @ \(pending.name)")
                .font(.mono(10))
                .foregroundStyle(Theme.signal)
            Text(pending.addressSummary)
                .font(.mono(10))
                .foregroundStyle(Theme.signal2)
            if let fingerprint = pending.fingerprint {
                Text(fingerprint)
                    .font(.mono(9))
                    .foregroundStyle(Theme.signal3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Theme.screen)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
    }

    @ViewBuilder
    private var actionRow: some View {
        switch pending.stage {
        case .bound:
            Text("Added to the fleet — it's on the deck now.")
                .font(.ui(10))
                .foregroundStyle(Theme.signal2)
        case .binding, .enrolling, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.mini)
                Text(busyCaption)
                    .font(.ui(10))
                    .foregroundStyle(Theme.signal2)
                Spacer(minLength: 0)
            }
        default:
            HStack(spacing: 8) {
                if pending.needsPIN {
                    pinField
                }
                Spacer(minLength: 4)
                ChassisChip("DISMISS", action: dismiss)
                    .accessibilityLabel("Dismiss \(pending.name)")
                ChassisChip(retryLabel, prominent: pending.canSubmit, action: confirm)
                    .disabled(!pending.canSubmit)
                    .opacity(pending.canSubmit ? 1 : 0.45)
                    .accessibilityLabel("\(retryLabel) \(pending.name)")
            }
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

    /// Six digits in mono wells. The real field is invisible and sits on top:
    /// the wells are the rendering, that field is the input.
    private var pinField: some View {
        HStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { index in
                let digits = Array(pending.pin)
                Text(index < digits.count ? String(digits[index]) : "·")
                    .font(.mono(13))
                    .foregroundStyle(index < digits.count ? Theme.signal : Theme.signal3)
                    .frame(width: 17, height: 24)
                    .background(Theme.screen)
                    .overlay(Rectangle().strokeBorder(
                        pinFocused ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
            }
        }
        .overlay {
            TextField("", text: Binding(get: { pending.pin }, set: setPIN))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($pinFocused)
                .font(.mono(13))
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("PIN from \(pending.name)’s terminal")
        }
        .onTapGesture { pinFocused = true }
    }
}

#if !os(visionOS)
/// The QR scanner, live only where a camera exists (iPhone/iPad — visionOS
/// App Store apps cannot reach the cameras at all).
private struct BindScannerSheet: View {
    var found: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BindScannerView(found: found)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan Bind Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ChassisBarButton("Cancel") { dismiss() }
                    }
                }
        }
    }
}

private struct BindScannerView: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported,
              DataScannerViewController.isAvailable
        else { return unavailableController() }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    private func unavailableController() -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(Theme.chassis)
        let label = UILabel()
        label.text = "This device can’t scan. Paste the bind code instead."
        label.textColor = UIColor(Theme.signal2)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            label.widthAnchor.constraint(
                equalTo: controller.view.widthAnchor, multiplier: 0.7),
        ])
        return controller
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (String) -> Void
        /// One payload per presentation: the scanner keeps recognizing the
        /// same code every frame while the sheet dismisses.
        private var delivered = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            deliver(from: addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            deliver(from: [item])
        }

        private func deliver(from items: [RecognizedItem]) {
            guard !delivered else { return }
            for item in items {
                guard case .barcode(let barcode) = item,
                      let text = barcode.payloadStringValue,
                      BindPayload(string: text) != nil
                else { continue }
                delivered = true
                found(text)
                return
            }
        }
    }
}
#endif
