import AtlasControlKit
import Foundation

/// A key a panel takes: the arrows and Return.
public enum PanelKey: Sendable, Equatable {
    case up
    case down
    case enter

    /// The key of a key code (`NSEvent.keyCode`): ↑ 126, ↓ 125, Return 36 or the keypad's
    /// Enter 76; nil for any other key.
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .enter
        default: return nil
        }
    }
}

/// The panel of the page on screen that takes ↑, ↓ and Return, wherever the focus is in
/// the window (a list's rows would take the arrows for themselves): the one that claimed
/// them last and is still shown. A panel claims them when it appears, so they work as
/// soon as its page opens, without a click.
@MainActor
public final class PanelKeys {
    /// What a key does on the panel: true when it took it. `isRepeat`: the key is held down.
    public typealias Handler = @MainActor (PanelKey, _ isRepeat: Bool) -> Bool

    private var claims: [(owner: AnyHashable, handler: Handler)] = []

    public init() {}

    /// `owner`'s panel takes the keys from now on, with `handler`.
    public func claim(_ owner: AnyHashable, _ handler: @escaping Handler) {
        release(owner)
        claims.append((owner, handler))
    }

    /// `owner`'s panel is gone; the one shown before it, if still claimed, has them again.
    public func release(_ owner: AnyHashable) {
        claims.removeAll { $0.owner == owner }
    }

    /// The key, to the panel that has the keys: whether it took it.
    public func press(_ key: PanelKey, isRepeat: Bool) -> Bool {
        claims.last?.handler(key, isRepeat) ?? false
    }
}

/// A `panel` block as it is read and answered: where its owner decides (to accept, to
/// merge, stuck work). Without `choose`, the arrows move the selection of its items and
/// Return opens the selected one's page; its answers are buttons. With `choose`, its
/// answers are a choice: the arrows move the selection (the recommended one at first) and
/// Return answers it. An answer is taken as the page's action of the same key: its call
/// when it has one (`submit_to`), else its page (`to`; a note's form for a no). The app
/// decides nothing about an answer: the order, the recommendation and the keys are Control's.
public struct Panel: Sendable, Equatable {
    /// What a key or a click does.
    public enum Outcome: Sendable, Equatable {
        /// Only the selection moved.
        case nothing
        /// Open this page (an item's).
        case open(String)
        /// Take this action (an answer, as the page's action of its key).
        case act(ActionModel)
    }

    public private(set) var block: PanelBlock
    /// The place of the selected item, or, when the panel is a choice, of the selected answer.
    public private(set) var selected: Int

    public init(_ block: PanelBlock) {
        self.block = block
        selected = Self.start(block)
    }

    public var choosing: Bool { block.choose == true }
    public var items: [PanelItemModel] { block.items ?? [] }
    public var answers: [PanelAnswerModel] { block.answers ?? [] }

    /// The item whose details show; nil without items, or when the panel is a choice.
    public var selectedItem: PanelItemModel? {
        guard !choosing, items.indices.contains(selected) else { return nil }
        return items[selected]
    }

    /// The answer Return takes; nil unless the panel is a choice with answers.
    public var selectedAnswer: PanelAnswerModel? {
        guard choosing, answers.indices.contains(selected) else { return nil }
        return answers[selected]
    }

    /// Control sent the block again: the same item or answer (by key) stays selected.
    public mutating func update(_ block: PanelBlock) {
        guard block != self.block else { return }
        let was = choosing ? selectedAnswer?.key : selectedItem?.key
        self.block = block
        let keys = choosing ? answers.map(\.key) : items.map(\.key)
        selected = was.flatMap { keys.firstIndex(of: $0) } ?? Self.start(block)
    }

    /// A key the panel takes: what it does, or nil when it leaves it to the view below
    /// (nothing to select). The arrows move the selection, not past the first or last, and
    /// never answer; Return opens the selected item, or answers the selected answer, once:
    /// held down (`isRepeat`) it does nothing more.
    public mutating func press(_ key: PanelKey, isRepeat: Bool = false) -> Outcome? {
        let count = choosing ? answers.count : items.count
        guard count > 0 else { return nil }
        switch key {
        case .up:
            selected = max(selected - 1, 0)
            return .nothing
        case .down:
            selected = min(selected + 1, count - 1)
            return .nothing
        case .enter:
            if isRepeat { return .nothing }
            if let answer = selectedAnswer { return self.answer(answer) }
            return selectedItem.map { .open($0.to) }
        }
    }

    /// Select this item (a click); a click on the selected one opens it.
    public mutating func click(item: PanelItemModel) -> Outcome {
        guard !choosing, let index = items.firstIndex(of: item) else { return .nothing }
        if index == selected { return .open(item.to) }
        selected = index
        return .nothing
    }

    /// Answer this answer (a click, its key, or Return on the selected one); in a choice
    /// it becomes the selected one.
    public mutating func answer(_ answer: PanelAnswerModel) -> Outcome {
        if choosing, let index = answers.firstIndex(of: answer) { selected = index }
        return .act(Self.action(answer))
    }

    /// An answer as the page's action of its key: its call, else its page (a no's: the
    /// form that asks its note).
    public static func action(_ answer: PanelAnswerModel) -> ActionModel {
        ActionModel(label: answer.label, key: answer.key, to: answer.to, submitTo: answer.submitTo)
    }

    /// Everything the panel's keys take: its answers, then its actions.
    public static func actions(_ block: PanelBlock) -> [ActionModel] {
        (block.answers ?? []).map(action) + (block.actions ?? [])
    }

    /// The links a client opens: http and https addresses only.
    public static func links(_ block: PanelBlock) -> [(link: LinkModel, url: URL)] {
        (block.links ?? []).compactMap { link in
            guard let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
            return (link, url)
        }
    }

    /// The byline in one line, its parts joined by " · ": a part with `since` says how long
    /// ago that was after its text ("waiting 3h"; the age alone when the text is empty).
    public static func byline(_ clauses: [ClauseModel], now: Date) -> String {
        clauses.compactMap { clause -> String? in
            let age = clause.since.flatMap { since in Self.age(since: since, now: now) }
            let parts = [clause.text, age ?? ""].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }.joined(separator: " · ")
    }

    /// How long ago an ISO 8601 time was, in its largest unit: "now" (under a minute),
    /// "5m", "3h", "2d"; nil when it is not a time.
    public static func age(since: String, now: Date) -> String? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        var at = format.date(from: since)
        if at == nil {
            format.formatOptions.insert(.withFractionalSeconds)
            at = format.date(from: since)
        }
        guard let at else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(at) / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }

    /// A check's state as a glyph, which carries what it says (the colour only repeats it):
    /// ✓ success, ✗ error, … pending, — not known.
    public static func glyph(_ state: String) -> String {
        switch state {
        case "success": "✓"
        case "error": "✗"
        case "pending": "…"
        default: "—"
        }
    }

    /// The recommended answer's place in a choice, else the first.
    private static func start(_ block: PanelBlock) -> Int {
        guard block.choose == true else { return 0 }
        return (block.answers ?? []).firstIndex { $0.recommended == true } ?? 0
    }
}
