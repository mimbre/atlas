import Foundation

/// Where a list row's work stands for the viewer (Control's `tone`), one meaning on every
/// list: Control decides it, the app only shows it. A tone this app does not know, or none,
/// is no tone: the row shows no dot.
public enum RowTone: String, Sendable, Equatable {
    /// The next step is the viewer's.
    case attention
    /// Under way: someone else, or an agent, is at it.
    case active
    /// Planned, or waiting on someone or something else.
    case waiting
    case done

    public init?(_ tone: String?) {
        guard let tone, let known = RowTone(rawValue: tone) else { return nil }
        self = known
    }

    /// What the dot means, in words (its colour never says it alone).
    public var meaning: String {
        switch self {
        case .attention: "Needs you"
        case .active: "Under way"
        case .waiting: "Waiting on someone else"
        case .done: "Done"
        }
    }
}

/// How long a row has been where it stands (Control's `since`, ISO 8601), compact, as the
/// TUI says it: `15d`, `6h`, `46m`, `today` (under a minute); nil without a readable time.
public enum RowAge {
    public static func text(since: String?, now: Date) -> String? {
        guard let since, let at = date(since) else { return nil }
        let seconds = max(Int(now.timeIntervalSince(at)), 0)
        switch seconds {
        case 86_400...: return "\(seconds / 86_400)d"
        case 3_600...: return "\(seconds / 3_600)h"
        case 60...: return "\(seconds / 60)m"
        default: return "today"
        }
    }

    private static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        // Control's times may carry fractions of a second.
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// The words of a list row's card (the Mac list): a top line, what the row is (its item's
/// kind and key, `DECISION · D-0104`); its title on at most `titleLines` lines; then where it
/// stands (Control's `detail`, the row's state; none when Control sends none, as when the
/// whole list shares it).
public enum RowCardText {
    public static let titleLines = 2

    /// The kind (in capitals, as small caps) and the key; whichever Control sends.
    public static func kindAndKey(kind: String?, id: String?) -> String? {
        let parts = [kind.map { $0.uppercased() }, id].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The row's state, or nil when it has none.
    public static func state(_ detail: String?) -> String? {
        guard let detail, !detail.isEmpty else { return nil }
        return detail
    }
}
