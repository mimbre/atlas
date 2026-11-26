import AtlasControlKit
import ControlSession
import SwiftUI

/// A `steps` block as a panel, in the single choice's styling (`SingleChoiceView`): a bar
/// with the work and how far it is, why (and how long it has been theirs), the steps done
/// as one muted line each with ✓, the current one framed and open (▸, its text, its
/// commands each in a darker block with a Copy button), the later ones as one muted line
/// each, and the keys. Return marks the current step done, the arrows move it: each is
/// the action Control declares for that key (`act`). Its answers are the page's actions,
/// with the page's title.
struct StepsView: View {
    let block: StepsBlock
    let act: (ActionModel) -> Void

    @State private var copied: String?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.pendingAction) private var pending

    private var panel: StepsPanel { StepsPanel(block) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            VStack(alignment: .leading, spacing: Prism.Spacing.s13) {
                if let why = panel.whyLine(now: Date()) {
                    Text(why).prism(Prism.Typography.caption).foregroundStyle(muted)
                }
                VStack(alignment: .leading, spacing: Prism.Spacing.s6) {
                    ForEach(block.steps, id: \.n) { step in
                        switch panel.place(step) {
                        case .current: current(step)
                        case .done: line(step, done: true)
                        case .later: line(step, done: false)
                        }
                    }
                }
                // Its own actions as buttons too (one per step move: Next step does what
                // Step done does); the answers are the page's, with its title.
                ActionsView(actions: PageActions.ofBlock(block.actions), act: act)
                if let pending, pending.kind == .sending {
                    HStack(spacing: Prism.Spacing.s6) {
                        ProgressView().controlSize(.small)
                        Text(pending.text).foregroundStyle(muted)
                    }
                }
                Text(keys).prism(Prism.Typography.captionSmall).foregroundStyle(muted)
            }
            .padding(Prism.Spacing.s15)
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme == .dark ? PrismCard.systemBackground : Prism.Colors.white)
        .clipShape(RoundedRectangle(cornerRadius: Prism.radius))
        .overlay(RoundedRectangle(cornerRadius: Prism.radius).strokeBorder(Prism.Colors.primary, lineWidth: 2))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress { press in
            guard let key = Self.key(press), let action = panel.action(key) else { return .ignored }
            act(action)
            return .handled
        }
        .onAppear { focused = true }
    }

    /// The bar: white on primary's shade (white on primary itself is under 4.5:1), how far
    /// it is at the right.
    private var bar: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s15) {
            Text("◆ TO DO FOR YOU").prism(Prism.Typography.labelSmall).fixedSize()
            Text(block.title).prism(Prism.Typography.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(panel.progress).prism(Prism.Typography.labelSmall).fixedSize()
        }
        .foregroundStyle(Prism.Colors.white)
        .padding(.horizontal, Prism.Spacing.s15)
        .padding(.vertical, Prism.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Prism.Colors.primaryShade)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var muted: Color { Prism.Colors.muted(scheme) }

    /// A step done or still to come: its first line, muted; one done has ✓ (dark text on
    /// success's light tint in light appearance, success itself in dark).
    private func line(_ step: InstructionStepModel, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
            if done {
                Text("✓").bold()
                    .foregroundStyle(scheme == .dark ? Prism.Colors.success : Prism.Colors.grey1)
                    .frame(width: 18, height: 18)
                    .background(scheme == .dark ? Color.clear : Prism.Colors.successLight, in: Circle())
            } else {
                Text(" ").frame(width: 18)
            }
            Text("\(step.n). \(StepsPanel.firstLine(step.text))").lineLimit(1).truncationMode(.tail)
                .foregroundStyle(muted)
        }
        .prism(Prism.Typography.tableRow)
        .padding(.horizontal, Prism.Spacing.s6)
        .accessibilityLabel("Step \(step.n), \(done ? "done" : "to come"): \(step.text)")
    }

    /// The current step, framed and open: ▸, its text, its commands.
    private func current(_ step: InstructionStepModel) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
                Text("▸").bold().frame(width: 18)
                Text("\(step.n). \(step.text)").bold().textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(step.commands.enumerated()), id: \.offset) { _, command in
                CommandBlock(command: command, copied: copied == command) { copy(command) }
            }
            if let all = panel.allCommands, step.commands.count > 1 {
                Button(copied == all ? "✓ copied" : "Copy all commands") { copy(all) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .prism(Prism.Typography.tableRow)
        .padding(Prism.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme == .dark ? Prism.Colors.primary.opacity(0.18) : Prism.Colors.primaryLight,
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .overlay(RoundedRectangle(cornerRadius: Prism.radius).strokeBorder(Prism.Colors.primary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current step \(step.n)")
    }

    private func copy(_ text: String) {
        #if canImport(AppKit)
        Clipboard.copy(text)
        #endif
        copied = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copied == text { copied = nil }
        }
    }

    /// The keys there are, in one line; the answers' keys are on their buttons.
    private var keys: String {
        var keys: [String] = []
        if panel.action(.enter) != nil { keys.append("Return step done") }
        if panel.action(.up) != nil || panel.action(.down) != nil { keys.append("↑↓ move") }
        if panel.current?.commands.isEmpty == false { keys.append("Copy beside a command") }
        // Each key with its meaning stays on one line.
        return keys.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "  ·  ")
    }

    private static func key(_ press: KeyPress) -> StepsPanel.Key? {
        switch press.key {
        case .return: .enter
        case .upArrow: .up
        case .downArrow: .down
        default: nil
        }
    }
}

/// One command, in a darker block, monospaced and selectable, with its Copy button; for a
/// moment after a copy the button says so.
struct CommandBlock: View {
    let command: String
    let copied: Bool
    let copy: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: Prism.Spacing.s10) {
            Text(command).monospaced().textSelection(.enabled)
                .foregroundStyle(scheme == .dark ? Prism.Colors.white : Prism.Colors.grey1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "✓ copied" : "Copy", action: copy)
                .buttonStyle(.bordered).controlSize(.small)
                .help("Copy this command")
        }
        .prism(Prism.Typography.tableRow)
        .padding(.horizontal, Prism.Spacing.s10)
        .padding(.vertical, Prism.Spacing.s7)
        .background(scheme == .dark ? Color.black.opacity(0.45) : Prism.Colors.grey4,
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .accessibilityLabel("Command: \(command)")
    }
}
