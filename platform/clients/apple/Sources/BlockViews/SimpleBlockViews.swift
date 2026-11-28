import AtlasControlKit
import ControlSession
import Prism
import SwiftUI

/// A `header` block, on the page itself (no card): the icon of its fact's kind (`KindIcon`,
/// grey; none for a kind this app does not know), the eyebrow and the key in small caps in
/// the accent's text colour ("TO DO FOR YOU · TD-12"), then the title as the page's title;
/// `actions`, the page's own (`PageActions.ofPage`), beside it as `PageHeader` has them.
/// What else can be done with its subject is in the window's toolbar (`ItemToolbar`).
struct HeaderBlockView: View {
    let block: HeaderBlock
    var actions: [ActionModel] = []
    let act: (ActionModel) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px6) {
            if let eyebrow {
                HStack(alignment: .center, spacing: Prism.Spacing.px6) {
                    if let symbol = SidebarLook.symbol(block.icon) { KindIcon(symbol: symbol) }
                    Text(eyebrow).tracking(0.8).prism(Prism.Typography.labelsmall)
                        .foregroundStyle(PrismDarkGap.accentText(scheme))
                        .textSelection(.enabled)
                }
            }
            PageHeader(title: block.title ?? "", actions: actions, act: act)
            if block.detail?.isEmpty == false || block.since?.isEmpty == false {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(HeaderState.line(block, now: context.date) ?? "")
                        .prism(Prism.Typography.caption)
                        .foregroundStyle(PrismDarkGap.muted(scheme))
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, Prism.Spacing.px15)
        .padding(.top, Prism.Spacing.px10)
    }

    /// The eyebrow and the key, as one line: either alone when the other is not sent.
    private var eyebrow: String? {
        let parts = [block.eyebrow?.uppercased(), block.key].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A `text` block, on the page itself, muted: "the old key leaked. · 3h ago"
/// (`TextLine`), its age kept current. With role `error` (something went wrong), as
/// Prism's `MessageBar` in its danger tone: its label as a heading, its text under it.
struct TextBlockView: View {
    let block: TextBlock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if block.role == "error" {
                PrismMessageBar(tone: .danger) {
                    VStack(spacing: Prism.Spacing.px6) {
                        if let label = block.label {
                            Text(label).prism(Prism.Typography.label)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if TextLine.isMarkdown(block) {
                            MarkdownText(source: block.text ?? "")
                            if let age = block.since.flatMap({ TextLine.age(since: $0, now: context.date) }) {
                                Text(age)
                            }
                        } else {
                            Text(TextLine.text(block, now: context.date))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, Prism.Spacing.px15)
                .accessibilityElement(children: .contain)
            } else {
                Group {
                    if TextLine.isMarkdown(block) {
                        VStack(alignment: .leading, spacing: Prism.Spacing.px6) {
                            if let label = block.label { Text(label) }
                            MarkdownText(source: block.text ?? "")
                            if let age = block.since.flatMap({ TextLine.age(since: $0, now: context.date) }) {
                                Text(age)
                            }
                        }
                    } else {
                        Text(TextLine.line(block, now: context.date))
                    }
                }
                    .prism(Prism.Typography.bodysmall)
                    .foregroundStyle(PrismDarkGap.muted(scheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Prism.Spacing.px15)
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
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.px13) {
            if let n = block.n { StepNumber(n: n) }
            VStack(alignment: .leading, spacing: Prism.Spacing.px10) {
                ForEach(Array((block.lines ?? []).enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelCard(focusable: false, room: room))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.n.map { "Step \($0)" } ?? "Step")
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
            Text(Instruction.shown(line)).prism(Prism.Typography.bodysmall).textSelection(.enabled)
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

/// A step's or an option's number: Prism's `StepIndicator`, current (white on primary).
struct StepNumber: View {
    let n: Int

    var body: some View {
        PrismStepIndicator(status: .current) { Text("\(n)") }
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
        VStack(alignment: .leading, spacing: Prism.Spacing.px15) {
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
/// without the keys' focus): its number as a step's (none on the only proposal), its text,
/// its badge in its tone (★ Recommended in success); then what it means at the card's full
/// width, each field a section (its label as a subtitle, its text in full under it: Rule,
/// Consequences); and its own answer as Prism's button (`OptionButton`), except on the
/// only proposal (`alone`), which the page's Accept answers. The button is the page's
/// action of the answer's key (`Panel.action`): exactly what the key does.
struct OptionView: View {
    let block: OptionBlock
    var room = true
    var detailHeading = false
    let act: (ActionModel) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.pendingAction) private var pending

    var body: some View {
        let action = Option.action(block)
        VStack(alignment: .leading, spacing: Prism.Spacing.px10) {
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.px13) {
                if let n = Option.number(block) { StepNumber(n: n) }
                Text(block.text ?? "").prism(detailHeading ? Prism.Typography.title6 : Prism.Typography.title5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge = block.badge, !badge.isEmpty {
                    PrismTag(tone: Self.tone(block.tone)) { Text(badge) }.fixedSize()
                }
            }
            ForEach(Array(Option.fields(block).enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: Prism.Spacing.px3) {
                    Text(field.label ?? "").prism(Prism.Typography.label).foregroundStyle(PrismDarkGap.muted(scheme))
                    FormattedText(text: field.value ?? "—", format: field.format).prism(Prism.Typography.bodysmall)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if block.alone != true, let answer = block.answer, let action {
                OptionButton(answer: answer, pending: PageActions.isPending(action, pending)) { act(action) }
                    .padding(.top, Prism.Spacing.px3)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelCard(focusable: false, room: room))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.n.map { "Option \($0)" } ?? "Option")
    }

    /// A badge's tone: success, warning, else neutral.
    private static func tone(_ tone: String?) -> PrismTagTone {
        switch tone {
        case "success": .success
        case "warning": .warning
        default: .neutral
        }
    }
}

/// An alternative's own Choose as Prism's button: the recommended one (weight main)
/// `primary`, every other `secondary`. Its key is not shown (the menu bar lists it); its
/// tooltip says what it does (`AnswerLook.tooltip`).
struct OptionButton: View {
    let answer: PanelAnswerModel
    let pending: Bool
    let take: () -> Void

    var body: some View {
        PrismActionButton(label: AnswerLook.label(answer), help: AnswerLook.tooltip(answer), pending: pending,
                          variant: answer.weight == "main" ? .primary : .secondary, take: take)
    }
}

/// Prism's button, `help` (`Tooltip`: Control's `help`, else its label) its tooltip;
/// pending, Prism's loading button (its spinner in place of the label). With `icon` (an SF
/// Symbol), Prism's with-icon look. A `plain` one keeps its label legible in dark
/// appearance (`PrismDarkGap.buttonStyle`).
struct PrismActionButton: View {
    let label: String
    let help: String
    let pending: Bool
    let variant: PrismButtonVariant
    var tone: PrismButtonTone = .accent
    var padded = true
    var icon: String? = nil
    let take: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: take) {
            // Its icon in the primary colour, every symbol fitted in one square (one size
            // for all, whatever the symbol's own) and centred on the label's line; its
            // label as Prism's button text.
            if let icon {
                HStack(alignment: .center, spacing: Prism.Spacing.px6) {
                    Image(systemName: icon).resizable().scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(variant == .primary ? AnyShapeStyle(.foreground)
                                                             : AnyShapeStyle(PrismDarkGap.icon(scheme)))
                    Text(label)
                }
            } else {
                Text(label)
            }
        }
        .buttonStyle(PrismDarkGap.buttonStyle(variant, tone: tone, padded: padded, loading: pending,
                                              icon: icon != nil, scheme: scheme))
        .textSelection(.disabled)
        .disabled(pending)
        .help(help)
    }
}

/// An `answers` block, with primary answers before other answers. On the opened item
/// the `other` answers are in the window's toolbar (`PageActions.toolbar`).
struct AnswersView: View {
    let block: AnswersBlock
    var toolbar = false
    var followsCardsBeforeDetails = false
    let act: (ActionModel) -> Void
    @Environment(\.pendingAction) private var pending
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let answers = Self.shown(block, toolbar: toolbar)
        VStack(alignment: .leading, spacing: Prism.Spacing.px6) {
            FlowLayout(spacing: Prism.Spacing.px10) {
                ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                    let action = Panel.action(answer)
                    AnswerButton(answer: answer, pending: PageActions.isPending(action, pending)) { act(action) }
                }
            }
            // What an answer means, small under the buttons (Decline: what declining keeps).
            ForEach(Array(Self.details(answers).enumerated()), id: \.offset) { _, detail in
                Text(detail).prism(Prism.Typography.caption).foregroundStyle(PrismDarkGap.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Prism.Spacing.px15)
        .padding(.bottom, followsCardsBeforeDetails ? Prism.Spacing.px22 : Prism.Spacing.px10)
    }

    /// The answers the page shows: all of them, or on the opened item (`toolbar`) those
    /// that are not the toolbar's (`PageActions.inToolbar`).
    static func shown(_ block: AnswersBlock, toolbar: Bool) -> [PanelAnswerModel] {
        AnswerLook.ordered((block.answers ?? []).filter { !toolbar || !PageActions.inToolbar($0) })
    }

    /// Each answer's explanation, after its label ("Decline: Keeps one block per kind").
    static func details(_ answers: [PanelAnswerModel]) -> [String] {
        answers.compactMap { answer in
            guard let detail = answer.detail, !detail.isEmpty else { return nil }
            return "\(AnswerLook.label(answer)): \(detail)"
        }
    }
}

/// An `actions` block where a page shows it (an action's page over the window, a page that
/// is no opened item): what else can be done with the page's subject (Update, Hand to,
/// Delete), as quiet icon-only buttons, in Control's order: each the icon Control names
/// (`ActionIcon`) in the primary colour, one size for all; its short label (`button`) as
/// its tooltip and accessibility label. Delete comes last, a little apart, in the danger
/// colour; it opens Control's confirm first. The opened item's are in the window's toolbar
/// (`ItemToolbar`) instead.
struct OtherActionsView: View {
    let actions: [ActionModel]
    let act: (ActionModel) -> Void
    @Environment(\.pendingAction) private var pending
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let (rest, delete) = PageActions.split(actions)
        HStack(spacing: Prism.Spacing.px15) {
            ForEach(Array(rest.enumerated()), id: \.offset) { _, action in button(action) }
            if let delete {
                button(delete).padding(.leading, Prism.Spacing.px10)
            }
        }
        .textSelection(.disabled)
    }

    private func button(_ action: ActionModel) -> some View {
        let busy = PageActions.isPending(action, pending)
        return Button { act(action) } label: {
            Group {
                if busy {
                    ProgressView().progressViewStyle(.prism(.accent, size: .size16))
                } else {
                    Image(systemName: ActionIcon.symbol(action.icon) ?? "ellipsis.circle")
                        .resizable().scaledToFit()
                        .foregroundStyle(action.icon == "delete" || action.icon == "remove" ? Prism.Colors.error : PrismDarkGap.icon(scheme))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(PageActions.tooltip(action))
        .accessibilityLabel(AnswerLook.label(action))
    }
}

/// Quiet icon-only toolbar actions with descriptive tooltips and accessibility labels.
/// Delete and remove use the danger colour and open Control's confirm first.
public struct ItemToolbar: ToolbarContent {
    let actions: [ActionModel]
    let pending: SessionState.Pending?
    let trailing: Bool
    let act: (ActionModel) -> Void

    public init(actions: [ActionModel], pending: SessionState.Pending?, trailing: Bool, act: @escaping (ActionModel) -> Void) {
        self.actions = actions
        self.pending = pending
        self.trailing = trailing
        self.act = act
    }

    public var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if trailing && !actions.isEmpty { Spacer() }
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in button(action) }
        }
    }

    private func button(_ action: ActionModel) -> some View {
        let busy = PageActions.isPending(action, pending)
        // A view of its own, not a `Label`: the toolbar's display setting neither hides
        // nor adds a title.
        return Button { act(action) } label: {
            if busy {
                ProgressView().progressViewStyle(.prism(.accent, size: .size16))
            } else {
                ToolbarIcon(icon: action.icon)
            }
        }
        .disabled(busy)
        .help(PageActions.tooltip(action))
        .accessibilityLabel(AnswerLook.label(action))
    }
}

/// A toolbar action's icon: in the primary colour (its dark-appearance text colour in
/// dark), delete and remove in the danger colour.
private struct ToolbarIcon: View {
    let icon: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: ActionIcon.symbol(icon) ?? "ellipsis.circle")
            .foregroundStyle(icon == "delete" || icon == "remove" ? Prism.Colors.error : PrismDarkGap.icon(scheme))
    }
}

/// The opened item's toolbar actions (`PageActions.toolbar`) as a context menu's items, in
/// the toolbar's order: each its label and icon, Delete last after a divider, destructive.
struct ItemActionsMenu: View {
    let actions: [ActionModel]
    let act: (ActionModel) -> Void

    var body: some View {
        let (rest, delete) = PageActions.split(actions)
        ForEach(Array(rest.enumerated()), id: \.offset) { _, action in
            Button(AnswerLook.label(action), systemImage: ActionIcon.symbol(action.icon) ?? "ellipsis.circle") {
                act(action)
            }
        }
        if let delete {
            Divider()
            Button(AnswerLook.label(delete), systemImage: ActionIcon.symbol(delete.icon) ?? "trash",
                   role: .destructive) { act(delete) }
        }
    }
}

/// A route, the way to something in an app: a muted ⌘, then each part as a small label
/// with a muted › before the next; a long route wraps before a ›. Dark: primarylight on a
/// faint primary; light: grey1 on white with a grey3 edge.
struct RouteLine: View {
    let parts: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FlowLayout(spacing: Prism.Spacing.px6, wrapOversized: true) {
            Text("⌘").foregroundStyle(PrismDarkGap.muted(scheme))
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                HStack(spacing: Prism.Spacing.px6) {
                    if index > 0 { Text("›").foregroundStyle(PrismDarkGap.muted(scheme)) }
                    label(part)
                }
            }
        }
        .prism(Prism.Typography.labelsmall)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Go to \(parts.joined(separator: ", then "))")
    }

    private func label(_ part: String) -> some View {
        Text(part).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(PrismDarkGap.routeText(scheme))
            .padding(.horizontal, Prism.Spacing.px6)
            .padding(.vertical, 3)
            .background(PrismDarkGap.routeFill(scheme), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(PrismDarkGap.routeEdge(scheme)))
    }
}

/// One command in a light inset that hugs it (grey5 with a thin grey4 edge in light, a
/// step below the card in dark; no shadow), in Prism's `monosmall` (16/24, as the step's
/// `bodysmall`), so no larger than the step's text; selectable, wrapping at the card's width, with a copy icon
/// right after it, in primary blue (clickable) at the action icons' 16pt; for a moment after a copy the icon is
/// a checkmark, blue too.
struct CommandBlock: View {
    let command: String
    let copied: Bool
    let copy: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.px10) {
            Text(command).prism(Prism.Typography.monosmall).textSelection(.enabled)
                .foregroundStyle(PrismDarkGap.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .fontWeight(.semibold)
                    .foregroundStyle(PrismDarkGap.icon(scheme))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            .help(copied ? "Copied" : "Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy")
        }
        .prism(Prism.Typography.bodysmall)
        .padding(.horizontal, Prism.Spacing.px10)
        .padding(.vertical, Prism.Spacing.px7)
        .background(PrismDarkGap.inset(scheme), in: RoundedRectangle(cornerRadius: Prism.radius))
        .overlay(RoundedRectangle(cornerRadius: Prism.radius)
            .strokeBorder(PrismDarkGap.insetEdge(scheme)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command: \(command)")
    }
}
