import AtlasControlKit

/// A `single_choice` block as it is chosen from, by key or by click: what Control sent,
/// numbered, the choice selected (the arrows move it, Return answers it; the recommended
/// one at first), and what choosing does. Choosing submits exactly the option's `answer`, the
/// call Control projects for it; an option given with a note (a decline) first asks for
/// the note, as Control's own answer form does. The app decides nothing about an option:
/// the order, the recommendation and the shortcuts are Control's.
public struct SingleChoice: Sendable, Equatable {
    public struct Choice: Sendable, Equatable, Identifiable {
        public var id: String { option.id }
        /// The number it is chosen with: the option's shortcut, else its place from 1.
        public var number: String
        public var option: ChoiceOptionModel
        /// The option Control recommends (it sends it first).
        public var recommended: Bool
        /// It is given with a note saying why.
        public var needsNote: Bool { option.note == true }
    }

    /// A key, as the block takes it while it has the focus.
    public enum Key: Sendable, Equatable {
        case digit(Character)
        case enter
        case escape
        case up
        case down
    }

    /// What a key or a click does.
    public enum Outcome: Sendable, Equatable {
        case nothing
        /// Send this call with these values.
        case submit(CallModel, values: [String: String])
        /// The note form opened for this choice.
        case askNote(Choice)
    }

    /// The name Control's answer form gives the note (its `note` input).
    static let noteName = "note"

    public private(set) var block: SingleChoiceBlock
    public private(set) var choices: [Choice]
    /// The choice whose note form is open.
    public private(set) var noting: Choice? {
        didSet { if noting?.option.answer != oldValue?.option.answer { note = "" } }
    }
    /// The note typed into the open form; empty whenever the form closes or another opens.
    public var note = ""
    /// The number typed so far, when a choice takes more than one digit.
    public private(set) var typed = ""
    /// The place of the choice Return answers.
    public private(set) var selected = 0

    public init(_ block: SingleChoiceBlock) {
        self.block = block
        choices = Self.choices(block)
        selected = Self.recommended(choices)
    }

    /// The choice Return answers; nil only without choices.
    public var selectedChoice: Choice? { choices.indices.contains(selected) ? choices[selected] : nil }

    /// Control sent the block again: the note form, and its note, stay only while the new
    /// block has an option with exactly the same answer call (the call names the decision),
    /// so a note never carries over to another decision.
    public mutating func update(_ block: SingleChoiceBlock) {
        guard block != self.block else { return }
        self.block = block
        let was = selectedChoice?.id
        choices = Self.choices(block)
        noting = noting.flatMap { old in choices.first { $0.option.answer == old.option.answer } }
        typed = ""
        selected = choices.firstIndex { $0.id == was } ?? Self.recommended(choices)
    }

    /// Numbers of more than one digit are typed, then confirmed with Enter.
    public var multiDigit: Bool { choices.contains { $0.number.count > 1 } }

    /// `0` is the recommended choice 1 again; another number chooses its choice. The arrows
    /// move the selection (not past the first or last), Return chooses the selected choice
    /// (or, while a number of more than one digit is typed, that number's). A number no
    /// choice has, or a key while the note form is open, does nothing (Esc closes it).
    public mutating func key(_ key: Key) -> Outcome {
        if noting != nil {
            if key == .escape { noting = nil }
            return .nothing
        }
        switch key {
        case .escape:
            typed = ""
            return .nothing
        case .digit(let digit):
            guard digit.isASCII, digit.isNumber else { return .nothing }
            guard multiDigit else { return choose(number: String(digit)) }
            typed.append(digit)
            return .nothing
        case .enter:
            guard typed.isEmpty else {
                let number = typed
                typed = ""
                return choose(number: number)
            }
            guard let choice = selectedChoice else { return .nothing }
            return choose(choice)
        case .up, .down:
            typed = ""
            guard !choices.isEmpty else { return .nothing }
            selected = key == .up ? max(selected - 1, 0) : min(selected + 1, choices.count - 1)
            return .nothing
        }
    }

    /// A key the block has the focus for: what it does, or nil when the block leaves it to
    /// the view below (the note field while its form is open, or a key that does nothing
    /// with no number being typed). The arrows are the block's while it has choices, also
    /// at the first or last, so they never move the selection of the list around it, and
    /// they never answer. A key held down (`isRepeat`) only moves the selection: Return or
    /// a digit answers once.
    public mutating func press(_ key: Key, isRepeat: Bool = false) -> Outcome? {
        guard noting == nil else { return nil }
        if key == .up || key == .down { return choices.isEmpty ? nil : self.key(key) }
        if isRepeat { return .nothing }
        let wasTyping = !typed.isEmpty
        let outcome = self.key(key)
        if outcome == .nothing, !wasTyping, typed.isEmpty { return nil }
        return outcome
    }

    /// Whether the block, with the focus, takes this key (one character) itself, before
    /// the page's action keys: a digit that chooses or goes on typing a number. With more
    /// than nine choices every digit is typed; else only a digit some choice has (and `0`).
    /// Not while the note form is open (the note field has the keys).
    public func takes(_ key: String) -> Bool {
        guard noting == nil, key.count == 1, let c = key.first, c.isASCII, c.isNumber, !choices.isEmpty else { return false }
        if multiDigit || !typed.isEmpty || c == "0" { return true }
        return choices.contains { $0.number == String(c) }
    }

    /// Choose this choice (a click, its number, or Return); it becomes the selected one.
    public mutating func choose(_ choice: Choice) -> Outcome {
        guard let index = choices.firstIndex(of: choice) else { return .nothing }
        let choice = choices[index]
        typed = ""
        selected = index
        if choice.needsNote {
            noting = choice
            return .askNote(choice)
        }
        return .submit(choice.option.answer, values: [:])
    }

    /// Give the note the open form asks for; a note that is blank is not given.
    public mutating func giveNote(_ note: String) -> Outcome {
        guard let choice = noting, !note.allSatisfy(\.isWhitespace) else { return .nothing }
        noting = nil
        return .submit(choice.option.answer, values: [Self.noteName: note])
    }

    /// Give the note typed into the open form.
    public mutating func giveNote() -> Outcome { giveNote(note) }

    public mutating func cancelNote() { noting = nil }

    private mutating func choose(number: String) -> Outcome {
        let normalized = number.drop { $0 == "0" }
        // `0` (however many zeros) is the first choice, the recommended one.
        let choice = normalized.isEmpty ? choices.first : choices.first { $0.number == String(normalized) }
        guard let choice else { return .nothing }
        return choose(choice)
    }

    /// The recommended choice's place, else the first's.
    private static func recommended(_ choices: [Choice]) -> Int {
        choices.firstIndex(where: \.recommended) ?? 0
    }

    private static func choices(_ block: SingleChoiceBlock) -> [Choice] {
        block.options.enumerated().map { offset, option in
            Choice(number: option.shortcut ?? String(offset + 1), option: option,
                   recommended: option.id == block.recommended)
        }
    }
}

/// The block that types and has the focus (a `single_choice`), as the app's action keys
/// ask it: a key it takes is left to it. A view says when it has the focus and what it is
/// now, and when it loses it.
@MainActor
public final class TypingFocus {
    private var owner: AnyHashable?
    public private(set) var choice: SingleChoice?

    public init() {}

    /// `owner`'s block has the focus, as it is now.
    public func focus(_ owner: AnyHashable, _ choice: SingleChoice) {
        self.owner = owner
        self.choice = choice
    }

    /// `owner` lost the focus (another may have it already).
    public func blur(_ owner: AnyHashable) {
        guard self.owner == owner else { return }
        self.owner = nil
        choice = nil
    }

    /// Whether the focused block takes this key itself.
    public func takes(_ key: String) -> Bool { choice?.takes(key) ?? false }
}
