import SwiftUI
#if !os(visionOS)
import VisionKit
#endif

/// The thin companion to the wall's ghost tiles: how a payload gets in when
/// the app can't hear the machine (a host on another network, a VPS) and the
/// place that explains the CLI. Discovery itself is not listed here — heard
/// machines appear on the wall, which is the whole point of candidate C.
struct BindSheet: View {
    @Environment(BindController.self) private var bind
    @Environment(\.dismiss) private var dismiss

    var addHostManually: () -> Void

    @State private var showingScanner = false
    @State private var pasteFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    instructions
                    actions
                    if !bind.pending.isEmpty {
                        incoming
                    }
                    footer
                }
                .frame(maxWidth: 560)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .chassisSheetGround()
            .navigationTitle("Bind Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle("Bind Host")
                ToolbarItem(placement: .cancellationAction) {
                    ChassisBarButton("Done") { dismiss() }
                }
            }
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

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChassisLabel("On the machine", size: 11, color: Theme.signal2)
            Text("Install the companion CLI, then run it. The machine appears on the deck by itself if it’s on this network — otherwise scan or paste what it prints.")
                .font(.footnote)
                .foregroundStyle(Theme.signal2)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.installLines, id: \.self) { line in
                    Text(line)
                        .font(.mono(11))
                        .foregroundStyle(Theme.miniText)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.screen)
            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        }
    }

    private static let installLines = [
        "# macOS",
        "brew install multiplex-term/tap/mpx",
        "# Linux",
        "curl -fsSL https://multiplexterm.dev/install | sh",
        "",
        "mpx bind",
    ]

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChassisLabel("On this device", size: 11, color: Theme.signal2)
            #if !os(visionOS)
            // visionOS App Store apps have no camera access, so the scan
            // affordance genuinely does not exist there.
            if DataScannerViewController.isSupported {
                ChassisChip("SCAN QR", systemImage: "qrcode.viewfinder") {
                    showingScanner = true
                }
            }
            #endif
            // A system paste control, not a chip that reads the pasteboard:
            // reading it in code raises iOS's "Allow Paste?" alert every
            // time, and the clipboard here may hold a key. The system
            // styling is the cost of not prompting.
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in accept(text) }
            }
            .buttonBorderShape(.roundedRectangle(radius: 4))
            .tint(Theme.bezelHi)
            ChassisChip("ADD HOST MANUALLY", systemImage: "plus") {
                dismiss()
                addHostManually()
            }
            if pasteFailed {
                Text("The clipboard doesn’t hold a bind code. Copy the multiplex://bind line the CLI printed.")
                    .font(.mono(10))
                    .foregroundStyle(Theme.caution)
            }
        }
    }

    private var incoming: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChassisLabel("Incoming", size: 11, color: Theme.caution)
            ForEach(bind.pending) { candidate in
                HStack(spacing: 10) {
                    ChassisLabel(candidate.name, size: 11)
                    Text(candidate.addressSummary)
                        .font(.mono(10))
                        .foregroundStyle(Theme.signal2)
                    Spacer(minLength: 4)
                    ChassisLabel(candidate.statusCaption, size: 9, color: Theme.signal3)
                }
                .padding(10)
                .background(Theme.screen)
                .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
            }
            Text("Confirm each one on the deck — its tile takes the PIN.")
                .font(.footnote)
                .foregroundStyle(Theme.signal3)
        }
    }

    private var footer: some View {
        Text("Binding never sends a private key: this device makes its own key and the machine adds the public half to authorized_keys. `mpx unbind` removes it.")
            .font(.footnote)
            .foregroundStyle(Theme.signal3)
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
