import AtlasControlKit
import SwiftUI

/// A page: its title and its blocks. Its lists' rows are the page's selection: selecting
/// one (a click, or the arrow keys) calls `open` with its `to`, and the row whose `to` is
/// `selectedPath` shows selected. `act` is called with an action a block declares (its
/// button). Under a block are only its own actions; the page's (`PageActions.ofPage`) are
/// in the header, the page's title with them, when `header` is set, else where the page's
/// container puts them (the window's toolbar). A page with a panel (`hasPanel`) has no
/// header: the panel names what it is about, and its buttons are the page's actions. A page
/// with a `header` block (`hasHeader`) has that in place of its own: the page's actions
/// beside its title. Its `text` and `answers` blocks are on the page too, each `instruction`
/// and each `option` in a card of its own.
public struct PageView: View {
    let presentation: PagePresentation
    let pageActions: [ActionModel]
    let header: Bool
    let selectedPath: String?
    let open: (String) -> Void
    let act: (ActionModel) -> Void

    public init(page: PageMessage, header: Bool = false, selectedPath: String? = nil,
                open: @escaping (String) -> Void,
                act: @escaping (ActionModel) -> Void = { _ in }) {
        presentation = PagePresentation(page)
        pageActions = PageActions.ofPage(page)
        self.header = header
        self.selectedPath = selectedPath
        self.open = open
        self.act = act
    }

    /// The page in the room its column gives it: at most `Prism.readableWidth` wide,
    /// centred; its details, when it has them, under what is decided as one recessed card
    /// (`RecessedCard`), at any width.
    public var body: some View {
        list(lines(presentation.groups, header: header)
             + (presentation.details.map { [Line(id: "\u{0}details", content: .details($0))] } ?? []))
            .frame(maxWidth: Prism.readableWidth)
            .frame(maxWidth: .infinity)
            .navigationTitle(presentation.title)
    }

    private func list(_ lines: [Line]) -> some View {
        // The list selects a row by its id (the line's), never by a tag inside it; the row
        // selected is the first whose `to` is `selectedPath`, and selecting one opens its `to`.
        List(selection: Binding(
            get: { lines.first { $0.to != nil && $0.to == selectedPath }?.id },
            set: { id in
                if let to = lines.first(where: { $0.id == id })?.to, to != selectedPath { open(to) }
            })) {
            // One flat run of rows, each with an id of its own: the list keeps a row's view
            // by its id, so two lists' rows must never share one (a second list showed the
            // first one's rows).
            ForEach(lines) { line in
                switch line.content {
                case .header:
                    still(PageHeader(title: presentation.title, actions: pageActions, act: act))
                case .title(let title):
                    still(Text(title).prism(Prism.Typography.title7).padding(.top, Prism.Spacing.s10))
                case .empty(let empty):
                    still(Text(empty).prism(Prism.Typography.caption).foregroundStyle(.secondary))
                case .row(let row):
                    RowLabel(row: row).listRowSeparator(.hidden)
                case .actions(let actions):
                    still(ActionsView(actions: actions, act: act))
                case .entry(let entry):
                    still(entryView(entry))
                case .section(let section):
                    still(sectionView(section))
                case .cards(let items):
                    still(CardStack(items: items, act: act))
                case .details(let details):
                    still(detailsView(details))
                }
            }
        }
        .listStyle(.inset)
    }

    /// A row of the page's list: the page's header, a list block's title, its empty text,
    /// one of its rows (the page's selection), its actions; cards that follow each other
    /// (steps, options: one stack); or any other block, or a section, as one row.
    private struct Line: Identifiable {
        enum Content {
            case header
            case title(String)
            case empty(String)
            case row(RowModel)
            case actions([ActionModel])
            case entry(PagePresentation.Entry)
            case cards([PagePresentation.Item])
            case section(PagePresentation.Section)
            case details(PagePresentation.Details)
        }

        let id: String
        let content: Content

        /// The page a row opens; nil for any other line.
        var to: String? {
            if case .row(let row) = content { row.to } else { nil }
        }
    }

    /// The details, in one recessed card under the page: their title, small, then their
    /// blocks, without cards of their own (no card inside a card).
    private func detailsView(_ details: PagePresentation.Details) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
            Text(details.title).prism(Prism.Typography.labelSmall)
                .accessibilityAddTraits(.isHeader)
            ForEach(details.groups) { group in
                switch group {
                case .entry(let entry): entryView(entry, inDetails: true)
                case .section(let section): sectionView(section, inDetails: true)
                }
            }
        }
        .modifier(RecessedCard())
    }

    /// The rows of `groups`, top down, each id made of its block's (the header's, which no
    /// block's id can be, its own); cards that follow each other are one row, by the first's.
    private func lines(_ groups: [PagePresentation.Group], header: Bool) -> [Line] {
        var blocks: [Line] = []
        for group in groups {
            switch group {
            case .section(let section):
                blocks.append(Line(id: group.id, content: .section(section)))
            case .entry(let entry) where CardStack.stacks(entry.item):
                if let last = blocks.last, case .cards(let cards) = last.content {
                    blocks[blocks.count - 1] = Line(id: last.id, content: .cards(cards + [entry.item]))
                } else {
                    blocks.append(Line(id: group.id, content: .cards([entry.item])))
                }
            case .entry(let entry):
                switch entry.item {
                case .list(let list):
                    if let title = list.title { blocks.append(Line(id: group.id + "/title", content: .title(title))) }
                    if list.rows.isEmpty, let empty = list.empty {
                        blocks.append(Line(id: group.id + "/empty", content: .empty(empty)))
                    }
                    for (offset, row) in list.rows.enumerated() {
                        blocks.append(Line(id: group.id + "/row/\(offset)", content: .row(row)))
                    }
                    let actions = PageActions.ofBlock(list.actions)
                    if !actions.isEmpty {
                        blocks.append(Line(id: group.id + "/actions", content: .actions(actions)))
                    }
                default:
                    blocks.append(Line(id: group.id, content: .entry(entry)))
                }
            }
        }
        let own = header && !presentation.hasPanel && !presentation.hasHeader
        return own ? [Line(id: "\u{0}header", content: .header)] + blocks : blocks
    }

    /// The page's actions a panel shows at its bottom: on a page with a header, which a
    /// page with a panel leaves out (but for a `header` block, which has them).
    private var panelActions: [ActionModel] {
        header && presentation.hasPanel && !presentation.hasHeader ? pageActions : []
    }

    /// The page's actions a `header` block shows beside its title, in place of the page's
    /// own header.
    private var headerActions: [ActionModel] {
        header ? pageActions : []
    }

    /// A row of the page that is not one of its selection.
    private func still(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionDisabled()
            .listRowSeparator(.hidden)
    }

    @ViewBuilder private func entryView(_ entry: PagePresentation.Entry, inDetails: Bool = false) -> some View {
        switch entry.item {
        case .list(let list): ListBlockView(list: list, selectedPath: selectedPath, open: open, act: act)
        case .item(let item): ItemBlockView(item: item, inDetails: inDetails, act: act)
        case .option(let option): OptionView(block: option, act: act)
        case .panel(let panel):
            // A view of its own per page: a selection never stays for another page.
            PanelView(block: panel, others: panelActions, open: open, act: act).id(presentation.path)
        case .header(let block): HeaderBlockView(block: block, actions: headerActions, act: act)
        case .text(let text): TextBlockView(block: text)
        case .instruction(let instruction): InstructionView(block: instruction)
        case .answers(let answers): AnswersView(block: answers, quiet: presentation.hasOptions, act: act)
        // A page that asks is shown over the window (ActionPageView), not in a column.
        case .form: FallbackView(type: "form", reason: nil)
        case .confirm: FallbackView(type: "confirm", reason: nil)
        case .notShown(let type): FallbackView(type: type, reason: nil)
        case .fallback(let fallback): FallbackView(type: fallback.type, reason: fallback.reason)
        }
    }

    private func blocks(_ section: PagePresentation.Section, inDetails: Bool) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            ForEach(section.entries) { entryView($0, inDetails: inDetails) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sectionView(_ section: PagePresentation.Section, inDetails: Bool = false) -> some View {
        if section.collapsible {
            DisclosureGroup(isExpanded: expansion(section)) {
                blocks(section, inDetails: inDetails).padding(.top, Prism.Spacing.s10)
            } label: {
                Text(section.title).prism(Prism.Typography.label)
            }
        } else {
            VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
                Text(section.title).prism(Prism.Typography.label)
                    .accessibilityAddTraits(.isHeader)
                Divider()
                blocks(section, inDetails: inDetails)
            }
        }
    }

    /// Unfolded sections, keyed by page path and start block: another page's section,
    /// or this one after the app restarts, starts folded.
    @State private var expanded: Set<String> = []

    private func expansion(_ section: PagePresentation.Section) -> Binding<Bool> {
        let key = presentation.path + "\u{0}" + section.id
        return Binding(get: { expanded.contains(key) },
                       set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
}

/// Shared bounded summaries. Full values stay in the received model and item detail.
struct ListBlockView: View {
    let list: ListBlock
    let selectedPath: String?
    let open: (String) -> Void
    let act: (ActionModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s3) {
            if let title = list.title {
                Text(title).prism(Prism.Typography.title7)
                    .padding(.bottom, Prism.Spacing.s5)
            }
            if list.rows.isEmpty, let empty = list.empty {
                Text(empty).prism(Prism.Typography.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(list.rows.enumerated()), id: \.offset) { _, row in
                ListRowView(row: row, selected: row.to == selectedPath, open: open)
            }
            ActionsView(actions: PageActions.ofBlock(list.actions), act: act)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ListRowView: View {
    let row: RowModel
    let selected: Bool
    let open: (String) -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The button owns its padded rectangle. Future nested controls must be
        // siblings of this button, with no overlay or parent tap gesture.
        Button { open(row.to) } label: {
            RowLabel(row: row)
                .padding(.horizontal, Prism.Spacing.s10)
                .padding(.vertical, Prism.Spacing.s9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Prism.Colors.row(scheme, selected: selected, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: Prism.radius))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: Prism.radius / 2).fill(Prism.Colors.primary)
                    .frame(width: Prism.Spacing.s3)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A row's content: where its work stands (a dot in the colour of Control's `tone`), its
/// id (the item's key; a row without one has no id column at all), how long it has been
/// where it stands (its age, from `since`), its label, its detail, and whether a write to
/// it is being processed. The id, the age and the detail have narrow columns of a fixed
/// width, so rows line up; the label has the rest, on one line ending in … when it is
/// longer (its page shows it whole), with the whole of it in a tooltip. A done row is muted.
struct RowLabel: View {
    let row: RowModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let tone = RowTone(row.tone)
        // Muted text that keeps 4.5:1; inside the list's emphasized selection the system's
        // own secondary colour, which stays legible on it.
        let quiet = prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Prism.Colors.muted(scheme))
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s13) {
            if row.tone != nil || row.since != nil {
                Circle().fill(tone.map(Self.colour) ?? .clear)
                    .frame(width: Prism.Spacing.s9, height: Prism.Spacing.s9)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .help(tone?.meaning ?? "")
                    .accessibilityLabel(tone?.meaning ?? "")
                    .accessibilityHidden(tone == nil)
            }
            if let id = row.id {
                Text(id).monospaced().prism(Prism.Typography.tableRow).foregroundStyle(.secondary)
                    .lineLimit(1).frame(width: 100, alignment: .leading)
            }
            if row.tone != nil || row.since != nil {
                Text(RowAge.text(since: row.since, now: Date()) ?? "")
                    .prism(Prism.Typography.tableRow).monospacedDigit()
                    .foregroundStyle(quiet)
                    .lineLimit(1).frame(width: 44, alignment: .trailing)
            }
            Text(row.label).prism(Prism.Typography.tableRow)
                .foregroundStyle(tone == .done ? quiet : AnyShapeStyle(.primary))
                .lineLimit(1)
                .help(row.label)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            if let detail = row.detail {
                Text(detail).prism(Prism.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(width: 110, alignment: .leading)
            }
            if row.pending == true {
                Text("⋯ being processed").prism(Prism.Typography.captionSmall)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tone's colour: needs you error red, under way warning orange, waiting primary
    /// blue, done success green. Never the only sign: the row's words say it too.
    static func colour(_ tone: RowTone) -> Color {
        switch tone {
        case .attention: Prism.Colors.error
        case .active: Prism.Colors.warning
        case .waiting: Prism.Colors.primary
        case .done: Prism.Colors.success
        }
    }
}

/// A calm card (Prism). Blank labels are prose. Nil values use the TUI's absent-value marker.
/// Text stays literal, selectable and unbounded, including embedded blank lines. In the
/// page's details (`inDetails`) it has no card of its own (the details' recessed card holds
/// it): a small heading, the values smaller and muted, so the panel above keeps the focus.
struct ItemBlockView: View {
    let item: ItemBlock
    var inDetails = false
    let act: (ActionModel) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let content = VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
            Text(item.title).prism(inDetails ? Prism.Typography.labelSmall : Prism.Typography.title7)
            // The actions first: the next step is in reach without scrolling.
            ActionsView(actions: PageActions.ofBlock(item.actions), act: act)
            ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: Prism.Spacing.s3) {
                    if !field.label.isEmpty {
                        Text(field.label).prism(inDetails ? Prism.Typography.captionSmall : Prism.Typography.labelSmall)
                            .foregroundStyle(inDetails ? AnyShapeStyle(Prism.Colors.muted(scheme)) : AnyShapeStyle(.secondary))
                    }
                    Text(field.value ?? "—").prism(inDetails ? Prism.Typography.caption : Prism.Typography.tableRow)
                        .foregroundStyle(inDetails ? AnyShapeStyle(Prism.Colors.muted(scheme)) : AnyShapeStyle(.primary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let links = item.links, !links.isEmpty {
                Text("Links are not supported in this client yet.").foregroundStyle(.secondary)
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Text("\(link.label): \(link.url)")
                }
            }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        if inDetails {
            content
        } else {
            content.modifier(PrismCard())
        }
    }
}

/// A block that is not shown: its type, and why when it could not be read.
struct FallbackView: View {
    let type: String?
    let reason: Fallback.Reason?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: reason == nil ? "square.dashed" : "exclamationmark.triangle")
            Text(type ?? "?").monospaced()
            if let reason {
                Text(reason.description)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}
