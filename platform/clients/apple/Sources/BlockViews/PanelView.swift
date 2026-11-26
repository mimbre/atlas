import AtlasControlKit
import ControlSession
import SwiftUI

/// A `panel` block, where its owner decides (to accept, to merge, stuck work), in the calm
/// card the details below it have too (`PrismCard`): the eyebrow (the heading) over the
/// title with its key (and the aside at its right), the byline, the items it is judged on
/// (the selected one on a light background, its details under them), its checks (✓ ✗ … —,
/// by state), its box, then at the bottom its answers and the page's other actions and
/// links, each with its key. Without `choose` the answers are buttons, a yes green and a no
/// (with a note) orange; ↑ ↓ select an item and Return opens it. With `choose` the answers
/// are a choice, the recommended one selected at first, the selected one's detail under
/// it; ↑ ↓ move the selection and Return answers it (`PanelKeys`). An answer is the page's
/// action of its key (`Panel.action`): `act` submits its call, or opens its page (a no's
/// note form). `others`: the page's actions besides (More…).
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
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            PanelHeading(eyebrow: block.heading, title: block.title, key: block.key, trailing: block.aside)
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
            if panel.choosing {
                choice
            }
            if let pending, pending.kind == .sending {
                HStack(spacing: Prism.Spacing.s6) {
                    ProgressView().controlSize(.small)
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

    private var muted: Color { Prism.Colors.muted(scheme) }

    /// The items, one row each: its key, its label; the selected one set apart.
    private var items: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s2) {
            ForEach(Array(panel.items.enumerated()), id: \.element.key) { offset, item in
                PanelRow(marker: offset == panel.selected, key: item.key, label: item.label, tags: [],
                         accessibility: "\(item.key): \(item.label)", hint: "Select; again to open (↑ ↓, Return)") {
                    apply(panel.click(item: item))
                }
            }
        }
    }

    /// The answers as a choice, as the single choice shows its options, and what the
    /// selected one does.
    private var choice: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s6) {
            VStack(alignment: .leading, spacing: Prism.Spacing.s2) {
                ForEach(Array(panel.answers.enumerated()), id: \.element.key) { offset, answer in
                    PanelRow(marker: offset == panel.selected, key: answer.key, label: answer.label,
                             tags: Self.tags(answer), accessibility: "Answer \(answer.key): \(answer.label)",
                             hint: "Answer (\(answer.key); ↑ ↓ choose, Return answers the selected one)") {
                        apply(panel.answer(answer))
                    }
                }
            }
            if let detail = panel.selectedAnswer?.detail, !detail.isEmpty {
                Text(detail).prism(Prism.Typography.caption).foregroundStyle(muted)
                    .padding(.leading, Prism.Spacing.s10)
            }
        }
    }

    /// At the bottom: the answers as buttons (not in a choice), then the panel's actions
    /// and links, and the page's other actions, each with its key.
    private var buttons: some View {
        FlowLayout(spacing: Prism.Spacing.s10) {
            if !panel.choosing {
                ForEach(panel.answers, id: \.key) { answer in
                    AnswerButton(answer: answer, pending: PageActions.isPending(Panel.action(answer), pending)) {
                        apply(panel.answer(answer))
                    }
                }
            }
            ForEach(Array(((block.actions ?? []) + others).enumerated()), id: \.offset) { _, action in
                KeyButton(label: action.label, key: action.key) { act(action) }
            }
            ForEach(Array(Panel.links(block).enumerated()), id: \.offset) { _, link in
                KeyButton(label: link.link.label, key: link.link.key) { openURL(link.url) }
            }
        }
        .textSelection(.disabled)
    }

    private static func tags(_ answer: PanelAnswerModel) -> [RoleTagModel] {
        var tags: [RoleTagModel] = []
        if answer.recommended == true {
            tags.append(RoleTagModel(text: "★ recommended", role: Prism.Colors.success, tint: Prism.Colors.successLight))
        }
        if answer.note == true {
            tags.append(RoleTagModel(text: "· note", role: Prism.Colors.warning, tint: Prism.Colors.warningLight))
        }
        return tags
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
        VStack(alignment: .leading, spacing: Prism.Spacing.s6) {
            Text(eyebrow.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Prism.Colors.accentText(scheme))
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s13) {
                (Text(title) + Text(key.map { "   " + $0 } ?? "").font(Prism.Typography.label.font.weight(.regular))
                    .foregroundColor(Prism.Colors.muted(scheme)))
                    .prism(Prism.Typography.title7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing, !trailing.isEmpty {
                    Text(trailing).prism(Prism.Typography.caption).foregroundStyle(Prism.Colors.muted(scheme))
                        .fixedSize()
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RoleTagModel: Hashable {
    let text: String
    let role: Color
    let tint: Color
}

/// One item or answer, one row: its key, its label, and at the right what sets it apart.
/// The selected row is on Prism's selection tint; hovering one shows it takes a click.
struct PanelRow: View {
    let marker: Bool
    let key: String
    let label: String
    let tags: [RoleTagModel]
    let accessibility: String
    var hint: String = ""
    let take: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: take) {
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
                Text(key).monospaced().foregroundStyle(Prism.Colors.muted(scheme)).fixedSize()
                Text(label).bold(marker)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(tags, id: \.self) { tag in
                    RoleTag(text: tag.text, role: tag.role, tint: tag.tint)
                }
            }
            .prism(Prism.Typography.tableRow)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, Prism.Spacing.s10)
            .padding(.vertical, Prism.Spacing.s7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Prism.Colors.row(scheme, selected: marker, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .onHover { hovering = $0 }
        .help(hint)
        .accessibilityLabel(accessibility + tags.map { ", " + $0.text }.joined())
        .accessibilityAddTraits(marker ? [.isSelected] : [])
    }
}

/// The selected item's details, a label and its value per row, on a faint surface.
struct PanelDetails: View {
    let pairs: [PairModel]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Prism.Spacing.s13, verticalSpacing: Prism.Spacing.s6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    Text(pair.label).foregroundStyle(Prism.Colors.muted(scheme))
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
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Prism.Spacing.s10, verticalSpacing: Prism.Spacing.s6) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                GridRow {
                    let role = Self.role(check.state)
                    Text(Panel.glyph(check.state)).bold()
                        .foregroundStyle(Prism.Colors.grey1)
                        .frame(width: Prism.Spacing.s18, height: Prism.Spacing.s18)
                        .background(role.tint, in: Circle())
                        .overlay(Circle().strokeBorder(role.color))
                        .accessibilityLabel(check.state)
                    Text(check.label).bold()
                    Text(check.text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .prism(Prism.Typography.tableRow)
    }

    private static func role(_ state: String) -> (color: Color, tint: Color) {
        switch state {
        case "success": (Prism.Colors.success, Prism.Colors.successLight)
        case "error": (Prism.Colors.error, Prism.Colors.errorLight)
        case "pending": (Prism.Colors.warning, Prism.Colors.warningLight)
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
        VStack(alignment: .leading, spacing: Prism.Spacing.s5) {
            Text(box.title).prism(Prism.Typography.labelSmall).foregroundStyle(Prism.Colors.muted(scheme))
            Text(box.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(Framed(border: box.tone == "error" ? Prism.Colors.error : nil))
    }
}

/// An answer as a button: its key as a keycap on its left, its label, with "· note" for
/// one given with a note. A yes in success, a no in warning, a `quiet` one (More…) in grey.
/// Light: on the tone's light tint with grey1 text, the quiet one on grey5 with a grey edge
/// (3.7:1 on white). Dark: a faint wash of the tone with white text (over 10:1) and the
/// tone as its edge (over 5:1 on the dark surface), the quiet one's edge grey2. Pending, a
/// spinner in place of its key.
struct AnswerButton: View {
    let answer: PanelAnswerModel
    var quiet = false
    let pending: Bool
    let take: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let no = answer.note == true
        Button(action: take) {
            HStack(spacing: Prism.Spacing.s6) {
                if pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Keycap(key: answer.key, inButton: true)
                }
                Text(no ? answer.label + " · note" : answer.label).prism(Prism.Typography.labelSmall)
            }
            .foregroundStyle(scheme == .dark ? Prism.Colors.white : Prism.Colors.grey1)
            .padding(.horizontal, Prism.Spacing.s10)
            .padding(.vertical, Prism.Spacing.s6)
            .background(fill(no: no), in: RoundedRectangle(cornerRadius: Prism.radius))
            .overlay(RoundedRectangle(cornerRadius: Prism.radius).strokeBorder(edge(no: no), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .help("\(answer.label) (\(answer.key))")
    }

    private func fill(no: Bool) -> Color {
        let dark = scheme == .dark
        if no { return dark ? Prism.Colors.warning.opacity(0.18) : Prism.Colors.warningLight }
        if quiet { return dark ? Prism.Colors.white.opacity(0.06) : Prism.Colors.grey5 }
        return dark ? Prism.Colors.success.opacity(0.18) : Prism.Colors.successLight
    }

    private func edge(no: Bool) -> Color {
        if no { return Prism.Colors.warning }
        if quiet { return scheme == .dark ? Prism.Colors.grey2 : Prism.Colors.grey1.opacity(0.55) }
        return Prism.Colors.success
    }
}

/// An action or link of a panel as a quiet button: its key as a keycap, its label.
struct KeyButton: View {
    let label: String
    let key: String
    let take: () -> Void

    var body: some View {
        Button(action: take) {
            HStack(spacing: Prism.Spacing.s6) {
                if let glyph = Keycap.glyph(key) { Keycap(key: glyph, inButton: true) }
                Text(label)
            }
        }
        .buttonStyle(.bordered)
        .help(Keycap.glyph(key).map { "\(label) (\($0))" } ?? label)
    }
}

/// A key, as macOS shows a menu's shortcut: a small neutral keycap (grey5 with a thin grey3
/// border in light, a grey a little lighter than the surface in dark), in the text's own
/// colour. Inside a button (`inButton`) it is quieter: no fill, the label's colour.
struct Keycap: View {
    let key: String
    var inButton = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(key).font(.caption.monospaced())
            .padding(.horizontal, Prism.Spacing.s5).padding(.vertical, Prism.Spacing.s1)
            .background(fill, in: RoundedRectangle(cornerRadius: Prism.radius))
            .overlay(RoundedRectangle(cornerRadius: Prism.radius).strokeBorder(border, lineWidth: 0.5))
            .opacity(inButton ? 0.85 : 1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var fill: Color {
        if inButton { return .clear }
        return scheme == .dark ? Color.white.opacity(0.12) : Prism.Colors.grey5
    }

    private var border: Color {
        if inButton { return Color.primary.opacity(0.3) }
        return scheme == .dark ? Color.white.opacity(0.2) : Prism.Colors.grey3
    }

    /// A key as a keycap shows it: one character as it is, Control's named keys as their
    /// signs (Enter ↩, Up ↑, Down ↓); nil for a key it does not show.
    static func glyph(_ key: String) -> String? {
        switch key {
        case "Enter": "↩"
        case "Up": "↑"
        case "Down": "↓"
        case _ where key.count == 1: key
        default: nil
        }
    }
}
