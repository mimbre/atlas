import AtlasControlKit
import SwiftUI

/// A `single_choice` block: the question, the numbered choices (Control's order, the
/// recommended one first, with why), and Control's instructions. A click or the choice's
/// number chooses it; a choice given with a note opens a form for the note first.
/// `submit` is called with the call Control projected for the choice, and its values.
struct SingleChoiceView: View {
    let block: SingleChoiceBlock
    let submit: (CallModel, [String: String]) -> Void

    @State private var choice: SingleChoice
    @FocusState private var focused: Bool
    @FocusState private var noteFocused: Bool

    init(block: SingleChoiceBlock, submit: @escaping (CallModel, [String: String]) -> Void) {
        self.block = block
        self.submit = submit
        _choice = State(initialValue: SingleChoice(block))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(block.question).font(.headline)
            ForEach(choice.choices) { item in
                ChoiceRow(choice: item, rationale: item.recommended ? block.rationale : nil,
                          noting: choice.noting?.id == item.id) { apply(choice.choose(item)) }
                if choice.noting?.id == item.id {
                    noteForm(item)
                }
            }
            if !choice.typed.isEmpty {
                Text("Choice \(choice.typed) — press Return to choose it, Esc to cancel.")
                    .foregroundStyle(.secondary)
            }
            if let instructions = block.instructions, !instructions.isEmpty {
                Text(instructions).font(.callout).foregroundStyle(.secondary)
            }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress { press in
            guard let key = Self.key(press), let outcome = choice.press(key) else { return .ignored }
            apply(outcome)
            return .handled
        }
        .onAppear { focused = true }
        .onChange(of: block) { _, new in choice.update(new) }
        .onChange(of: choice.noting?.option.answer) { _, answer in
            if answer == nil { focused = true } else { noteFocused = true }
        }
    }

    /// The view's identity on a page: its path and the block's revision.
    nonisolated static func identity(path: String, block: SingleChoiceBlock) -> [String] { [path, block.revision] }

    private func noteForm(_ item: SingleChoice.Choice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Say why (required):").font(.subheadline)
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
        .padding(.leading, 36)
    }

    private func apply(_ outcome: SingleChoice.Outcome) {
        if case .submit(let call, let values) = outcome { submit(call, values) }
    }

    private static func key(_ press: KeyPress) -> SingleChoice.Key? {
        switch press.key {
        case .return: return .enter
        case .escape: return .escape
        default:
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  press.characters.count == 1, let c = press.characters.first,
                  c.isASCII, c.isNumber
            else { return nil }
            return .digit(c)
        }
    }
}

/// One choice: its number, its text, and what it means; the recommended one says so,
/// and why.
struct ChoiceRow: View {
    let choice: SingleChoice.Choice
    let rationale: String?
    let noting: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Text(choice.number).monospaced().bold()
                    .frame(minWidth: 24, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(choice.option.text).bold()
                        if choice.recommended {
                            Text("Recommended").font(.caption.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                    if let rationale, !rationale.isEmpty {
                        Text("Why: " + rationale).foregroundStyle(.secondary)
                    }
                    if !choice.option.details.isEmpty {
                        Text(choice.option.details)
                    }
                    if !choice.option.rule.isEmpty {
                        Text("Rule: " + choice.option.rule).foregroundStyle(.secondary)
                    }
                    if !choice.option.consequences.isEmpty {
                        Text("Consequences: " + choice.option.consequences).foregroundStyle(.secondary)
                    }
                    if choice.needsNote {
                        Text("Asks for a note saying why.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(noting ? Color.accentColor.opacity(0.18) :
                        (hovering ? Color.primary.opacity(0.06) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .onHover { hovering = $0 }
        .accessibilityLabel("Choice \(choice.number)\(choice.recommended ? ", recommended" : ""): \(choice.option.text)")
    }
}
