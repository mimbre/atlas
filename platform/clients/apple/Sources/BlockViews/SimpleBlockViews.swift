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
/// (`TextLine`), its age kept current. With role `error` (something went wrong), in a
/// red-tinted recessed card (`RecessedCard`, no shadow): its label as the card's heading
/// beside a warning sign in Prism's error colour, its text under it in the text's colour.
struct TextBlockView: View {
    let block: TextBlock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if block.role == "error" {
                HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Prism.Colors.error)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Prism.Spacing.s6) {
                        if let label = block.label {
                            Text(label).prism(Prism.Typography.labelSmall)
                                .accessibilityAddTraits(.isHeader)
                        }
                        Text(TextLine.text(block, now: context.date)).prism(Prism.Typography.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
                .modifier(RecessedCard(error: true))
                .accessibilityElement(children: .contain)
            } else {
                Text(TextLine.line(block, now: context.date))
                    .prism(Prism.Typography.caption)
                    .foregroundStyle(Prism.Colors.muted(scheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Prism.Spacing.s15)
            }
        }
    }
}

/// An `instruction` block, one step, in a calm card of its own (`PanelCard`, without the
/// keys' focus), shown in full: its number in a badge, then its lines in the order written:
/// text with its breaks, a route as its parts with › between them, a command in a light
/// inset with a copy icon right after it. Without `room`, its stack gives its shadow room
/// (`CardStack`).
struct InstructionView: View {
    let block: InstructionBlock
    var room = true
    @State private var copied: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s13) {
            StepNumber(n: block.n)
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

/// A step's or an option's number in a badge: white on primary's shade, round.
struct StepNumber: View {
    let n: Int

    /// Its size, so what follows starts at the same place on every card.
    static let size: CGFloat = 24

    var body: some View {
        Text("\(n)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Prism.Colors.white)
            .frame(width: Self.size, height: Self.size)
            .background(Prism.Colors.primaryShade, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Cards that follow each other (steps, options), one each, stacked with equal weight:
/// the room for their shadows (`ShadowRoom`) is the stack's, so the cards stand as close
/// as a list's.
struct CardStack: View {
    let items: [PagePresentation.Item]
    let act: (ActionModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .instruction(let block): InstructionView(block: block, room: false)
                case .option(let block): OptionView(block: block, room: false, act: act)
                default: EmptyView()
                }
            }
        }
        .modifier(ShadowRoom())
    }

    /// Whether the item is shown as one of a stack's cards.
    static func stacks(_ item: PagePresentation.Item) -> Bool {
        switch item {
        case .instruction, .option: true
        default: false
        }
    }
}

/// An `option` block, one option of a decision, in a calm card of its own (`PanelCard`,
/// without the keys' focus), as a step's: its number as a step's, its text, its badge in
/// its tone (★ Recommended in success, Decline · note in warning), what it means as label
/// and value rows (its Rule and what follows Then; a decline's Details), and its own answer
/// as a button with its key in a neutral keycap: a yes (Choose) filled green, one that asks
/// a note (Decline…) an orange outline, which opens the note form. The button is the page's
/// action of the answer's key (`Panel.action`): exactly what the key does.
struct OptionView: View {
    let block: OptionBlock
    var room = true
    let act: (ActionModel) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.pendingAction) private var pending

    var body: some View {
        let action = Option.action(block)
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s13) {
            StepNumber(n: block.n)
            VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
                HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
                    Text(block.text).prism(Prism.Typography.title7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let badge = block.badge, !badge.isEmpty {
                        let tone = Self.tone(block.tone)
                        RoleTag(text: badge, role: tone.role, tint: tone.tint)
                    }
                }
                if !block.fields.isEmpty {
                    Grid(alignment: .topLeading, horizontalSpacing: Prism.Spacing.s13, verticalSpacing: Prism.Spacing.s6) {
                        ForEach(Array(block.fields.enumerated()), id: \.offset) { _, field in
                            GridRow {
                                Text(field.label).foregroundStyle(Prism.Colors.muted(scheme))
                                Text(field.value ?? "—").frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .prism(Prism.Typography.caption)
                }
                OptionButton(answer: block.answer, pending: PageActions.isPending(action, pending)) { act(action) }
                    .padding(.top, Prism.Spacing.s3)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelCard(focusable: false, room: room))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Option \(block.n)")
    }

    /// A badge's colours by its tone: success, warning, else neutral grey.
    private static func tone(_ tone: String?) -> (role: Color, tint: Color) {
        switch tone {
        case "success": (Prism.Colors.success, Prism.Colors.successLight)
        case "warning": (Prism.Colors.warning, Prism.Colors.warningLight)
        default: (Prism.Colors.grey2, Prism.Colors.grey5)
        }
    }
}

/// An option's own answer as a button: its key in a neutral keycap, then its label. A yes
/// (Choose) is filled in success green with grey1 text (6.3:1) and a light keycap, in both
/// appearances; one that asks a note (Decline…) is an orange outline in warning, its text
/// the text's colour. Pending, a spinner in place of its key.
struct OptionButton: View {
    let answer: PanelAnswerModel
    let pending: Bool
    let take: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let decline = answer.note == true
        Button(action: take) {
            HStack(spacing: Prism.Spacing.s6) {
                if pending {
                    ProgressView().controlSize(.mini)
                } else if let glyph = Keycap.glyph(answer.key) {
                    Keycap(key: glyph, light: !decline)
                }
                Text(answer.label).prism(Prism.Typography.labelSmall)
            }
            .foregroundStyle(decline ? (scheme == .dark ? Prism.Colors.white : Prism.Colors.grey1) : Prism.Colors.grey1)
            .padding(.horizontal, Prism.Spacing.s13)
            .padding(.vertical, Prism.Spacing.s7)
            .background(decline ? Color.clear : Prism.Colors.success, in: RoundedRectangle(cornerRadius: Prism.radius))
            .overlay(RoundedRectangle(cornerRadius: Prism.radius)
                .strokeBorder(decline ? Prism.Colors.warning : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
        .disabled(pending)
        .help("\(answer.label) (\(answer.key))")
    }
}

/// A short word that sets something apart ("★ Recommended"): grey1 on the role's light
/// tint, readable in either appearance, the role's colour as its border; the words say it,
/// not the colour.
struct RoleTag: View {
    let text: String
    let role: Color
    let tint: Color

    var body: some View {
        Text(text).prism(Prism.Typography.captionSmall)
            .foregroundStyle(Prism.Colors.grey1)
            .padding(.horizontal, Prism.Spacing.s6).padding(.vertical, Prism.Spacing.s2)
            .background(tint, in: Capsule())
            .overlay(Capsule().strokeBorder(role))
            .fixedSize()
    }
}

/// An `answers` block, on the page itself: a button per answer, in Control's order, each
/// with its key, each taking its answer as the page's action of that key (`Panel.action`).
/// The first (the next step) is a yes, green; one that asks a note is a no, orange, as a
/// panel's answers are; the others (More…) quiet. Under a decision's options (`quiet`),
/// which are its answers, every one but a no is quiet.
struct AnswersView: View {
    let block: AnswersBlock
    var quiet = false
    let act: (ActionModel) -> Void
    @Environment(\.pendingAction) private var pending

    var body: some View {
        FlowLayout(spacing: Prism.Spacing.s10) {
            ForEach(Array(block.answers.enumerated()), id: \.offset) { offset, answer in
                let action = Panel.action(answer)
                AnswerButton(answer: answer, quiet: answer.note != true && (quiet || offset > 0),
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
