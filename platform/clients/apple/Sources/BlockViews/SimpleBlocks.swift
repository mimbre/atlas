import AtlasControlKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A `text` block in one line: its label before it ("Why: …"), and how long ago `since` was
/// after it ("· 3h ago"), when Control sends them.
public enum TextLine {
    public static func line(_ block: TextBlock, now: Date) -> String {
        let text = block.label.map { "\($0): \(block.text)" } ?? block.text
        guard let age = block.since.flatMap({ age(since: $0, now: now) }) else { return text }
        return "\(text) · \(age)"
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
