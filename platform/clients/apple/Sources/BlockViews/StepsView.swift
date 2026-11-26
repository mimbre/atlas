import AtlasControlKit
import ControlSession
import SwiftUI

/// A `steps` block, the page's panel, in the panel's card (`PanelCard`): the eyebrow,
/// the work with its key and how far it is, why (and how long it has been theirs), the
/// steps done as one muted line each with ✓, the current one open on a light background
/// (its text, its commands each in a block that hugs it, with a copy icon), the later ones
/// as one muted line each saying how many commands they fold away, then the buttons: this
/// step done and the page's answers (`StepsPanel.buttons`), each the action Control
/// declares. `others`: the page's actions besides, shown with them (More…).
struct StepsView: View {
    let block: StepsBlock
    var others: [ActionModel] = []
    let act: (ActionModel) -> Void

    @State private var copied: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.pendingAction) private var pending

    private var panel: StepsPanel { StepsPanel(block) }

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            PanelHeading(eyebrow: "TO DO FOR YOU", title: block.title, key: block.key, trailing: panel.progress)
            if let why = panel.whyLine(now: Date()) {
                Text(why).prism(Prism.Typography.caption).foregroundStyle(muted)
            }
            VStack(alignment: .leading, spacing: Prism.Spacing.s2) {
                ForEach(block.steps, id: \.n) { step in
                    if panel.place(step) == .current {
                        current(step)
                    } else {
                        StepRow(step: step, done: panel.place(step) == .done)
                    }
                }
            }
            if let pending, pending.kind == .sending {
                HStack(spacing: Prism.Spacing.s6) {
                    ProgressView().controlSize(.small)
                    Text(pending.text).foregroundStyle(muted)
                }
            }
            ActionsView(actions: panel.buttons(others: others), act: act)
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelCard())
    }

    private var muted: Color { Prism.Colors.muted(scheme) }

    /// The current step, open on a light background: its number, then its lines in the
    /// order written: text, a command in its block with a copy icon, a route as its parts.
    private func current(_ step: InstructionStepModel) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
                Text("\(step.n).").bold().monospacedDigit().frame(width: StepRow.number, alignment: .trailing)
                VStack(alignment: .leading, spacing: Prism.Spacing.s6) {
                    ForEach(Array(step.lines.enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Prism.Spacing.s6) {
                if let all = panel.allCommands, step.commands.count > 1 {
                    Button { copy(all) } label: {
                        Label("Copy all", systemImage: copied == all ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .foregroundStyle(muted)
                    .help("Copy all commands")
                }
            }
            .padding(.leading, StepRow.number + Prism.Spacing.s10)
        }
        .prism(Prism.Typography.tableRow)
        .padding(.horizontal, Prism.Spacing.s10)
        .padding(.vertical, Prism.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Prism.Colors.row(scheme, selected: true, hovering: false),
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current step \(step.n)")
    }

    @ViewBuilder
    private func lineView(_ line: InstructionLineModel) -> some View {
        switch line.kind {
        case "command":
            let command = line.text ?? ""
            CommandBlock(command: command, copied: copied == command) { copy(command) }
        case "route":
            RouteLine(parts: line.parts ?? [])
        default:
            Text(line.text ?? "").bold().textSelection(.enabled)
        }
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
}

/// A step done or still to come, one muted line: ✓ for one done, its number, its first
/// line, and for one to come what it folds away ("· 2 commands").
struct StepRow: View {
    let step: InstructionStepModel
    let done: Bool
    @Environment(\.colorScheme) private var scheme

    /// The width of a step's number, so the steps' texts line up.
    static let number: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
            Text(done ? "✓" : "\(step.n).").monospacedDigit()
                .foregroundStyle(done ? (scheme == .dark ? Prism.Colors.success : Prism.Colors.grey1) : muted)
                .frame(width: Self.number, alignment: .trailing)
            (Text(StepsPanel.firstLine(step.text))
                + Text(done ? "" : StepsPanel.holds(step).map { "  · " + $0 } ?? "").font(.caption))
                .foregroundStyle(muted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .prism(Prism.Typography.tableRow)
        .padding(.horizontal, Prism.Spacing.s10)
        .padding(.vertical, Prism.Spacing.s7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.n), \(done ? "done" : "to come"): \(step.text)")
    }

    private var muted: Color { Prism.Colors.muted(scheme) }
}

/// A route, the way to something in an app: a muted ⌘, then each part as a small label
/// with a muted › before the next; a long route wraps before a ›. Dark: primarylight on a
/// faint primary; light: grey1 on white with a grey3 edge, on the current step's tint.
struct RouteLine: View {
    let parts: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FlowLayout(spacing: Prism.Spacing.s6) {
            Text("⌘").foregroundStyle(Prism.Colors.muted(scheme))
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                HStack(spacing: Prism.Spacing.s6) {
                    if index > 0 { Text("›").foregroundStyle(Prism.Colors.muted(scheme)) }
                    label(part)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Go to \(parts.joined(separator: ", then "))")
    }

    private func label(_ part: String) -> some View {
        Text(part).prism(Prism.Typography.labelSmall).textSelection(.enabled)
            .foregroundStyle(scheme == .dark ? Prism.Colors.primaryLight : Prism.Colors.grey1)
            .padding(.horizontal, Prism.Spacing.s6)
            .padding(.vertical, 3)
            .background(scheme == .dark ? Prism.Colors.primary.opacity(0.35) : Prism.Colors.white,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(scheme == .dark ? Color.clear : Prism.Colors.grey3))
    }
}

/// One command in a block that hugs it (grey5 in light, grey1 in dark; no border),
/// monospaced and selectable, wrapping at the column's width, with a copy icon right after
/// it; for a moment after a copy the icon is a checkmark.
struct CommandBlock: View {
    let command: String
    let copied: Bool
    let copy: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
            Text(command).monospaced().textSelection(.enabled)
                .foregroundStyle(scheme == .dark ? Prism.Colors.white : Prism.Colors.grey1)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Prism.Colors.muted(scheme))
            .help(copied ? "Copied" : "Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy")
        }
        .prism(Prism.Typography.tableRow)
        .padding(.horizontal, Prism.Spacing.s10)
        .padding(.vertical, Prism.Spacing.s7)
        .background(scheme == .dark ? Prism.Colors.grey1 : Prism.Colors.grey5,
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command: \(command)")
    }
}
