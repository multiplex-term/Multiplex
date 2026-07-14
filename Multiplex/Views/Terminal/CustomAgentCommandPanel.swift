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

/// Anchored TALLY editor for one agent's custom helper commands. Rows remain
/// drafts until DONE, so delete/reorder is forgiving and tapping outside or
/// CANCEL discards the whole edit session.
struct CustomAgentCommandPanel: View {
    static let preferredWidth: CGFloat = 500

    let agent: AgentKind
    private let width: CGFloat
    let save: ([CustomAgentCommand]) -> Void
    let cancel: () -> Void

    @State private var drafts: CustomAgentCommandDrafts
    @State private var measuredCommandListHeight: CGFloat = 0
    @FocusState private var focusedCommandID: UUID?

    init(
        agent: AgentKind,
        commands: [CustomAgentCommand],
        width: CGFloat = Self.preferredWidth,
        save: @escaping ([CustomAgentCommand]) -> Void,
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
                ChassisLabel("CUSTOM COMMANDS", size: 13)
                Spacer(minLength: 8)
                ChassisLabel(agent.displayName, size: 9, color: Theme.customCommand)
            }
            // Match the tmux shortcuts title origin so both anchored panels
            // share the same breathing room from the rounded top corner.
            .padding(.top, 6)
            .padding(.leading, 1)

            Text("Type one or many lines. Auto Submit sends Return after the content; turn it off to leave the text ready to edit.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.signal2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var commandList: some View {
        ScrollView {
            VStack(spacing: 1) {
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
        .scrollDisabled(measuredCommandListHeight <= Self.maximumEditorHeight)
        .onPreferenceChange(CustomAgentCommandListHeightKey.self) { height in
            let measuredHeight = ceil(height)
            guard measuredHeight > 0,
                  abs(measuredHeight - measuredCommandListHeight) >= 0.5
            else { return }
            measuredCommandListHeight = measuredHeight
        }
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

            HStack(spacing: 8) {
                ChassisSwitch(
                    "SUBMIT",
                    isOn: command.autoSubmit,
                    accessibilityLabel: "Auto Submit"
                )
                ChassisSwitch(
                    "BAR",
                    isOn: command.showInBar,
                    accessibilityLabel: "Show in Bar"
                )
                ChassisSwitch(
                    "SHARED",
                    isOn: command.shared,
                    accessibilityLabel: "Shared between Claude Code and Codex"
                )

                Spacer(minLength: 8)

                ChassisLabel(
                    placementLabel,
                    size: 8,
                    color: command.wrappedValue.showInBar
                        ? Theme.customCommand
                        : Theme.signal3
                )

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
            .padding(.leading, 28)
        }
        .padding(10)
        .background(Theme.chassis)
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
                    Text("Bar keeps the first 9 characters and adds ... when needed; turn it off to use More.")
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
                    save(CustomAgentCommand.normalized(drafts.commands))
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
        CGFloat(max(1, drafts.commands.count)) * 102 + 24
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
