import AtlasControlKit

/// How a page's blocks are shown, block by block, in the order Control sent them. A block
/// this slice does not show yet, or one the package could not decode, is a fallback with
/// its type (and its reason, when it has one); the rest of the page still shows.
///
/// The page's top-level `section` markup groups its blocks (`groups`): a collapsible
/// section is folded until its reader unfolds it, any other section is a heading over its
/// blocks. Other kinds of markup do not change the layout. Markup that is not one
/// well-formed tree (an unknown id, an end before its start, crossing entries, a block id
/// used twice) is left out, as the contract asks of a client, and the blocks show flat.
public struct PagePresentation: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        /// A list: its rows open the page they name.
        case list(ListBlock)
        /// Read-only detail, including full multiline field values.
        case item(ItemBlock)
        /// A panel where its owner decides: its items, checks, box and answers.
        case panel(PanelBlock)
        /// A page's header: its eyebrow and key over its title.
        case header(HeaderBlock)
        /// A line of text, with its label and how long ago, when it has them ("Why: …").
        case text(TextBlock)
        /// One numbered step of instructions, all its lines.
        case instruction(InstructionBlock)
        /// The page's answers, each on its key: the page's actions (`PageActions.all`).
        case answers(AnswersBlock)
        /// One option of a decision: what it means and its own answer.
        case option(OptionBlock)
        /// A form: its inputs, edited and submitted to its call.
        case form(FormBlock)
        /// A confirm: its text, and Confirm (its call) or Cancel.
        case confirm(ConfirmBlock)
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

    /// A titled stretch of blocks, from the section's start block to its end block.
    public struct Section: Sendable, Equatable, Identifiable {
        /// The id of its start block: with the page's path, what its fold state is kept by.
        public var id: String
        public var title: String
        /// Folded by default; the reader can unfold it.
        public var collapsible: Bool
        public var entries: [Entry]
    }

    /// One step of the page, top down: a block on its own, or a section over its blocks.
    public enum Group: Sendable, Equatable, Identifiable {
        case entry(Entry)
        case section(Section)

        public var id: String {
            switch self {
            case .entry(let entry): "block:" + entry.id
            case .section(let section): "section:" + section.id
            }
        }
    }

    public var title: String
    /// The page's path.
    public var path: String
    /// Every shown block once, in order.
    public var entries: [Entry]
    /// The same blocks, grouped by the page's top-level sections, but its details.
    public var groups: [Group]
    /// The page's details, when its markup has them: a part of role details.
    public var details: Details?

    /// The facts of the page's item, apart from what is decided on it.
    public struct Details: Sendable, Equatable {
        public var title: String
        public var groups: [Group]
    }

    /// The page shows a panel where its owner acts: it leads the page in place of its title.
    public var hasPanel: Bool {
        entries.contains { if case .panel = $0.item { true } else { false } }
    }

    /// The page is a decision with its options: they, not its `answers`, answer it.
    public var hasOptions: Bool {
        entries.contains { if case .option = $0.item { true } else { false } }
    }

    /// The page has a `header` block: it names the page in place of its title.
    public var hasHeader: Bool {
        entries.contains { if case .header = $0.item { true } else { false } }
    }

    public init(_ page: PageMessage) {
        title = page.title ?? ""
        path = page.path ?? ""
        let blocks = page.blocks ?? []
        // Positions are the page's, so markup over a block this view leaves out still lines up.
        let shown: [(position: Int, entry: Entry)] = blocks.enumerated().compactMap { offset, block in
            let item: Item
            switch block.content {
            case .list(let list): item = .list(list)
            case .item(let detail): item = .item(detail)
            case .panel(let panel): item = .panel(panel)
            case .header(let header): item = .header(header)
            case .text(let text): item = .text(text)
            case .instruction(let instruction): item = .instruction(instruction)
            case .answers(let answers): item = .answers(answers)
            case .option(let option): item = .option(option)
            case .form(let form): item = .form(form)
            case .confirm(let confirm): item = .confirm(confirm)
            case .fallback(let fallback): item = .fallback(fallback)
            case .consoleAction: return nil  // the Console's actions: ConsoleKit, S5
            case .groups: return nil  // the page's groups: the shell's sidebar (ShellViewModel)
            default: item = .notShown(type: block.type ?? "")
            }
            return (offset, Entry(id: block.id ?? "#\(offset)", item: item))
        }
        entries = shown.map(\.entry)

        let sections = Self.topLevelSections(page)
        var groups: [Group] = []
        var index = shown.startIndex
        for (range, props) in sections {
            while index < shown.endIndex, shown[index].position < range.lowerBound {
                groups.append(.entry(shown[index].entry))
                index += 1
            }
            var inside: [Entry] = []
            while index < shown.endIndex, shown[index].position <= range.upperBound {
                inside.append(shown[index].entry)
                index += 1
            }
            let start = blocks[range.lowerBound].id ?? "#\(range.lowerBound)"
            groups.append(.section(Section(id: start, title: props.title ?? "",
                                           collapsible: props.collapsible == true, entries: inside)))
        }
        groups.append(contentsOf: shown[index...].map { .entry($0.entry) })

        // The page's details (a part of role details): beside the rest or under it, as the
        // room the page gets allows (`PageView`).
        var position: [String: Int] = [:]
        for (offset, block) in blocks.enumerated() { if let id = block.id { position[id] = offset } }
        let part = (page.markup ?? []).lazy.compactMap { entry -> (ClosedRange<Int>, String)? in
            guard case .part(let props) = entry.content, props.role == "details",
                  let start = position[entry.start], let end = position[entry.end], start <= end
            else { return nil }
            return (start...end, props.title ?? "")
        }.first
        if let (range, title) = part {
            let inside = Set(shown.filter { range.contains($0.position) }.map(\.entry.id))
            let first: (Group) -> String? = {
                switch $0 {
                case .entry(let entry): entry.id
                case .section(let section): section.entries.first?.id
                }
            }
            details = Details(title: title, groups: groups.filter { first($0).map(inside.contains) ?? false })
            self.groups = groups.filter { !(first($0).map(inside.contains) ?? false) }
        } else {
            details = nil
            self.groups = groups
        }
    }

    /// The outermost sections, in block order, as ranges of block positions; none when the
    /// page's markup is not a well-formed tree.
    static func topLevelSections(_ page: PageMessage) -> [(ClosedRange<Int>, SectionMarkup)] {
        var position: [String: Int] = [:]
        for (offset, block) in (page.blocks ?? []).enumerated() {
            guard let id = block.id else { continue }
            if position.updateValue(offset, forKey: id) != nil { return [] }  // an id used twice
        }
        // Every entry of a known kind is checked, so a section is never drawn from markup
        // that is wrong elsewhere. Entries this package could not read are left out.
        var ranges: [(ClosedRange<Int>, SectionMarkup?)] = []
        for entry in page.markup ?? [] {
            let section: SectionMarkup?
            switch entry.content {
            case .fallback: continue
            case .section(let props): section = props
            case .legend, .part, .highlight: section = nil
            }
            guard let start = position[entry.start], let end = position[entry.end], start <= end
            else { return [] }
            ranges.append((start...end, section))
        }
        for (i, a) in ranges.enumerated() {
            for b in ranges[(i + 1)...] {
                let nested = a.0.contains(b.0.lowerBound) && a.0.contains(b.0.upperBound)
                    || b.0.contains(a.0.lowerBound) && b.0.contains(a.0.upperBound)
                if a.0.overlaps(b.0) && !nested { return [] }  // crossing
            }
        }
        // A section inside another section shows inside it, without a fold of its own.
        // The same stretch twice: the first in list order is outermost.
        let sections = ranges.enumerated().compactMap { order, entry in
            entry.1.map { (order: order, range: entry.0, props: $0) }
        }.sorted {
            ($0.range.lowerBound, -$0.range.upperBound, $0.order)
                < ($1.range.lowerBound, -$1.range.upperBound, $1.order)
        }
        var outermost: [(ClosedRange<Int>, SectionMarkup)] = []
        for candidate in sections where !outermost.contains(where: { $0.0.overlaps(candidate.range) }) {
            outermost.append((candidate.range, candidate.props))
        }
        return outermost
    }
}
