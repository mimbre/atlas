import AtlasControlKit
import ControlSession
import SwiftUI

/// A `single_choice` block as a panel that asks for a decision: a bar with the question,
/// why the recommendation, the choices in Control's order (the recommended one first),
/// one aligned row each, the selected one marked ▸, what the selected one means (its rule
/// and what then follows; a decline's details) in a box under them, and the keys. The
/// arrows move the selection and Return answers it; a click or the choice's number
/// answers that choice; a choice given with a note opens a form for the note first.
/// `submit` is called with the call Control projected for the choice, and its values.
/// With the focus it tells `typingFocus` which digits are its own, so the page's action
/// keys leave them to it; once a choice is sent, it says so until Control answers.
struct SingleChoiceView: View {
    let block: SingleChoiceBlock
    let submit: (CallModel, [String: String]) -> Void

    @State private var choice: SingleChoice
    @State private var token = UUID()
    @FocusState private var focused: Bool
    @FocusState private var noteFocused: Bool
    @Environment(\.typingFocus) private var typingFocus
    @Environment(\.pendingAction) private var pending
    @Environment(\.colorScheme) private var scheme

    init(block: SingleChoiceBlock, submit: @escaping (CallModel, [String: String]) -> Void) {
        self.block = block
        self.submit = submit
        _choice = State(initialValue: SingleChoice(block))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            VStack(alignment: .leading, spacing: Prism.Spacing.s13) {
                if !block.rationale.isEmpty {
                    Text("Why: " + block.rationale).prism(Prism.Typography.caption).foregroundStyle(muted)
                }
                VStack(alignment: .leading, spacing: Prism.Spacing.s2) {
                    ForEach(Array(choice.choices.enumerated()), id: \.element.id) { offset, item in
                        ChoiceRow(choice: item, selected: offset == choice.selected, numberWidth: numberWidth) {
                            apply(choice.choose(item))
                        }
                    }
                }
                if let selected = choice.selectedChoice {
                    ChoiceMeaning(choice: selected)
                }
                if let noting = choice.noting {
                    noteForm(noting)
                }
                if !choice.typed.isEmpty {
                    Text("Choice \(choice.typed) — press Return to choose it, Esc to cancel.")
                        .prism(Prism.Typography.caption).foregroundStyle(muted)
                }
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
            guard let key = Self.key(press), let outcome = choice.press(key) else { return .ignored }
            apply(outcome)
            return .handled
        }
        .onAppear { focused = true }
        .onDisappear { typingFocus?.blur(token) }
        .onChange(of: focused) { _, now in tellFocus(now) }
        .onChange(of: choice) { _, _ in tellFocus(focused) }
        .onChange(of: block) { _, new in choice.update(new) }
        .onChange(of: choice.noting?.option.answer) { _, answer in
            if answer == nil { focused = true } else { noteFocused = true }
        }
    }

    /// The bar: white on primary's shade (white on primary itself is under 4.5:1).
    private var bar: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s15) {
            Text("◆ YOUR DECISION").prism(Prism.Typography.labelSmall).fixedSize()
            Text(block.question).prism(Prism.Typography.label)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Room for the widest number, so the choices' texts line up.
    private var numberWidth: CGFloat {
        CGFloat(choice.choices.map(\.number.count).max() ?? 1) * 9
    }

    /// The keys there are, in one line.
    private var keys: String {
        var keys = ["↑↓ choose", "Return answer"]
        if let first = choice.choices.first?.number, let last = choice.choices.last?.number {
            keys.append(choice.multiDigit ? "type a number, Return answer" : first == last ? "\(first) answer" : "\(first)–\(last) answer")
        }
        if choice.choices.first?.recommended == true { keys.append("0 recommended") }
        // Each key with its meaning stays on one line.
        return keys.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "  ·  ")
    }

    /// The view's identity on a page: its path and the block's revision.
    nonisolated static func identity(path: String, block: SingleChoiceBlock) -> [String] { [path, block.revision] }

    private func noteForm(_ item: SingleChoice.Choice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Say why (required):").prism(Prism.Typography.labelSmall)
            TextField("Your note", text: $choice.note, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .focused($noteFocused)
            HStack {
                Button(item.option.text) { apply(choice.giveNote()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice.note.allSatisfy(\.isWhitespace))
                Button("Cancel") { choice.cancelNote() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func tellFocus(_ focused: Bool) {
        if focused { typingFocus?.focus(token, choice) } else { typingFocus?.blur(token) }
    }

    private func apply(_ outcome: SingleChoice.Outcome) {
        if case .submit(let call, let values) = outcome { submit(call, values) }
    }

    private static func key(_ press: KeyPress) -> SingleChoice.Key? {
        switch press.key {
        case .return: return .enter
        case .escape: return .escape
        case .upArrow: return .up
        case .downArrow: return .down
        default:
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  press.characters.count == 1, let c = press.characters.first,
                  c.isASCII, c.isNumber
            else { return nil }
            return .digit(c)
        }
    }
}

/// One choice, one row: the marker (▸ on the selected one), its number, its text, and at
/// the right what sets it apart: the recommended one, one given with a note (a decline).
/// The selected row has Prism's selection tint. A click answers it.
struct ChoiceRow: View {
    let choice: SingleChoice.Choice
    let selected: Bool
    let numberWidth: CGFloat
    let choose: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s10) {
                Text(selected ? "▸" : " ").bold().frame(width: Prism.Spacing.s10)
                Text(choice.number).monospaced().bold()
                    .frame(width: numberWidth, alignment: .trailing)
                Text(choice.option.text).bold(selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let label {
                    RoleTag(text: label.text, role: label.role, tint: label.tint)
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
        .background(Prism.Colors.row(scheme, selected: selected, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .onHover { hovering = $0 }
        .accessibilityLabel("Choice \(choice.number)\(label.map { ", " + $0.text } ?? ""): \(choice.option.text)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var label: (text: String, role: Color, tint: Color)? {
        if choice.recommended { return ("★ recommended", Prism.Colors.success, Prism.Colors.successLight) }
        if choice.needsNote { return ("decline · note", Prism.Colors.warning, Prism.Colors.warningLight) }
        return nil
    }
}

/// A short word that sets a row apart ("★ recommended"): grey1 on the role's light tint,
/// readable in either appearance, the role's colour as its border; the words say it, not
/// the colour.
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

/// What the selected choice means, framed, without a title: its rule and what then
/// follows, each under a muted label; for one given with a note (a decline), or one with
/// neither, its details.
struct ChoiceMeaning: View {
    let choice: SingleChoice.Choice
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let parts = [("Rule", choice.option.rule), ("Then", choice.option.consequences)]
            .map { ($0, $1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
        let details = choice.option.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parts.isEmpty, !choice.needsNote {
            Grid(alignment: .topLeading, horizontalSpacing: Prism.Spacing.s13, verticalSpacing: Prism.Spacing.s6) {
                ForEach(parts, id: \.0) { label, text in
                    GridRow {
                        Text(label).foregroundStyle(Prism.Colors.muted(scheme))
                        Text(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .modifier(Framed())
        } else if !details.isEmpty {
            Text(details).frame(maxWidth: .infinity, alignment: .leading).modifier(Framed())
        }
    }
}

/// A framed text without a title, in caption type; the border grey, or `border`.
struct Framed: ViewModifier {
    var border: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .prism(Prism.Typography.caption)
            .textSelection(.enabled)
            .padding(Prism.Spacing.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Prism.radius)
                .strokeBorder(border ?? (scheme == .dark ? Prism.Colors.grey2 : Prism.Colors.grey3)))
    }
}
