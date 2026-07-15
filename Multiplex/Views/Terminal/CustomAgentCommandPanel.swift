import Foundation
import Observation
import SwiftUI

/// Stable, ID-addressed editor state. Text fields can deliver a final binding
/// write while SwiftUI tears down a deleted or reordered row; resolving that
/// write by ID makes the late update a safe no-op instead of indexing into the
/// array position the row used to occupy.
@MainActor
@Observable
final class CustomAgentCommandDrafts {
    private(set) var commands: [CustomAgentCommand]

    init(commands: [CustomAgentCommand]) {
        self.commands = commands
    }

    func command(id: UUID) -> CustomAgentCommand? {
        commands.first(where: { $0.id == id })
    }

    func update(_ updated: CustomAgentCommand, id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        var stable = updated
        stable.id = id
        commands[index] = stable
    }

    @discardableResult
    func appendBlank() -> CustomAgentCommand {
        let command = CustomAgentCommand(content: "")
        commands.append(command)
        return command
    }

    func move(id: UUID, offset: Int) {
        guard let source = commands.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard commands.indices.contains(destination) else { return }
        commands.swapAt(source, destination)
    }

    func remove(id: UUID) {
        commands.removeAll { $0.id == id }
    }
}

/// Anchored TALLY editor for one agent's built-in placement and custom helper
/// commands. Every choice remains a draft until DONE, so edits are forgiving
/// and tapping outside or CANCEL discards the whole session.
struct CustomAgentCommandPanel: View {
    static let preferredWidth: CGFloat = 500

    let agent: AgentKind
    private let width: CGFloat
    let save: (
        [CustomAgentCommand],
        [String: AgentCommandPlacement]
    ) -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drafts: CustomAgentCommandDrafts
    @State private var builtInPlacementOverrides: [String: AgentCommandPlacement]
    @State private var isBuiltInExpanded = false
    @State private var measuredCommandListHeight: CGFloat = 0
    @FocusState private var focusedCommandID: UUID?

    init(
        agent: AgentKind,
        commands: [CustomAgentCommand],
        builtInPlacements: [String: AgentCommandPlacement] = [:],
        width: CGFloat = Self.preferredWidth,
        save: @escaping (
            [CustomAgentCommand],
            [String: AgentCommandPlacement]
        ) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.agent = agent
        self.width = width
        self.save = save
        self.cancel = cancel
        _drafts = State(initialValue: CustomAgentCommandDrafts(
            commands: commands.isEmpty
                ? [CustomAgentCommand(content: "")]
                : commands
        ))
        _builtInPlacementOverrides = State(initialValue:
            AgentCommandSet.normalizedPlacementOverrides(
                builtInPlacements,
                for: agent
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            commandList
            divider
            footer
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bezel)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        .presentationBackground(Theme.bezel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ChassisLabel("COMMAND SETUP", size: 13)
                Spacer(minLength: 8)
                ChassisLabel(agent.displayName, size: 9, color: Theme.customCommand)
            }
            // Match the tmux shortcuts title origin so both anchored panels
            // share the same breathing room from the rounded top corner.
            .padding(.top, 6)
            .padding(.leading, 1)

            Text("Place each built-in in Bar or More. Custom content may span many lines; turn Submit off to leave it ready to edit.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.signal2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var commandList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 1) {
                builtInAccordionHeader
                if isBuiltInExpanded {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 210), spacing: 1)],
                        spacing: 1
                    ) {
                        ForEach(builtInCommands) { command in
                            builtInCommandRow(command)
                        }
                    }
                    .transition(.opacity)
                }

                commandSectionHeader("CUSTOM", detail: "ORDERED")
                // Do not iterate over `$commands`: SwiftUI's collection
                // binding captures array indices, which become invalid while
                // a focused row is deleted or moved. Resolve every edit by
                // stable command ID instead, and ignore a late write from a
                // row that has already left the collection.
                ForEach(drafts.commands) { command in
                    commandRow(binding(for: command))
                }
                if drafts.commands.isEmpty {
                    ChassisLabel("NO CUSTOM COMMANDS", size: 10, color: Theme.signal3)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(Theme.chassis)
                }
            }
            .background(Theme.bezelHi)
            .padding(12)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CustomAgentCommandListHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .frame(height: editorHeight)
        .onPreferenceChange(CustomAgentCommandListHeightKey.self) { height in
            let measuredHeight = ceil(height)
            guard measuredHeight > 0,
                  abs(measuredHeight - measuredCommandListHeight) >= 0.5
            else { return }
            measuredCommandListHeight = measuredHeight
        }
    }

    private var builtInCommands: [AgentCommand] {
        AgentCommandSet.all(for: agent)
    }

    private var builtInAccordionHeader: some View {
        Button(action: toggleBuiltInCommands) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.signal2)
                    .rotationEffect(.degrees(isBuiltInExpanded ? 90 : 0))
                    .frame(width: 12)
                ChassisLabel("BUILT-IN", size: 9)
                Spacer(minLength: 8)
                ChassisLabel(
                    "\(builtInCommands.count) ITEMS · BAR / MORE",
                    size: 8,
                    color: Theme.signal3
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bezel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel("Built-in commands")
        .accessibilityValue(isBuiltInExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows placement controls for built-in commands")
    }

    private func commandSectionHeader(
        _ title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 10) {
            ChassisLabel(title, size: 9)
            Spacer(minLength: 8)
            ChassisLabel(detail, size: 8, color: Theme.signal3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.bezel)
    }

    private func builtInCommandRow(_ command: AgentCommand) -> some View {
        HStack(spacing: 10) {
            Text(command.label)
                .font(.mono(10, weight: .semibold))
                .foregroundStyle(Theme.signal2)
                .lineLimit(1)
            Spacer(minLength: 6)
            TallyChoiceBar(
                [("BAR", AgentCommandPlacement.bar),
                 ("MORE", AgentCommandPlacement.more)],
                selection: builtInPlacementBinding(for: command)
            )
            .frame(width: 112)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(Theme.chassis)
    }

    private func builtInPlacementBinding(
        for command: AgentCommand
    ) -> Binding<AgentCommandPlacement> {
        Binding(
            get: {
                AgentCommandSet.resolvedPlacement(
                    for: command.id,
                    kind: agent,
                    placementOverrides: builtInPlacementOverrides
                ) ?? .more
            },
            set: { placement in
                guard let stockPlacement = AgentCommandSet.defaultPlacement(
                    for: command.id,
                    kind: agent
                ) else { return }
                var overrides = builtInPlacementOverrides
                if placement == stockPlacement {
                    overrides.removeValue(forKey: command.id)
                } else {
                    overrides[command.id] = placement
                }
                builtInPlacementOverrides = overrides
            }
        )
    }

    private func commandRow(_ command: Binding<CustomAgentCommand>) -> some View {
        let id = command.wrappedValue.id
        let index = drafts.commands.firstIndex(where: { $0.id == id }) ?? 0
        let barLabel = command.wrappedValue.barLabel
        let placementLabel = switch (
            command.wrappedValue.shared,
            command.wrappedValue.showInBar
        ) {
        case (true, true): "BOTH · \(barLabel ?? "EMPTY")"
        case (true, false): "BOTH · MORE"
        case (false, true): "BAR · \(barLabel ?? "EMPTY")"
        case (false, false): "MORE"
        }

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Text(String(format: "%02d", index + 1))
                    .font(.mono(9, weight: .semibold))
                    .foregroundStyle(Theme.signal3)
                    .frame(width: 18, alignment: .leading)

                TextField("Command content", text: command.content, axis: .vertical)
                    .font(.mono(11))
                    .foregroundStyle(Theme.signal)
                    .lineLimit(2...5)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.plain)
                    .focused($focusedCommandID, equals: id)
                    .padding(9)
                    .background(Theme.screen)
                    .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
            }

            commandControls(
                command,
                id: id,
                index: index,
                placementLabel: placementLabel
            )
            .padding(.leading, 28)
        }
        .padding(10)
        .background(Theme.chassis)
    }

    /// Preserve the existing one-line iPad anatomy when it fits. Phone-width
    /// panels fall back to two measured lines: switches first, then placement
    /// and row actions. Fixed intrinsic switch widths make ViewThatFits choose
    /// the fallback instead of satisfying the proposal by truncating captions.
    private func commandControls(
        _ command: Binding<CustomAgentCommand>,
        id: UUID,
        index: Int,
        placementLabel: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                commandSwitches(command)
                Spacer(minLength: 8)
                commandPlacementLabel(placementLabel, command: command)
                commandRowActions(id: id, index: index)
            }

            VStack(alignment: .leading, spacing: 8) {
                commandSwitches(command)
                HStack(spacing: 8) {
                    commandPlacementLabel(placementLabel, command: command)
                    Spacer(minLength: 8)
                    commandRowActions(id: id, index: index)
                }
            }
        }
    }

    private func commandSwitches(
        _ command: Binding<CustomAgentCommand>
    ) -> some View {
        HStack(spacing: 8) {
            ChassisSwitch(
                "SUBMIT",
                isOn: command.autoSubmit,
                accessibilityLabel: "Auto Submit"
            )
            .fixedSize(horizontal: true, vertical: false)
            ChassisSwitch(
                "BAR",
                isOn: command.showInBar,
                accessibilityLabel: "Show in Bar"
            )
            .fixedSize(horizontal: true, vertical: false)
            ChassisSwitch(
                "SHARED",
                isOn: command.shared,
                accessibilityLabel: "Shared between Claude Code and Codex"
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func commandPlacementLabel(
        _ placementLabel: String,
        command: Binding<CustomAgentCommand>
    ) -> some View {
        ChassisLabel(
            placementLabel,
            size: 8,
            color: command.wrappedValue.showInBar
                ? Theme.customCommand
                : Theme.signal3
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func commandRowActions(id: UUID, index: Int) -> some View {
        HStack(spacing: 8) {
            rowButton(
                "arrow.up",
                label: "Move command up",
                disabled: index == 0
            ) { moveCommand(id: id, offset: -1) }
            rowButton(
                "arrow.down",
                label: "Move command down",
                disabled: index >= drafts.commands.count - 1
            ) { moveCommand(id: id, offset: 1) }
            rowButton("trash", label: "Delete command") {
                deleteCommand(id: id)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func rowButton(
        _ systemImage: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(disabled ? Theme.signal3 : Theme.signal2)
                .frame(width: 25, height: 23)
                .background(Theme.chassis)
                .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.customCommand)
                        .frame(width: 6, height: 6)
                    Text("Built-ins and custom commands each live in Bar or More; custom Bar labels keep 9 characters.")
                        .font(.mono(8, weight: .medium))
                        .foregroundStyle(Theme.signal2)
                }
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.signal3)
                        .frame(width: 6, height: 6)
                    Text("Shared keeps one editable command synchronized in Claude Code and Codex.")
                        .font(.mono(8, weight: .medium))
                        .foregroundStyle(Theme.signal2)
                }
            }

            HStack(spacing: 8) {
                ChassisChip("ADD COMMAND", systemImage: "plus", action: addCommand)
                Spacer(minLength: 12)
                ChassisChip("CANCEL", action: cancel)
                ChassisChip("DONE", prominent: true) {
                    save(
                        CustomAgentCommand.normalized(drafts.commands),
                        AgentCommandSet.normalizedPlacementOverrides(
                            builtInPlacementOverrides,
                            for: agent
                        )
                    )
                }
            }
        }
        .padding(14)
    }

    private var divider: some View {
        Rectangle().fill(Theme.bezelHi).frame(height: 1)
    }

    private var editorHeight: CGFloat {
        min(
            Self.maximumEditorHeight,
            measuredCommandListHeight > 0
                ? measuredCommandListHeight
                : estimatedCommandListHeight
        )
    }

    /// Used only for the first layout pass. The measured rendered height takes
    /// over immediately and follows multiline edits plus ADD/DELETE exactly.
    private var estimatedCommandListHeight: CGFloat {
        if isBuiltInExpanded { return Self.maximumEditorHeight }
        return CGFloat(max(1, drafts.commands.count)) * 102 + 60
    }

    private func toggleBuiltInCommands() {
        if reduceMotion {
            isBuiltInExpanded.toggle()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                isBuiltInExpanded.toggle()
            }
        }
    }

    private func addCommand() {
        let command = drafts.appendBlank()
        Task { @MainActor in
            await Task.yield()
            focusedCommandID = command.id
        }
    }

    private func moveCommand(id: UUID, offset: Int) {
        drafts.move(id: id, offset: offset)
    }

    private func deleteCommand(id: UUID) {
        if focusedCommandID == id { focusedCommandID = nil }
        drafts.remove(id: id)
    }

    /// A binding whose identity survives insertions, reorders, and deletes.
    /// The snapshot is only a harmless fallback during SwiftUI's teardown of
    /// a deleted row; writes after deletion intentionally do nothing.
    private func binding(for snapshot: CustomAgentCommand) -> Binding<CustomAgentCommand> {
        Binding(
            get: {
                drafts.command(id: snapshot.id) ?? snapshot
            },
            set: { updated in
                drafts.update(updated, id: snapshot.id)
            }
        )
    }
}

private extension CustomAgentCommandPanel {
    static let maximumEditorHeight: CGFloat = 430
}

private struct CustomAgentCommandListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Let the custom editor keep its designed intrinsic panel size on modern
    /// OS releases. Older supported releases use the panel's fixed sizing.
    @ViewBuilder
    func customCommandPresentationSizing() -> some View {
        #if os(visionOS)
        if #available(visionOS 2.0, *) {
            presentationSizing(.fitted)
        } else {
            self
        }
        #else
        if #available(iOS 18.0, *) {
            presentationSizing(.fitted)
        } else {
            self
        }
        #endif
    }
}
