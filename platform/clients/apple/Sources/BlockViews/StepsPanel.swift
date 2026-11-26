import AtlasControlKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A `steps` block as it is worked through: where each step stands (done, the current
/// one, later), the action a key takes, and what Copy copies. Control moves the step (its
/// actions keyed `Enter`, `Down` and `Up`); the app decides nothing about it.
public struct StepsPanel: Sendable, Equatable {
    public enum Place: Sendable, Equatable {
        case done
        case current
        case later
    }

    /// A key, as the panel takes it while it has the focus.
    public enum Key: Sendable, Equatable {
        case enter
        case up
        case down

        /// The key of the action Control declares for it.
        var name: String {
            switch self {
            case .enter: "Enter"
            case .up: "Up"
            case .down: "Down"
            }
        }
    }

    public let block: StepsBlock

    public init(_ block: StepsBlock) { self.block = block }

    public var count: Int { block.steps.count }

    /// The step its owner is at; nil once every step is done.
    public var current: InstructionStepModel? { block.steps.first { $0.n == block.current } }

    public func place(_ step: InstructionStepModel) -> Place {
        step.n < block.current ? .done : step.n == block.current ? .current : .later
    }

    /// "step 2 of 5", or, past the last, "all 5 steps done".
    public var progress: String {
        current == nil ? "all \(count) step\(count == 1 ? "" : "s") done" : "step \(block.current) of \(count)"
    }

    /// The action `key` takes, as Control declares it; nil when there is none (no next
    /// step after the last, no previous before the first).
    public func action(_ key: Key) -> ActionModel? {
        block.actions?.first { $0.key == key.name && $0.submitTo != nil }
    }

    /// The commands of the current step, one per line: what Copy all copies.
    public var allCommands: String? {
        guard let commands = current?.commands, !commands.isEmpty else { return nil }
        return commands.joined(separator: "\n")
    }

    /// "Why: …", with how long it has been theirs (`since`, at `now`), when either is known.
    public func whyLine(now: Date) -> String? {
        let age = block.since.flatMap { Self.age(since: $0, now: now) }
        switch (block.why, age) {
        case let (why?, age?): return "Why: \(why) · \(age)"
        case let (why?, nil): return "Why: \(why)"
        case let (nil, age?): return age
        case (nil, nil): return nil
        }
    }

    /// A step's first line: what a step not open shows.
    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// How long ago `since` (ISO 8601) was: "just now", "5m ago", "3h ago", "2d ago".
    static func age(since: String, now: Date) -> String? {
        guard let at = ISO8601DateFormatter().date(from: since) else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(at) / 60))
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes)m ago"
        case ..<(60 * 24): return "\(minutes / 60)h ago"
        default: return "\(minutes / (60 * 24))d ago"
        }
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
