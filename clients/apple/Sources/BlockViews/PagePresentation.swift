import AtlasControlKit

/// How a page's blocks are shown, block by block, in the order Control sent them. A block
/// this slice does not show yet, or one the package could not decode, is a fallback with
/// its type (and its reason, when it has one); the rest of the page still shows.
public struct PagePresentation: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        /// A list: its rows open the page they name.
        case list(ListBlock)
        /// Read-only detail, including full multiline field values.
        case item(ItemBlock)
        /// A single choice: its options are chosen by number or click.
        case singleChoice(SingleChoiceBlock)
        /// A block of a type this app knows but does not show yet.
        case notShown(type: String)
        /// A block that cannot be shown: unknown or broken.
        case fallback(Fallback)
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        /// The block's id, else its position.
        public var id: String
        public var item: Item
    }

    public var title: String
    /// The page's path.
    public var path: String
    public var entries: [Entry]

    public init(_ page: PageMessage) {
        title = page.title
        path = page.path
        entries = page.blocks.enumerated().compactMap { offset, block in
            let item: Item
            switch block.content {
            case .list(let list): item = .list(list)
            case .item(let detail): item = .item(detail)
            case .singleChoice(let choice): item = .singleChoice(choice)
            case .fallback(let fallback): item = .fallback(fallback)
            case .consoleAction: return nil  // the Console's actions: ConsoleKit, S5
            default: item = .notShown(type: block.type ?? "")
            }
            return Entry(id: block.id ?? "#\(offset)", item: item)
        }
    }
}
