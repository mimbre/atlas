import AtlasControlKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A `text` block in one line: its label before it, when it has one, and how long ago `since` was
/// after it ("· 3h ago"), when Control sends them.
public enum TextLine {
    public static func line(_ block: TextBlock, now: Date) -> String {
        let shown = text(block, now: now)
        guard let label = block.label else { return shown }
        return shown.isEmpty ? label : "\(label): \(shown)"
    }

    /// Its text and how long ago, without its label (where a heading shows that).
    public static func text(_ block: TextBlock, now: Date) -> String {
        let text = block.text ?? ""
        guard let age = block.since.flatMap({ age(since: $0, now: now) }) else { return text }
        return text.isEmpty ? age : "\(text) · \(age)"
    }

    /// How long ago `since` (ISO 8601) was: "just now", "5m ago", "3h ago", "2d ago".
    static func age(since: String, now: Date) -> String? {
        Panel.age(since: since, now: now).map { $0 == "now" ? "just now" : "\($0) ago" }
    }
}

/// A header's state and its compact, current age.
public enum HeaderState {
    public static func line(_ block: HeaderBlock, now: Date) -> String? {
        let parts = [block.detail, RowAge.text(since: block.since, now: now)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// An `instruction` block's lines as they are shown: a route as its parts with › between
/// them, any other line as its text.
public enum Instruction {
    public static func shown(_ line: InstructionLineModel) -> String {
        line.kind == "route" ? (line.parts ?? []).joined(separator: " › ") : line.text ?? ""
    }
}

/// An `option` block as it is answered: its button takes its answer as the page's action of
/// the answer's key (`Panel.action`): its call at once (`submit_to`), else its page (`to`;
/// for one that asks a note, a decline, the form that asks it). Its key, as Control binds
/// it, takes the same; the recommended one (tone success) is on `0` too.
public enum Option {
    /// What its button and its key take; nil when it has no answer.
    public static func action(_ block: OptionBlock) -> ActionModel? {
        block.answer.map(Panel.action)
    }

    /// The number its card shows: none on the only proposal (`alone`), which has nothing
    /// to be told from.
    public static func number(_ block: OptionBlock) -> Int? {
        block.alone == true ? nil : block.n
    }

    /// What it means, as its card shows it: each field with a value (Rule, Consequences);
    /// one without (an alternative its proposer has not worked out yet) shows no section.
    public static func fields(_ block: OptionBlock) -> [PairModel] {
        (block.fields ?? []).filter { !($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Its answer as the page's actions: on its key, and on `0` for the recommended one.
    /// The only proposal's (`alone`) only on `0`: its key is the page's Accept.
    public static func actions(_ block: OptionBlock) -> [ActionModel] {
        guard let own = action(block) else { return [] }
        var zero = own
        zero.key = "0"
        if block.alone == true { return [zero] }
        guard block.tone == "success" else { return [own] }
        return [own, zero]
    }
}

#if canImport(AppKit)
/// Copies text for pasting elsewhere (a terminal): the general pasteboard, or another one.
@MainActor
public enum Clipboard {
    public static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
