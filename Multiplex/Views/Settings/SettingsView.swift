import SwiftUI

/// App-wide settings, opened from the deck: terminal appearance, agent alerts,
/// and the Multiplex Pro entitlement. Host-specific options live with the host.
struct SettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(AttentionCenter.self) private var attention
    @Environment(\.dismiss) private var dismiss
    /// The resolved chassis appearance — theme rows select into this
    /// appearance's slot, so the sheet always edits what's on screen.
    @Environment(\.colorScheme) private var colorScheme

    /// Non-nil while the editor is pushed; a theme unknown to the store is
    /// a new one and is added (and selected) on save.
    @State private var editingTheme: TerminalTheme?
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    appearanceSection
                    currentThemeSection
                    builtInThemesSection
                    customThemesSection
                    alertsSection
                    proSection
                }
                .frame(maxWidth: 680)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .background(sheetGround.ignoresSafeArea())
            .sheet(isPresented: $showingPaywall) { ProPaywallView() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $editingTheme) { theme in
                ThemeEditorView(theme: theme, onSave: save)
            }
            #if DEBUG
            .task { presentThemeEditorForVerificationIfRequested() }
            #endif
            #if !os(visionOS)
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
    }

    @ViewBuilder
    private var sheetGround: some View {
        #if os(visionOS)
        Color.clear
        #else
        Theme.chassis
        #endif
    }

    /// SYSTEM follows the device; LIGHT/DARK pin the chassis. The choice is
    /// free and device-local, like the terminal theme selection.
    private var appearanceSection: some View {
        TallyFormSection(
            "Appearance",
            detail: "System follows the device. The deck, terminal chrome, and forms switch together; each appearance keeps its own terminal theme below."
        ) {
            TallyFormRow {
                TallyChoiceBar(
                    [
                        ("SYSTEM", AppAppearance.system),
                        ("LIGHT", AppAppearance.light),
                        ("DARK", AppAppearance.dark),
                    ],
                    selection: Binding(
                        get: { themes.appearance },
                        set: { themes.appearance = $0 }
                    )
                )
            }
        }
    }

    private var currentThemeSection: some View {
        TallyFormSection(
            "Current theme",
            detail: "Selections apply to every terminal immediately and belong to the \(colorScheme == .light ? "light" : "dark") appearance now on screen."
        ) {
            TallyFormRow {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            ChassisLabel(themes.selected(for: colorScheme).name, size: 12)
                            Text("TERMINAL SURFACE")
                                .font(.mono(8, weight: .medium))
                                .kerning(1)
                                .foregroundStyle(Theme.signal3)
                        }
                        Spacer()
                        ChassisBadge("ACTIVE", prominent: true)
                    }

                    ThemePreview(theme: themes.selected(for: colorScheme))
                }
            }
        }
    }

    private var builtInThemesSection: some View {
        TallyFormSection(
            "Built-in themes",
            detail: "Choose a terminal palette. Press and hold a theme to duplicate it as a custom starting point."
        ) {
            ForEach(TerminalTheme.builtIns) { theme in
                ThemeRow(theme: theme, isSelected: themes.selectedID(for: colorScheme) == theme.id) {
                    themes.select(theme, for: colorScheme)
                }
                .contextMenu {
                    Button("Duplicate") { duplicate(theme) }
                }
            }
        }
    }

    private var customThemesSection: some View {
        TallyFormSection("Your themes", detail: customThemesDetail) {
            if themes.customThemes.isEmpty {
                TallyFormRow {
                    VStack(alignment: .leading, spacing: 4) {
                        ChassisLabel("No custom themes", size: 10, color: Theme.signal3)
                        Text("Start from the active palette, then tune its surface and ANSI colors.")
                            .font(.ui(10))
                            .foregroundStyle(Theme.signal2)
                    }
                }
            } else {
                ForEach(themes.customThemes) { theme in
                    ThemeRow(
                        theme: theme,
                        isSelected: themes.selectedID(for: colorScheme) == theme.id,
                        select: { themes.select(theme, for: colorScheme) },
                        edit: { requestThemeEditor(theme) },
                        duplicate: { duplicate(theme) },
                        delete: { themes.remove(theme) }
                    )
                }
            }

            TallyFormRow {
                HStack(spacing: 12) {
                    ChassisChip("NEW THEME", systemImage: "plus") {
                        requestThemeEditor(themes.selected(for: colorScheme).asCustom(named: "New Theme"))
                    }
                    Spacer()
                    if !entitlements.canMutateCustomThemes {
                        ChassisBadge("PRO", prominent: true)
                    }
                }
            }
        }
    }

    private var customThemesDetail: String {
        if !entitlements.canMutateCustomThemes {
            return "Creating, duplicating, and editing custom themes requires Multiplex Pro. Existing themes remain selectable and deletable."
        }
        return "New themes begin with the active palette. Use the row menu to edit, duplicate, or delete one."
    }

    private var alertsSection: some View {
        TallyFormSection(
            "Agent alerts",
            detail: "Posts a banner when Claude Code or Codex finishes a turn, asks a question, or wants permission in a session you are not typing in. Multiplex must remain open. Requires Pro."
        ) {
            TallyFormBoolField(
                "Agent alerts",
                isOn: agentAlertsBinding,
                status: entitlements.canScheduleAgentAlerts ? nil : "PRO",
                statusIsProminent: true,
                accessibilityHint: entitlements.canScheduleAgentAlerts
                    ? nil
                    : "Requires Multiplex Pro"
            )

            if !entitlements.canScheduleAgentAlerts {
                TallyFormRow {
                    ChassisChip("VIEW MULTIPLEX PRO") { showingPaywall = true }
                }
            }
        }
    }

    /// Keep the preference while locked, but present the unavailable capability
    /// as off. A tap remembers the intent and opens the paywall; AttentionCenter
    /// still cannot schedule anything until Pro is owned.
    private var agentAlertsBinding: Binding<Bool> {
        Binding(
            get: { entitlements.canScheduleAgentAlerts && attention.alertsEnabled },
            set: { enabled in
                if enabled && !entitlements.canScheduleAgentAlerts {
                    attention.alertsEnabled = true
                    showingPaywall = true
                } else {
                    attention.alertsEnabled = enabled
                }
            }
        )
    }

    private var proSection: some View {
        TallyFormSection(
            "Multiplex Pro",
            detail: "Pro adds unlimited hosts, mosh, unlimited agent-helper commands, alerts, and custom themes. SSH terminals, agent detection, and the wall's live state stay free."
        ) {
            TallyFormRow {
                HStack(spacing: 12) {
                    ChassisLabel(
                        entitlements.isPro ? "Pro unlocked" : "Free tier",
                        size: 11
                    )
                    Spacer()
                    ChassisBadge(
                        entitlements.isPro ? "UNLOCKED" : "FREE",
                        prominent: entitlements.isPro
                    )
                }
            }

            proRow("Unlimited Hosts")
            proRow("Mosh Transport")
            proRow(
                "Agent Helpers",
                freeStatus: "\(EntitlementStore.dailySlashChipLimit) / DAY"
            )
            proRow("Agent Alerts")
            proRow("Custom Themes")

            TallyFormRow {
                ChassisChip(
                    entitlements.isPro ? "PRO DETAILS" : "UNLOCK MULTIPLEX PRO",
                    prominent: true
                ) {
                    showingPaywall = true
                }
            }

            #if DEBUG
            TallyFormBoolField(
                "Pro debug override",
                isOn: Binding(
                    get: { entitlements.isPro },
                    set: { entitlements.setDebugUnlocked($0) }
                ),
                accessibilityLabel: "Pro unlocked debug override"
            )
            #endif
        }
    }

    /// A Pro feature's lock status row.
    private func proRow(_ name: String, freeStatus: String = "Locked") -> some View {
        TallyFormRow {
            HStack(spacing: 12) {
                ChassisLabel(name, size: 9, color: Theme.signal2)
                Spacer()
                ChassisBadge(entitlements.isPro ? "INCLUDED" : freeStatus.uppercased())
            }
        }
    }

    private func duplicate(_ theme: TerminalTheme) {
        guard entitlements.canMutateCustomThemes else {
            showingPaywall = true
            return
        }
        editingTheme = theme.asCustom(named: "\(theme.name) Copy")
    }

    /// Custom-theme mutation is Pro-gated at the edit intent. Existing
    /// themes remain selectable and deletable, so losing/restoring an
    /// entitlement never strands the user's current appearance or data.
    private func requestThemeEditor(_ theme: TerminalTheme) {
        guard entitlements.canMutateCustomThemes else {
            showingPaywall = true
            return
        }
        editingTheme = theme
    }

    private func save(_ theme: TerminalTheme) {
        if themes.theme(id: theme.id) == nil {
            themes.add(theme)
            themes.select(theme, for: colorScheme)
        } else {
            themes.update(theme)
        }
    }

    #if DEBUG
    private func presentThemeEditorForVerificationIfRequested() {
        guard ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_SETTINGS"] == "theme"
        else { return }
        editingTheme = themes.selected(for: colorScheme).asCustom(named: "Tally Custom")
    }
    #endif
}

/// One selectable theme: live terminal preview, identity, status, and optional
/// custom-theme actions kept outside the selection button's hit target.
private struct ThemeRow: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let select: () -> Void
    var edit: (() -> Void)?
    var duplicate: (() -> Void)?
    var delete: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if hasActions {
            row.contextMenu { actions }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 1) {
            Button(action: select) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        ThemePreview(theme: theme, compact: true)
                            .frame(width: 148)
                        identity
                        Spacer(minLength: 12)
                        selectionBadge
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            identity
                            Spacer(minLength: 8)
                            selectionBadge
                        }
                        ThemePreview(theme: theme, compact: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Theme.bezel : Theme.chassis)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chassisHover(2)
            .accessibilityLabel("\(theme.name) theme")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if hasActions {
                Menu {
                    actions
                } label: {
                    ChassisBadge("", systemImage: "ellipsis")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("Actions for \(theme.name)")
            }
        }
        .background(Theme.bezelHi)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            ChassisLabel(theme.name, size: 11)
            Text(theme.isBuiltIn ? "BUILT-IN PALETTE" : "CUSTOM PALETTE")
                .font(.mono(8, weight: .medium))
                .kerning(1)
                .foregroundStyle(Theme.signal3)
                .lineLimit(1)
        }
    }

    private var selectionBadge: some View {
        ChassisBadge(isSelected ? "ACTIVE" : "SELECT", prominent: isSelected)
    }

    private var hasActions: Bool {
        edit != nil || duplicate != nil || delete != nil
    }

    @ViewBuilder
    private var actions: some View {
        if let edit {
            Button("Edit…", action: edit)
        }
        if let duplicate {
            Button("Duplicate", action: duplicate)
        }
        if let delete {
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

/// A theme rendered as what it is — a small terminal: prompt line, cursor,
/// and the ANSI palette. Every color shown is a color the theme defines.
struct ThemePreview: View {
    let theme: TerminalTheme
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            promptLine.font(.mono(fontSize)).lineLimit(1)
            if !compact {
                outputLine.font(.mono(fontSize)).lineLimit(1)
            }
            ansiStrip
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(theme.background))
        .overlay(
            Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(theme.name) terminal theme")
    }

    private var fontSize: CGFloat { compact ? 10 : 13 }

    private var promptLine: Text {
        Text("jhen@devbox").foregroundStyle(Color(theme.ansi(2)))
            + Text(" ~").foregroundStyle(Color(theme.ansi(4)))
            + Text(" $ tmux a").foregroundStyle(Color(theme.foreground))
            + Text(" █").foregroundStyle(Color(theme.cursor))
    }

    private var outputLine: Text {
        Text("✓ ").foregroundStyle(Color(theme.ansi(2)))
            + Text("attached · 3 windows").foregroundStyle(Color(theme.ansi(8)))
    }

    private var ansiStrip: some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(compact ? Array(0..<8) : Array(0..<16), id: \.self) { index in
                Rectangle()
                    .fill(Color(theme.ansi(index)))
                    .frame(width: compact ? 8 : 12, height: compact ? 8 : 12)
            }
        }
    }
}

private extension TerminalTheme {
    /// Preview-safe palette access — an invalid custom theme must not crash
    /// the settings sheet.
    func ansi(_ index: Int) -> ThemeColor {
        ansi.indices.contains(index) ? ansi[index] : foreground
    }
}

#if DEBUG
#Preview("Theme Preview") {
    VStack(spacing: 18) {
        ThemePreview(theme: .tally)
        ThemePreview(theme: .solarizedLight, compact: true)
            .frame(width: 180)
    }
    .padding()
    .frame(width: 440)
    .background(Theme.chassis)
    .preferredColorScheme(.dark)
}

#Preview("Theme Row") {
    VStack(spacing: 8) {
        ThemeRow(theme: .tally, isSelected: true, select: {})
        ThemeRow(theme: .nord, isSelected: false, select: {})
    }
    .padding()
    .frame(width: 520)
    .background(Theme.chassis)
    .preferredColorScheme(.dark)
}
#endif
