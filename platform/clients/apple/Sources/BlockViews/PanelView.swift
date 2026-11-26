import AtlasControlKit
import ControlSession
import SwiftUI

/// A `panel` block, where its owner decides (to accept, to merge, stuck work), in the
/// single choice's styling: a bar with the heading and the title (and the aside at its
/// right), the byline, the items it is judged on (▸ on the selected one, its details in a
/// box under them), its checks (✓ ✗ … — by state), its box, its answers and a line of
/// keys. Without `choose` the answers are buttons, a yes green and a no (with a note)
/// orange; the arrows select an item and Return opens it. With `choose` the answers are a
/// choice, the recommended one selected at first, the selected one's detail under it; the
/// arrows move the selection and Return answers it. An answer is the page's action of its
/// key (`Panel.action`): `act` submits its call, or opens its page (a no's note form).
struct PanelView: View {
    let block: PanelBlock
    let open: (String) -> Void
    let act: (ActionModel) -> Void

    @State private var panel: Panel
    @FocusState private var focused: Bool
    @Environment(\.pendingAction) private var pending
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    init(block: PanelBlock, open: @escaping (String) -> Void, act: @escaping (ActionModel) -> Void) {
        self.block = block
        self.open = open
        self.act = act
        _panel = State(initialValue: Panel(block))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            VStack(alignment: .leading, spacing: Prism.Spacing.s13) {
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
                } else if !panel.answers.isEmpty {
                    FlowLayout(spacing: Prism.Spacing.s10) {
                        ForEach(panel.answers, id: \.key) { answer in
                            AnswerButton(answer: answer, pending: PageActions.isPending(Panel.action(answer), pending)) {
                                apply(panel.answer(answer))
                            }
                        }
                    }
                }
                if let pending, pending.kind == .sending {
                    HStack(spacing: Prism.Spacing.s6) {
                        ProgressView().controlSize(.small)
                        Text(pending.text).foregroundStyle(muted)
                    }
                }
                keys
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
            guard let key = Self.key(press), let outcome = panel.press(key) else { return .ignored }
            apply(outcome)
            return .handled
        }
        .onAppear { focused = true }
        .onChange(of: block) { _, new in panel.update(new) }
    }

    /// The bar: white on primary's shade (white on primary itself is under 4.5:1).
    private var bar: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s15) {
            Text("◆ " + block.heading).prism(Prism.Typography.labelSmall).fixedSize()
            Text(block.title).prism(Prism.Typography.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let aside = block.aside, !aside.isEmpty {
                Text(aside).prism(Prism.Typography.caption).fixedSize()
            }
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

    /// The items, one row each: ▸ on the selected one, its key, its label.
    private var items: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s2) {
            ForEach(Array(panel.items.enumerated()), id: \.element.key) { offset, item in
                PanelRow(marker: offset == panel.selected, key: item.key, label: item.label, tags: [],
                         accessibility: "\(item.key): \(item.label)") {
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
                             tags: Self.tags(answer), accessibility: "Answer \(answer.key): \(answer.label)") {
                        apply(panel.answer(answer))
                    }
                }
            }
            if let detail = panel.selectedAnswer?.detail, !detail.isEmpty {
                Text(detail).prism(Prism.Typography.caption).foregroundStyle(muted).lineLimit(1)
                    .padding(.leading, Prism.Spacing.s6)
            }
        }
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

    /// The keys there are, in one line: the arrows and Return, then the panel's actions
    /// and links, each a click away too.
    private var keys: some View {
        FlowLayout(spacing: Prism.Spacing.s13) {
            if panel.choosing, !panel.answers.isEmpty {
                KeyHint(key: "↑↓", label: "choose")
                KeyHint(key: "Return", label: "answer")
            } else if !panel.items.isEmpty {
                KeyHint(key: "↑↓", label: "select")
                KeyHint(key: "Return", label: "open")
            }
            ForEach(Array((block.actions ?? []).enumerated()), id: \.offset) { _, action in
                KeyHint(key: action.key, label: action.label) { act(action) }
            }
            ForEach(Array(Panel.links(block).enumerated()), id: \.offset) { _, link in
                KeyHint(key: link.link.key, label: link.link.label) { openURL(link.url) }
            }
        }
        .textSelection(.disabled)
    }

    private func apply(_ outcome: Panel.Outcome) {
        switch outcome {
        case .nothing: break
        case .open(let to): open(to)
        case .act(let action): act(action)
        }
    }

    private static func key(_ press: KeyPress) -> Panel.Key? {
        switch press.key {
        case .return: .enter
        case .upArrow: .up
        case .downArrow: .down
        default: nil
        }
    }
}

struct RoleTagModel: Hashable {
    let text: String
    let role: Color
    let tint: Color
}

/// One item or answer, one row: ▸ on the selected one, its key, its label, and at the
/// right what sets it apart. The selected row has Prism's selection tint. A click takes it.
struct PanelRow: View {
    let marker: Bool
    let key: String
    let label: String
    let tags: [RoleTagModel]
    let accessibility: String
    let take: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: take) {
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
                Text(marker ? "▸" : " ").bold().frame(width: Prism.Spacing.s10)
                Text(key).monospaced().bold().fixedSize()
                Text(label).bold(marker)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(tags, id: \.self) { tag in
                    RoleTag(text: tag.text, role: tag.role, tint: tag.tint)
                }
            }
            .prism(Prism.Typography.tableRow)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, Prism.Spacing.s6)
            .padding(.vertical, Prism.Spacing.s7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Prism.Colors.row(scheme, selected: marker, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibility + tags.map { ", " + $0.text }.joined())
        .accessibilityAddTraits(marker ? [.isSelected] : [])
    }
}

/// The selected item's details, a label and its value per row, framed.
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
    @Environment(\.colorScheme) private var scheme

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

/// A framed text with its title (muted); with tone `error`, an error-coloured border.
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

/// An answer as a button: its key and label, with "· note" for one given with a note.
/// A yes on the success tint, a no on the warning tint; grey1 text either way. Pending,
/// a spinner in place of its key.
struct AnswerButton: View {
    let answer: PanelAnswerModel
    let pending: Bool
    let take: () -> Void

    var body: some View {
        let no = answer.note == true
        Button(action: take) {
            HStack(spacing: Prism.Spacing.s6) {
                if pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Keycap(key: answer.key)
                }
                Text(no ? answer.label + " · note" : answer.label).prism(Prism.Typography.labelSmall)
            }
            .foregroundStyle(Prism.Colors.grey1)
            .padding(.horizontal, Prism.Spacing.s10)
            .padding(.vertical, Prism.Spacing.s6)
            .background(no ? Prism.Colors.warningLight : Prism.Colors.successLight,
                        in: RoundedRectangle(cornerRadius: Prism.radius))
            .overlay(RoundedRectangle(cornerRadius: Prism.radius)
                .strokeBorder(no ? Prism.Colors.warning : Prism.Colors.success, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .help("\(answer.label) (key \(answer.key))")
    }
}

/// A key as the key line shows it: grey1 on tertiary.
struct Keycap: View {
    let key: String

    var body: some View {
        Text(key).font(.caption.monospaced().bold())
            .foregroundStyle(Prism.Colors.grey1)
            .padding(.horizontal, Prism.Spacing.s5).padding(.vertical, Prism.Spacing.s1)
            .background(Prism.Colors.tertiary, in: RoundedRectangle(cornerRadius: Prism.radius))
            .fixedSize()
    }
}

/// A key and what it does, muted; with `take`, a click does it too.
struct KeyHint: View {
    let key: String
    let label: String
    var take: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let content = HStack(spacing: Prism.Spacing.s5) {
            Keycap(key: key)
            Text(label).prism(Prism.Typography.captionSmall).foregroundStyle(Prism.Colors.muted(scheme))
        }
        .fixedSize()
        if let take {
            Button(action: take) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("\(label) (key \(key))")
        } else {
            content
        }
    }
}
