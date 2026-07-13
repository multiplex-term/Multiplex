import SwiftUI

/// Placeholder paywall — the Pro seam ships before the purchase does.
/// StoreKit 2 lands inside `EntitlementStore` later; this sheet only says
/// what Pro is. Presented from locked feature controls and Settings.
struct ProPaywallView: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                ChassisLabel("Multiplex Pro", size: 16)

                feature(
                    "MOSH TRANSPORT",
                    "Keep terminal connections alive through headset sleep, "
                    + "network roaming and IP changes. SSH remains the secure "
                    + "bootstrap and fleet control plane."
                )

                feature(
                    "AGENT HELPERS",
                    "Quick commands the moment Claude Code or Codex runs in "
                    + "the attached session — interrupt, /clear, /compact, "
                    + "mode cycling and more, injected exactly as if typed."
                )

                feature(
                    "AGENT ALERTS",
                    "A banner when an agent finishes a turn, asks a question, "
                    + "or wants permission — in any session you're not "
                    + "watching, so you can step away and get pulled back."
                )

                Spacer()

                HStack {
                    ChassisBadge(
                        entitlements.isPro ? "UNLOCKED" : "PURCHASE",
                        prominent: true
                    )
                    Text(entitlements.isPro
                         ? "Pro is unlocked on this device."
                         : "Purchases aren't available in this build yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func feature(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ChassisLabel(title, size: 11)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
