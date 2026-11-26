import AtlasControlKit
import ControlSession
import Prism
import SwiftUI

/// A `panel` block, where its owner decides (to accept, to merge), in the calm card the
/// details below it have too (`PrismCard`): the eyebrow (the heading) over the title with
/// its key (and the aside at its right), the byline, the items it is judged on (the
/// selected one on a light background, its details under them), its checks (✓ ✗ … —, by
/// state), its box, then at the bottom its answers and the page's other actions and links,
/// each with its key. The answers are buttons, a yes green and a no (with a note) orange;
/// ↑ ↓ select an item and Return opens it (`PanelKeys`). An answer is the page's action of
/// its key (`Panel.action`): `act` submits its call, or opens its page (a no's note form).
/// `others`: the page's other actions.
struct PanelView: View {
    let block: PanelBlock
    let others: [ActionModel]
    let open: (String) -> Void
    let act: (ActionModel) -> Void

    @State private var panel: Panel
    @State private var token = UUID()
    @Environment(\.pendingAction) private var pending
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.panelKeys) private var panelKeys

    init(block: PanelBlock, others: [ActionModel] = [], open: @escaping (String) -> Void,
         act: @escaping (ActionModel) -> Void) {
        self.block = block
        self.others = others
        self.open = open
        self.act = act
        _panel = State(initialValue: Panel(block))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px15) {
            PanelHeading(eyebrow: block.heading ?? "", title: block.title ?? "", key: block.key, trailing: block.aside)
            if let byline = block.byline, !byline.isEmpty {
                // The ages keep current.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Panel.byline(byline, now: context.date))
                        .prism(Prism.Typography.caption).foregroundStyle(muted)
                }
            }
            if !panel.items.isEmpty {
                items
            }
            if let item = panel.selectedItem, let details = item.details, !details.isEmpty {
                PanelDetails(pairs: details)
            }
            if let checks = block.checks, !checks.isEmpty {
                PanelChecks(checks: checks)
            }
            if let box = block.box {
                PanelBox(box: box)
            }
            if let pending, pending.kind == .sending {
                HStack(spacing: Prism.Spacing.px6) {
                    ProgressView().progressViewStyle(.prism(.accent, size: .size20))
                    Text(pending.text).foregroundStyle(muted)
                }
            }
            buttons
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelCard())
        .onAppear(perform: claim)
        .onDisappear { panelKeys?.release(token) }
        .onChange(of: block) { _, new in panel.update(new) }
    }

    /// ↑ ↓ and Return while the panel has the keys' focus. The arrows only ever move the
    /// selection; Return opens or answers the selected one, once.
    private func claim() {
        panelKeys?.claim(token) { [$panel, open, act] key, isRepeat in
            guard let outcome = $panel.wrappedValue.press(key, isRepeat: isRepeat) else { return false }
            Self.apply(outcome, open: open, act: act)
            return true
        }
    }

    private var muted: Color { PrismDarkGap.muted(scheme) }

    /// The items, one row each: its key, its label; the selected one set apart.
    private var items: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px2) {
            ForEach(Array(panel.items.enumerated()), id: \.element.key) { offset, item in
                PanelRow(marker: offset == panel.selected, key: item.key ?? "", label: item.label ?? "",
                         accessibility: [item.key, item.label].compactMap { $0 }.joined(separator: ": "),
                         hint: "Select; again to open (↑ ↓, Return)") {
                    apply(panel.click(item: item))
                }
            }
        }
    }

    /// At the bottom: the answers as buttons, then the panel's actions and links, and the
    /// page's other actions, each with its key.
    private var buttons: some View {
        FlowLayout(spacing: Prism.Spacing.px10) {
            ForEach(panel.answers, id: \.key) { answer in
                AnswerButton(answer: answer, pending: PageActions.isPending(Panel.action(answer), pending)) {
                    apply(panel.answer(answer))
                }
            }
            ForEach(Array(((block.actions ?? []) + others).enumerated()), id: \.offset) { _, action in
                KeyButton(label: action.label ?? "", key: action.key) { act(action) }
            }
            ForEach(Array(Panel.links(block).enumerated()), id: \.offset) { _, link in
                KeyButton(label: link.link.label ?? link.url.absoluteString, key: link.link.key) { openURL(link.url) }
            }
        }
        .textSelection(.disabled)
    }

    private func apply(_ outcome: Panel.Outcome) {
        Self.apply(outcome, open: open, act: act)
    }

    private static func apply(_ outcome: Panel.Outcome, open: (String) -> Void, act: (ActionModel) -> Void) {
        switch outcome {
        case .nothing: break
        case .open(let to): open(to)
        case .act(let action): act(action)
        }
    }
}

/// The top of a panel: the eyebrow (what is asked of its owner, "TO ACCEPT") in small
/// caps, the one place in primary; under it the title as a heading with the key of the
/// fact it is about, muted, beside it; `trailing` (how far it is, how many) muted at the
/// right.
struct PanelHeading: View {
    let eyebrow: String
    let title: String
    let key: String?
    let trailing: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px6) {
            Text(eyebrow.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
                .foregroundStyle(PrismDarkGap.accentText(scheme))
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.px13) {
                (Text(title) + Text(key.map { "   " + $0 } ?? "").font(Prism.Typography.label.font.weight(.regular))
                    .foregroundColor(PrismDarkGap.muted(scheme)))
                    .prism(Prism.Typography.title7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing, !trailing.isEmpty {
                    Text(trailing).prism(Prism.Typography.caption).foregroundStyle(PrismDarkGap.muted(scheme))
                        .fixedSize()
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One item, one row: its key and its label. The selected row is on Prism's selection
/// tint; hovering one shows it takes a click.
struct PanelRow: View {
    let marker: Bool
    let key: String
    let label: String
    let accessibility: String
    var hint: String = ""
    let take: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: take) {
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.px10) {
                Text(key).monospaced().foregroundStyle(PrismDarkGap.muted(scheme)).fixedSize()
                Text(label).bold(marker)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .prism(Prism.Typography.tablerow)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, Prism.Spacing.px10)
            .padding(.vertical, Prism.Spacing.px7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PrismDarkGap.row(scheme, selected: marker, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .onHover { hovering = $0 }
        .help(hint)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(marker ? [.isSelected] : [])
    }
}

/// The selected item's details, a label and its value per row, on a faint surface.
struct PanelDetails: View {
    let pairs: [PairModel]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Prism.Spacing.px13, verticalSpacing: Prism.Spacing.px6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    Text(pair.label ?? "").foregroundStyle(PrismDarkGap.muted(scheme))
                    Text(pair.value ?? "—").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .modifier(Framed())
    }
}

/// The checks, a row each: the state's glyph (✓ ✗ … —), which says it, on the state's
/// tint, then the check and what it says.
struct PanelChecks: View {
    let checks: [CheckModel]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Prism.Spacing.px10, verticalSpacing: Prism.Spacing.px6) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                GridRow {
                    let role = Self.role(check.state ?? "")
                    Text(Panel.glyph(check.state ?? "")).bold()
                        .foregroundStyle(Prism.Colors.grey1)
                        .frame(width: Prism.Spacing.px18, height: Prism.Spacing.px18)
                        .background(role.tint, in: Circle())
                        .overlay(Circle().strokeBorder(role.color))
                        .accessibilityLabel(check.state ?? "")
                    Text(check.label ?? "").bold()
                    Text(check.text ?? "").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .prism(Prism.Typography.tablerow)
    }

    private static func role(_ state: String) -> (color: Color, tint: Color) {
        switch state {
        case "success": (Prism.Colors.success, Prism.Colors.successlight)
        case "error": (Prism.Colors.error, Prism.Colors.errorlight)
        case "pending": (Prism.Colors.warning, Prism.Colors.warninglight)
        default: (Prism.Colors.grey2, Prism.Colors.grey4)
        }
    }
}

/// A text with its title (muted), on a faint surface; with tone `error`, framed in the
/// error colour, the one frame that says something.
struct PanelBox: View {
    let box: BoxModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px5) {
            if let title = box.title {
                Text(title).prism(Prism.Typography.labelsmall).foregroundStyle(PrismDarkGap.muted(scheme))
            }
            Text(box.text ?? "").frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(Framed(border: box.tone == "error" ? Prism.Colors.error : nil))
    }
}

/// A text without a title, in caption type, on a faint surface; framed only with `border`
/// (an error), the one frame that says something.
struct Framed: ViewModifier {
    var border: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .prism(Prism.Typography.caption)
            .textSelection(.enabled)
            .padding(Prism.Spacing.px10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PrismDarkGap.framed(scheme), in: RoundedRectangle(cornerRadius: Prism.radius))
            .overlay(RoundedRectangle(cornerRadius: Prism.radius).strokeBorder(border ?? .clear))
    }
}

/// An answer as Prism's button (`AnswerLabelButton`), "· note" after one given with a
/// note: a yes `primary` in success, a no `secondary` in warning, a `quiet` one `plain`.
/// Its key only in its tooltip.
struct AnswerButton: View {
    let answer: PanelAnswerModel
    var quiet = false
    let pending: Bool
    let take: () -> Void

    var body: some View {
        let no = answer.note == true
        let label = answer.label ?? ""
        PrismActionButton(label: no ? label + " · note" : label, key: answer.key, pending: pending,
                          variant: no ? .secondary : quiet ? .plain : .primary,
                          tone: no ? .warning : quiet ? .accent : .success, take: take)
    }
}

/// An action or link of a panel as Prism's `plain` button; its key only in its tooltip.
struct KeyButton: View {
    let label: String
    let key: String?
    let take: () -> Void

    var body: some View {
        PrismActionButton(label: label, key: key, pending: false, variant: .plain, take: take)
    }
}

/// How a key reads in a tooltip or the menu bar: one character as it is, Control's named
/// keys as their signs (Enter ↩, Up ↑, Down ↓); nil for a key it does not show.
enum KeyGlyph {
    static func glyph(_ key: String?) -> String? {
        guard let key else { return nil }
        return switch key {
        case "Enter": "↩"
        case "Up": "↑"
        case "Down": "↓"
        case _ where key.count == 1: key
        default: nil
        }
    }
}
