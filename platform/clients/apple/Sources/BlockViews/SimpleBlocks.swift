import AtlasControlKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A `text` block in one line: its label before it ("Why: …"), and how long ago `since` was
/// after it ("· 3h ago"), when Control sends them.
public enum TextLine {
    public static func line(_ block: TextBlock, now: Date) -> String {
        let shown = text(block, now: now)
        return block.label.map { "\($0): \(shown)" } ?? shown
    }

    /// Its text and how long ago, without its label (where a heading shows that).
    public static func text(_ block: TextBlock, now: Date) -> String {
        guard let age = block.since.flatMap({ age(since: $0, now: now) }) else { return block.text }
        return "\(block.text) · \(age)"
    }

    /// How long ago `since` (ISO 8601) was: "just now", "5m ago", "3h ago", "2d ago".
    static func age(since: String, now: Date) -> String? {
        Panel.age(since: since, now: now).map { $0 == "now" ? "just now" : "\($0) ago" }
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
    /// What its button and its key take.
    public static func action(_ block: OptionBlock) -> ActionModel {
        Panel.action(block.answer)
    }

    /// Its answer as the page's actions: on its key, and on `0` for the recommended one.
    public static func actions(_ block: OptionBlock) -> [ActionModel] {
        let own = action(block)
        guard block.tone == "success" else { return [own] }
        var zero = own
        zero.key = "0"
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
