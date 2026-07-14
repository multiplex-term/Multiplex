import SwiftUI
import StoreKit

/// The StoreKit-backed Multiplex Pro purchase surface. Commerce stays inside
/// `EntitlementStore`; this view only expresses purchase/restore intent and
/// renders its observable state.
struct ProPaywallView: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero

                    VStack(alignment: .leading, spacing: 18) {
                        feature(
                            "UNLIMITED HOSTS",
                            "Keep your work box, homelab and servers on one live fleet wall."
                        )
                        feature(
                            "MOSH TRANSPORT",
                            "Keep terminals alive through headset sleep, network roaming and IP changes."
                        )
                        feature(
                            "AGENT HELPERS + ALERTS",
                            "Use Claude Code and Codex quick commands without the daily limit, and get a banner when an unwatched session needs you."
                        )
                        feature(
                            "CUSTOM THEMES",
                            "Build and edit terminal palettes while the Tally chassis stays consistent."
                        )
                    }

                    purchaseControls
                }
                .padding(26)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle("Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await entitlements.loadStorefront() }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChassisLabel("Multiplex Pro", size: 18)
            Text("Buy once. Use it on iPad and Vision Pro.")
                .font(.title3.weight(.semibold))
            Text("The free tier stays useful: one host, spatial SSH terminals, live agent detection, built-in themes and \(EntitlementStore.dailySlashChipLimit) built-in or custom agent-command taps each day.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var purchaseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entitlements.isPro {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Multiplex Pro is unlocked")
                            .font(.headline)
                        Text("This purchase is available on your devices with the same Apple ID.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    Task {
                        _ = await entitlements.purchasePro(using: purchase)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if entitlements.commerceState == .purchasing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(purchaseLabel)
                            .font(.body.weight(.semibold))
                        Spacer(minLength: 12)
                        Text("ONE-TIME")
                            .font(.mono(9, weight: .semibold))
                            .kerning(1)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.bezel)
                    .overlay(Rectangle().strokeBorder(Theme.signal2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .disabled(entitlements.purchaseIsUnavailable)
                .accessibilityHint("Purchases the non-consumable Multiplex Pro unlock")
            }

            if let commerceMessage {
                Text(commerceMessage)
                    .font(.footnote)
                    .foregroundStyle(commerceMessageIsFailure ? Theme.caution : Theme.signal2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(
                entitlements.commerceState == .restoring
                    ? "Restoring Purchases…"
                    : "Restore Purchases"
            ) {
                Task { _ = await entitlements.restorePurchases() }
            }
            .disabled(entitlements.restoreIsUnavailable)

            Text("Payment is charged to your Apple ID. No subscription.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private var purchaseLabel: String {
        if let price = entitlements.productDisplayPrice {
            return "Unlock Multiplex Pro · \(price)"
        }
        return "Unlock Multiplex Pro"
    }

    private var commerceMessage: String? {
        switch entitlements.commerceState {
        case .idle:
            if entitlements.isPro {
                nil
            } else if entitlements.productIsLoading {
                "Loading the App Store price…"
            } else {
                entitlements.productLoadError
            }
        case .purchasing:
            "Waiting for the App Store…"
        case .pending:
            "Purchase pending approval. Pro unlocks automatically if approved. If it was declined, tap Restore Purchases to check again."
        case .purchased:
            "Purchase complete."
        case .restoring:
            "Checking your App Store purchases…"
        case .restored:
            entitlements.isPro
                ? "Multiplex Pro was restored."
                : "No Multiplex Pro purchase was found for this Apple ID."
        case .failed(let message):
            message
        }
    }

    private var commerceMessageIsFailure: Bool {
        if case .failed = entitlements.commerceState { return true }
        return false
    }

    private func feature(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.signal2)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 5) {
                ChassisLabel(title, size: 11)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
