import AtlasControlKit
import Foundation
import Observation

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

/// A column of the window that the arrows can go to: the middle list or the page's panel.
public enum KeyColumn: Sendable, Equatable {
    case list
    case panel

    /// The column a key code's arrow gives the focus to: ← 123 the list, → 124 the panel.
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .list
        case 124: self = .panel
        default: return nil
        }
    }
}

/// Where ↑, ↓ and Return go, as in the TUI: to the focused column. The list has the focus
/// at first and keeps it when a page with a panel opens (a move in the list opens the next
/// row's page); → gives it to the panel on screen, ← back to the list, and a click in the
/// panel gives it to the panel. The panel that has the keys is the one that claimed them
/// last and is still shown. `moved` tells the app, so it moves the window's own focus
/// (the list's rows look focused only while the list has it).
@MainActor
@Observable
public final class PanelKeys {
    /// What a key does on the panel: true when it took it. `isRepeat`: the key is held down.
    public typealias Handler = @MainActor (PanelKey, _ isRepeat: Bool) -> Bool

    public private(set) var focus: KeyColumn = .list
    @ObservationIgnored public var moved: (@MainActor (KeyColumn) -> Void)?
    @ObservationIgnored private var claims: [(owner: AnyHashable, handler: Handler)] = []

    public init() {}

    /// `owner`'s panel takes the keys from now on, with `handler`. Another panel than the
    /// one shown (a newly opened page's) leaves the focus to the list.
    public func claim(_ owner: AnyHashable, _ handler: @escaping Handler) {
        let shown = claims.last?.owner == owner
        claims.removeAll { $0.owner == owner }
        claims.append((owner, handler))
        if !shown { move(.list) }
    }

    /// `owner`'s panel is gone; the one shown before it, if still claimed, has them again.
    /// Without a panel the list has the focus.
    public func release(_ owner: AnyHashable) {
        claims.removeAll { $0.owner == owner }
        if claims.isEmpty { move(.list) }
    }

    /// The panel takes the focus (→, a click in it), when there is one. A click tells the
    /// app also when the panel had it already: the click may have put the window's focus on
    /// the page's list around the panel.
    public func focusPanel() {
        guard !claims.isEmpty else { return }
        if focus == .panel { moved?(.panel) } else { move(.panel) }
    }

    /// The list takes the focus (a click in it).
    public func focusList() { move(.list) }

    /// ← or →: whether it moved the focus (a held one moves it once, and only between a
    /// list and a panel there is).
    public func press(column: KeyColumn, isRepeat: Bool) -> Bool {
        guard column != focus, column == .list || !claims.isEmpty else { return false }
        if !isRepeat { move(column) }
        return true
    }

    /// ↑, ↓ or Return, to the panel when it has the focus: whether it took it. With the
    /// list focused it is the list's.
    public func press(_ key: PanelKey, isRepeat: Bool) -> Bool {
        guard focus == .panel else { return false }
        return claims.last?.handler(key, isRepeat) ?? false
    }

    private func move(_ column: KeyColumn) {
        guard focus != column else { return }
        focus = column
        moved?(column)
    }
}

/// A `panel` block as it is read and answered: where its owner decides (to accept, to
/// merge). The arrows move the selection of its items and Return opens the selected one's
/// page; its answers are buttons. An answer is taken as the page's action of the same key:
/// its call when it has one (`submit_to`), else its page (`to`; a note's form for a no).
/// The app decides nothing about an answer: the order and the keys are Control's.
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
    /// The place of the selected item.
    public private(set) var selected = 0

    public init(_ block: PanelBlock) {
        self.block = block
    }

    public var items: [PanelItemModel] { block.items ?? [] }
    public var answers: [PanelAnswerModel] { block.answers ?? [] }

    /// The item whose details show; nil without items.
    public var selectedItem: PanelItemModel? {
        items.indices.contains(selected) ? items[selected] : nil
    }

    /// Control sent the block again: the same item (by key) stays selected.
    public mutating func update(_ block: PanelBlock) {
        guard block != self.block else { return }
        let was = selectedItem?.key
        self.block = block
        selected = was.flatMap { key in items.firstIndex { $0.key == key } } ?? 0
    }

    /// A key the panel takes: what it does, or nil when it leaves it to the view below
    /// (nothing to select). The arrows move the selection, not past the first or last;
    /// Return opens the selected item, once: held down (`isRepeat`) it does nothing more.
    public mutating func press(_ key: PanelKey, isRepeat: Bool = false) -> Outcome? {
        guard !items.isEmpty else { return nil }
        switch key {
        case .up:
            selected = max(selected - 1, 0)
            return .nothing
        case .down:
            selected = min(selected + 1, items.count - 1)
            return .nothing
        case .enter:
            if isRepeat { return .nothing }
            guard let item = selectedItem else { return nil }
            return item.to.map { .open($0) } ?? .nothing
        }
    }

    /// Select this item (a click); a click on the selected one opens it.
    public mutating func click(item: PanelItemModel) -> Outcome {
        guard let index = items.firstIndex(of: item) else { return .nothing }
        if index == selected { return item.to.map { .open($0) } ?? .nothing }
        selected = index
        return .nothing
    }

    /// Answer this answer (a click or its key).
    public func answer(_ answer: PanelAnswerModel) -> Outcome {
        .act(Self.action(answer))
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
            guard let url = link.url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased())
            else { return nil }
            return (link, url)
        }
    }

    /// The byline in one line, its parts joined by " · ": a part with `since` says how long
    /// ago that was after its text ("waiting 3h"; the age alone when the text is empty).
    public static func byline(_ clauses: [ClauseModel], now: Date) -> String {
        clauses.compactMap { clause -> String? in
            let age = clause.since.flatMap { since in Self.age(since: since, now: now) }
            let parts = [clause.text ?? "", age ?? ""].filter { !$0.isEmpty }
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
}
