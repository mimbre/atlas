import Prism
import CoreGraphics

/// The window's columns, left to right against each other, never centred: the sidebar, the
/// index page's list, the opened page's main blocks, and its details (`PagePresentation.details`)
/// as a column of their own beside them when there is room; what is left over is only at the
/// far right, after the last column. Narrower, the details go under the main blocks; narrower
/// still the sidebar folds away (as Mail's does), reachable by the sidebar toggle. macOS's
/// split view folds only the sidebar: `.detailOnly` does not hide its middle column.
public enum WindowLayout {
    /// The sidebar, fixed: room for the longest work tab's label beside its icon, chevron
    /// and count ("Supervised by you   12") without cutting it.
    public static let sidebar: CGFloat = 240
    /// The index page's list, fixed: room for a row's key, title (two lines) and to-do.
    public static let list: CGFloat = 360
    /// The opened page's main blocks, at most 100 characters of the body font wide.
    public static let page: CGFloat = 100 * Prism.characterWidth
    /// The least room the opened page gets beside the sidebar and list before the sidebar folds away.
    public static let pageMin: CGFloat = 480
    /// The details' own column, growing with the room from its least to the main blocks' most.
    public static let detailsMin: CGFloat = 280
    public static let detailsMax: CGFloat = page

    /// The opened page's columns in its column `width` wide: the main blocks' width and,
    /// when the details fit beside them, the details' width (else they go under the main blocks).
    public struct Columns: Equatable {
        public let page: CGFloat
        public let details: CGFloat?
    }

    public static func columns(width: CGFloat) -> Columns {
        guard width >= page + detailsMin else { return Columns(page: min(width, page), details: nil) }
        return Columns(page: page, details: min(width - page, detailsMax))
    }

    /// Whether a window `width` wide shows the sidebar beside the list and the opened page.
    public static func showsSidebar(window width: CGFloat) -> Bool {
        width >= sidebar + list + pageMin
    }
}
