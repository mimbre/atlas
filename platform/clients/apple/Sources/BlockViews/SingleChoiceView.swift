import AtlasControlKit
import ControlSession
import SwiftUI

/// A `single_choice` block as a panel that asks for a decision, in the panel's card
/// (`PanelCard`): the eyebrow over the question with its key, why the recommendation, the
/// choices in Control's order (the recommended one first), one aligned row each, the
/// selected one on a light background, what it means (its rule and what then follows; a
/// decline's details) under them, and the page's other actions (`others`, More…). ↑ ↓
/// move the selection and Return answers it (`PanelKeys`, wherever the focus is; held
/// down, the arrows only move it); a click or the choice's number answers that choice; a
/// choice given with a note opens a form for the note first. `submit` is called with the
/// call Control projected for the choice, and its values. With the focus it tells
/// `typingFocus` which digits are its own, so the page's action keys leave them to it;
/// once a choice is sent, it says so until Control answers.
struct SingleChoiceView: View {
    let block: SingleChoiceBlock
    let others: [ActionModel]
    let act: (ActionModel) -> Void
    let submit: (CallModel, [String: String]) -> Void

    @State private var choice: SingleChoice
    @State private var token = UUID()
    @FocusState private var focused: Bool
    @FocusState private var noteFocused: Bool
    @Environment(\.typingFocus) private var typingFocus
    @Environment(\.panelKeys) private var panelKeys
    @Environment(\.pendingAction) private var pending
    @Environment(\.colorScheme) private var scheme

    init(block: SingleChoiceBlock, others: [ActionModel] = [], act: @escaping (ActionModel) -> Void = { _ in },
         submit: @escaping (CallModel, [String: String]) -> Void) {
        self.block = block
        self.others = others
        self.act = act
        self.submit = submit
        _choice = State(initialValue: SingleChoice(block))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            PanelHeading(eyebrow: "YOUR DECISION", title: block.question, key: block.key, trailing: nil)
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
            if !others.isEmpty {
                FlowLayout(spacing: Prism.Spacing.s10) {
                    ForEach(Array(others.enumerated()), id: \.offset) { _, action in
                        KeyButton(label: action.label, key: action.key) { act(action) }
                    }
                }
                .textSelection(.disabled)
            }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelCard())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress { press in
            guard let key = Self.key(press), let outcome = choice.press(key, isRepeat: press.phase == .repeat)
            else { return .ignored }
            apply(outcome)
            return .handled
        }
        .onAppear {
            focused = true
            claim()
        }
        .onDisappear {
            typingFocus?.blur(token)
            panelKeys?.release(token)
        }
        .onChange(of: focused) { _, now in tellFocus(now) }
        .onChange(of: choice) { _, _ in tellFocus(focused) }
        .onChange(of: block) { _, new in choice.update(new) }
        .onChange(of: choice.noting?.option.answer) { _, answer in
            if answer == nil { focused = true } else { noteFocused = true }
        }
    }

    /// ↑ ↓ and Return, wherever the focus is in the window: the arrows only ever move the
    /// selection; Return answers the selected choice, once. While the note form is open
    /// they are the note field's.
    private func claim() {
        panelKeys?.claim(token) { [$choice, submit] key, isRepeat in
            let key: SingleChoice.Key = switch key {
            case .up: .up
            case .down: .down
            case .enter: .enter
            }
            guard let outcome = $choice.wrappedValue.press(key, isRepeat: isRepeat) else { return false }
            if case .submit(let call, let values) = outcome { submit(call, values) }
            return true
        }
    }

    private var muted: Color { Prism.Colors.muted(scheme) }

    /// Room for the widest number, so the choices' texts line up.
    private var numberWidth: CGFloat {
        CGFloat(choice.choices.map(\.number.count).max() ?? 1) * 9
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

/// One choice, one row: its number, its text, and at the right what sets it apart: the
/// recommended one, one given with a note (a decline). The selected row is on Prism's
/// selection tint; hovering one shows it takes a click. A click answers it.
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
                Text(choice.number).monospaced()
                    .foregroundStyle(Prism.Colors.muted(scheme))
                    .frame(width: numberWidth, alignment: .trailing)
                Text(choice.option.text).bold(selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let label {
                    RoleTag(text: label.text, role: label.role, tint: label.tint)
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
        .background(Prism.Colors.row(scheme, selected: selected, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .onHover { hovering = $0 }
        .help("Answer this (\(choice.number); ↑ ↓ choose, Return answers the selected one)")
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

/// A text without a title, in caption type, on a faint surface; framed only with `border`
/// (an error), the one frame that says something.
struct Framed: ViewModifier {
    var border: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .prism(Prism.Typography.caption)
            .textSelection(.enabled)
            .padding(Prism.Spacing.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color.white.opacity(0.05) : Prism.Colors.grey6,
                        in: RoundedRectangle(cornerRadius: Prism.radius))
            .overlay(RoundedRectangle(cornerRadius: Prism.radius).strokeBorder(border ?? .clear))
    }
}
