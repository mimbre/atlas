import AtlasControlKit
import ControlSession
import SwiftUI

/// A `header` block, on the page itself (no card): the eyebrow and the key in small caps in
/// the accent's text colour ("TO DO FOR YOU · TD-12"), then the title as the page's title;
/// `actions`, the page's own (`PageActions.ofPage`), beside it as `PageHeader` has them.
struct HeaderBlockView: View {
    let block: HeaderBlock
    var actions: [ActionModel] = []
    let act: (ActionModel) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s6) {
            if let eyebrow {
                Text(eyebrow).font(.system(size: 11, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Prism.Colors.accentText(scheme))
                    .textSelection(.enabled)
            }
            PageHeader(title: block.title, actions: actions, act: act)
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, Prism.Spacing.s15)
        .padding(.top, Prism.Spacing.s10)
    }

    /// The eyebrow and the key, as one line: either alone when the other is not sent.
    private var eyebrow: String? {
        let parts = [block.eyebrow?.uppercased(), block.key].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A `text` block, on the page itself, muted: "Why: the old key leaked. · 3h ago"
/// (`TextLine`), its age kept current.
struct TextBlockView: View {
    let block: TextBlock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(TextLine.line(block, now: context.date))
                .prism(Prism.Typography.caption)
                .foregroundStyle(Prism.Colors.muted(scheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Prism.Spacing.s15)
    }
}

/// An `instruction` block, one step, in a calm card of its own (`PanelCard`, without the
/// keys' focus), shown in full: its number in a badge, then its lines in the order written:
/// text with its breaks, a route as its parts with › between them, a command in a light
/// inset with a copy icon right after it. Without `room`, its stack gives its shadow room
/// (`InstructionsView`).
struct InstructionView: View {
    let block: InstructionBlock
    var room = true
    @State private var copied: String?
    @Environment(\.colorScheme) private var scheme

    /// The badge's size, so the lines start at the same place on every card.
    static let badge: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s13) {
            Text("\(block.n)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Prism.Colors.white)
                .frame(width: Self.badge, height: Self.badge)
                .background(Prism.Colors.primaryShade, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
                ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelCard(focusable: false, room: room))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(block.n)")
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
            Text(Instruction.shown(line)).prism(Prism.Typography.caption).textSelection(.enabled)
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

/// Steps that follow each other, one card each, stacked with equal weight: the room for
/// their shadows (`ShadowRoom`) is the stack's, so the cards stand as close as a list's.
struct InstructionsView: View {
    let blocks: [InstructionBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                InstructionView(block: block, room: false)
            }
        }
        .modifier(ShadowRoom())
    }
}

/// An `answers` block, on the page itself: a button per answer, in Control's order, each
/// with its key, each taking its answer as the page's action of that key (`Panel.action`).
/// The first (the next step) and one recommended are a yes, green; one that asks a note is
/// a no, orange, as a panel's answers are; the others (More…) quiet.
struct AnswersView: View {
    let block: AnswersBlock
    let act: (ActionModel) -> Void
    @Environment(\.pendingAction) private var pending

    var body: some View {
        FlowLayout(spacing: Prism.Spacing.s10) {
            ForEach(Array(block.answers.enumerated()), id: \.offset) { offset, answer in
                let action = Panel.action(answer)
                let yes = answer.recommended == true || offset == 0
                AnswerButton(answer: answer, quiet: answer.note != true && !yes,
                             pending: PageActions.isPending(action, pending)) { act(action) }
            }
        }
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Prism.Spacing.s15)
        .padding(.bottom, Prism.Spacing.s10)
    }
}

/// A route, the way to something in an app: a muted ⌘, then each part as a small label
/// with a muted › before the next; a long route wraps before a ›. Dark: primarylight on a
/// faint primary; light: grey1 on white with a grey3 edge.
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

/// One command in a light inset that hugs it (grey5 with a thin grey4 edge in light, a
/// step below the card in dark; no shadow), monospaced and selectable, wrapping at the
/// card's width, with a copy icon right after it; for a moment after a copy the icon is a
/// checkmark.
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
        .overlay(RoundedRectangle(cornerRadius: Prism.radius)
            .strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Prism.Colors.grey4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command: \(command)")
    }
}
