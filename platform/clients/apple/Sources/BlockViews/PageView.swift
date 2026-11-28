import AtlasControlKit
import Prism
import SwiftUI

/// A page: its title and its blocks. Its lists' rows are the page's selection: selecting
/// one (a click, or the arrow keys) calls `open` with its `to`, and the row whose `to` is
/// `selectedPath` shows selected. `act` is called with an action a block declares (its
/// button). Under a block are only its own actions; the page's (`PageActions.ofPage`) are
/// in the header, the page's title with them, when `header` is set, else where the page's
/// container puts them (the window's toolbar). A page with a panel (`hasPanel`) has no
/// header: the panel names what it is about, and its buttons are the page's actions. A page
/// with a `header` block (`hasHeader`) has that in place of its own. Its `text` and
/// `answers` blocks are on the page too, each `instruction` and each `option` in a card of
/// its own. On the opened item (`header`) its other actions (its `actions` blocks) and its
/// answers of weight `other` are not on the page but in the window's toolbar
/// (`PageActions.toolbar`, `ItemToolbar`, put there by its container) and in its context
/// menu (`ItemActionsMenu`): its bottom keeps only the main answer and the decline. Another
/// page shows them where Control put them.
public struct PageView: View {
    let presentation: PagePresentation
    let pageActions: [ActionModel]
    /// The opened item's toolbar actions (`PageActions.toolbar`): in its context menu; none
    /// on a page that is no opened item (`header` not set).
    let itemActions: [ActionModel]
    let header: Bool
    let selectedPath: String?
    let open: (String) -> Void
    let act: (ActionModel) -> Void
    let filter: (String) -> Void
    let selectedGroup: String?
    @Environment(\.colorScheme) private var scheme
    /// Whether the list has the keys: its selected card shows Prism's tint, else calm grey.
    @FocusState private var listFocused: Bool

    public init(page: PageMessage, header: Bool = false, selectedPath: String? = nil,
                open: @escaping (String) -> Void,
                act: @escaping (ActionModel) -> Void = { _ in },
                filter: ((String) -> Void)? = nil, selectedGroup: String? = nil) {
        presentation = PagePresentation(page)
        pageActions = PageActions.ofPage(page)
        itemActions = header ? PageActions.toolbar(page) : []
        self.header = header
        self.selectedPath = selectedPath
        self.open = open
        self.act = act
        self.filter = filter ?? open
        self.selectedGroup = selectedGroup
    }

    /// The page from the left of its column (`WindowLayout.columns`): its main blocks at most
    /// `WindowLayout.page` wide, and its details, when it has them, as a column of their own right
    /// beside them when they fit, else under what is decided as one recessed card
    /// (`RecessedCard`). What is left over is at the right, after the last column.
    public var body: some View {
        GeometryReader { room in
            columns(WindowLayout.columns(width: room.size.width))
        }
        .navigationTitle(presentation.title)
    }

    @ViewBuilder
    private func columns(_ columns: WindowLayout.Columns) -> some View {
        let main = lines(presentation.groups, header: header)
        if let details = presentation.details, let width = columns.details {
            HStack(alignment: .top, spacing: 0) {
                list(main).frame(width: columns.page)
                ScrollView {
                    detailsView(details)
                        .padding(.top, Prism.Spacing.px22)
                        .padding(.bottom, Prism.Spacing.px10)
                }
                .contentMargins(.bottom, Prism.Spacing.px30, for: .scrollContent)
                .frame(width: width)
                Spacer(minLength: 0)
            }
        } else {
            list(main + (presentation.details.map { [Line(id: "\u{0}details", content: .details($0))] } ?? []))
                .frame(width: columns.page)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                switch line.content {
                case .header:
                    still(PageHeader(title: presentation.title, actions: pageActions, act: act))
                case .title(let title):
                    still(Text(title).prism(Prism.Typography.title7).padding(.top, Prism.Spacing.px10))
                case .heading(let title, let aside):
                    still(HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.px10) {
                        Text(title).prism(Prism.Typography.label).accessibilityAddTraits(.isHeader)
                        if let aside {
                            Text(aside).prism(Prism.Typography.caption).foregroundStyle(PrismDarkGap.muted(scheme))
                        }
                    }
                    .padding(.horizontal, Prism.Spacing.px15)
                    .padding(.top, Prism.Spacing.px10))
                case .empty(let empty):
                    still(Text(empty).prism(Prism.Typography.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, header ? Prism.Spacing.px15 : 0))
                case .row(let row):
                    RowCard(row: row, selected: line.to == selectedPath, focused: listFocused)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(listPage ? PrismDarkGap.listGround(scheme) : PrismDarkGap.card(scheme))
                case .actions(let actions):
                    still(ActionsView(actions: actions, act: act))
                case .entry(let entry):
                    let betweenCardsAndDetails = index > 0 && index + 1 < lines.count
                        && { if case .cards = lines[index - 1].content,
                                case .details = lines[index + 1].content { return true }
                             return false }()
                    still(entryView(entry, followsCardsBeforeDetails: betweenCardsAndDetails))
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
        .contextMenu { ItemActionsMenu(actions: itemActions, act: act) }
        // Room after the last block, so its answers and its card's shadow scroll fully into
        // view at any window height.
        .contentMargins(.bottom, Prism.Spacing.px30, for: .scrollContent)
        .focused($listFocused)
        // Only the overview list has its own ground; rows embedded in an opened page
        // share that page's background.
        .scrollContentBackground(listPage ? .hidden : .automatic)
        .background(listPage ? PrismDarkGap.listGround(scheme) : .clear)
    }

    var listPage: Bool {
        !header && !presentation.hasHeader && presentation.details == nil && !presentation.hasPanel
    }

    /// A row of the page's list: the page's header, a list block's title, its empty text,
    /// one of its rows (the page's selection), its actions; cards that follow each other
    /// (steps, options: one stack); or any other block, or a section, as one row.
    private struct Line: Identifiable {
        enum Content {
            case header
            case title(String)
            case heading(String, aside: String?)
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

    private func detailsView(_ details: PagePresentation.Details) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px10) {
            Text(details.title).prism(Prism.Typography.title6)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Prism.Spacing.px15)
            ForEach(details.groups) { group in
                switch group {
                case .entry(let entry): entryView(entry, detailHeading: true)
                case .section(let section): sectionView(section, detailHeading: true)
                }
            }
        }
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
                    if (header && list.title != nil) || list.aside != nil {
                        blocks.append(Line(id: group.id + "/title",
                                           content: .heading(list.title ?? "", aside: list.aside)))
                    } else if let title = list.title {
                        blocks.append(Line(id: group.id + "/title", content: .title(title)))
                    }
                    let rows = list.rows ?? []
                    if rows.isEmpty, let empty = list.empty {
                        blocks.append(Line(id: group.id + "/empty", content: .empty(empty)))
                    }
                    for (offset, row) in rows.enumerated() {
                        blocks.append(Line(id: group.id + "/row/\(offset)", content: .row(row)))
                    }
                    let actions = PageActions.ofBlock(list.actions)
                    if !actions.isEmpty {
                        blocks.append(Line(id: group.id + "/actions", content: .actions(actions)))
                    }
                case .actions where header:
                    break
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

    @ViewBuilder private func entryView(_ entry: PagePresentation.Entry, inDetails: Bool = false,
                                        detailHeading: Bool = false, followsCardsBeforeDetails: Bool = false) -> some View {
        switch entry.item {
        case .list(let list):
            ListBlockView(list: list, selectedPath: selectedPath, open: open, act: act)
        case .groups(let groups): GroupFilters(groups: groups, selected: selectedGroup, filter: filter)
        case .item(let item): ItemBlockView(item: item, inDetails: inDetails, detailHeading: detailHeading, act: act)
        case .option(let option): OptionView(block: option, detailHeading: detailHeading, act: act)
        case .panel(let panel):
            // A view of its own per page: a selection never stays for another page.
            PanelView(block: panel, others: panelActions, detailHeading: detailHeading, open: open, act: act).id(presentation.path)
        case .header(let block):
            HeaderBlockView(block: block, actions: headerActions, act: act)
        case .text(let text): TextBlockView(block: text)
        case .instruction(let instruction): InstructionView(block: instruction)
        case .answers(let answers):
            AnswersView(block: answers, toolbar: header, followsCardsBeforeDetails: followsCardsBeforeDetails, act: act)
        // The opened item's are in the window's toolbar.
        case .actions where header:
            EmptyView()
        case .actions(let actions):
            OtherActionsView(actions: actions.actions ?? [], act: act)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Prism.Spacing.px15)
                .padding(.bottom, Prism.Spacing.px10)
        // A page that asks is shown over the window (ActionPageView), not in a column.
        case .form: FallbackView(type: "form", reason: nil)
        case .confirm: FallbackView(type: "confirm", reason: nil)
        case .notShown(let type): FallbackView(type: type, reason: nil)
        case .fallback(let fallback):
            FallbackView(type: fallback.type, reason: fallback.reason,
                         plain: fallback.reason == .unknownType ? fallback.plain : nil)
        }
    }

    private func blocks(_ section: PagePresentation.Section, inDetails: Bool, detailHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px15) {
            ForEach(section.entries) { entryView($0, inDetails: inDetails, detailHeading: detailHeading) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionView(_ section: PagePresentation.Section, inDetails: Bool = false,
                             detailHeading: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px10) {
            Text(section.title).prism(Prism.Typography.title6)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, inDetails ? 0 : Prism.Spacing.px10)
            Divider()
            blocks(section, inDetails: inDetails, detailHeading: detailHeading)
        }
    }
}

/// Shared bounded summaries. Full values stay in the received model and item detail.
struct ListBlockView: View {
    let list: ListBlock
    let selectedPath: String?
    let open: (String) -> Void
    let act: (ActionModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px3) {
            if list.title != nil || list.aside != nil {
                HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.px10) {
                    if let title = list.title {
                        Text(title).prism(Prism.Typography.title7)
                    }
                    if let aside = list.aside {
                        Text(aside).prism(Prism.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, Prism.Spacing.px5)
            }
            if (list.rows ?? []).isEmpty, let empty = list.empty {
                Text(empty).prism(Prism.Typography.caption).foregroundStyle(.secondary)
            }
            ForEach(Array((list.rows ?? []).enumerated()), id: \.offset) { _, row in
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

    var body: some View {
        // The button owns its card. Future nested controls must be siblings of this
        // button, with no overlay or parent tap gesture.
        Button { if let to = row.to { open(to) } } label: {
            RowCard(row: row, selected: selected, focused: true)
        }
        .buttonStyle(.plain)
        .disabled(row.to == nil)
    }
}

/// A list row as a small card (the Mac list): a top line, muted, with what it is (its
/// kind's icon, `KindIcon`, and its kind and key, `DECISION · D-0104`) and, at the right,
/// how long it has been there (`3h`); under it the title on one or two lines (… only past
/// two, the whole of it in a tooltip); under that, muted, its state when Control sends one
/// (`Decide it · Deadline 2026-12-01 17:00`, on a line of its own so the kind and key never
/// crowd it out), and whether a write to it is being processed. No status dot: the state
/// says where it stands in words. The card follows its title's height and uses the same
/// compact treatment in overview and related lists.
/// Selected: Prism's light primary tint with a thin primary border, and the kind's icon in
/// primary, while the list has the focus (`focused`), calm grey without it.
struct RowCard: View {
    let row: RowModel
    let selected: Bool
    /// Whether the list the card is in has the keys.
    let focused: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Prism.radius * 2)
        content
            // Our own colours on our own card: not the List's selected (white) text.
            .environment(\.backgroundProminence, .standard)
            .padding(.horizontal, Prism.Spacing.px13)
            .padding(.vertical, Prism.Spacing.px10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(PrismDarkGap.listCard(scheme, selected: selected, focused: focused, hovering: hovering))
            }
            .overlay {
                if selected { shape.strokeBorder(PrismDarkGap.listCardEdge(scheme, focused: focused), lineWidth: 1) }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .padding(.horizontal, Prism.Spacing.px10)
            .padding(.vertical, Prism.Spacing.px3)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var content: some View {
        let tone = RowTone(row.tone)
        let top = RowCardText.top(row)
        let muted = PrismDarkGap.listMuted(scheme, selected: selected)
        return VStack(alignment: .leading, spacing: Prism.Spacing.px5) {
            // Centred: the icon sits on the middle of the line's text at any size; the line's
            // texts share one typography, so their baselines still line up.
            HStack(alignment: .center, spacing: Prism.Spacing.px6) {
                KindIcon(symbol: top.symbol, selected: selected && focused)
                Text(top.text ?? "").tracking(0.6)
                    .prism(Prism.Typography.caption)
                Spacer(minLength: Prism.Spacing.px6)
                if let age = RowAge.text(since: row.since, now: Date()) {
                    Text(age).prism(Prism.Typography.caption).monospacedDigit()
                }
            }
            .foregroundStyle(muted)
            .lineLimit(1)
            .truncationMode(.tail)
            Text(row.label ?? "")
                .prism(Prism.Typography.title7)
                .lineSpacing(Prism.Spacing.px3)
                .foregroundStyle(tone == .done ? muted : PrismDarkGap.text(scheme))
                .lineLimit(RowCardText.titleLines)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .help(row.label ?? "")
            if let state = RowCardText.state(row.detail) {
                Text(state).prism(Prism.Typography.caption).foregroundStyle(muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(state)
            }
            if row.pending == true {
                Text("⋯ being processed").prism(Prism.Typography.caption).foregroundStyle(muted)
            }
        }
    }
}

/// A kind's icon (Control's `icon`, the model's semantic name for the kind, the same as on
/// its sidebar tab), drawn as the sidebar draws it: neutral grey, primary only where it is
/// selected (a selected card while its list has the focus). `symbol` is its SF Symbol
/// (`SidebarLook.symbol`); without one, nothing in the same square, so what follows keeps its
/// place.
struct KindIcon: View {
    let symbol: String?
    var selected = false
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let symbol {
                Image(systemName: symbol).resizable().scaledToFit()
                    .foregroundStyle(PrismDarkGap.sidebarIcon(scheme, selected: selected))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A calm card (Prism). Blank labels are prose. Nil values use the TUI's absent-value marker.
/// Text stays literal, selectable and unbounded, including embedded blank lines. In the
/// page's details (`inDetails`) it has no card of its own (the details' recessed card holds
/// it): a label for its heading, the values muted, so the panel above keeps the focus.
struct ItemBlockView: View {
    let item: ItemBlock
    var inDetails = false
    var detailHeading = false
    let act: (ActionModel) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let content = VStack(alignment: .leading, spacing: Prism.Spacing.px10) {
            if let title = item.title, !title.isEmpty {
                Text(title).prism(inDetails ? Prism.Typography.label
                                  : detailHeading ? Prism.Typography.title6 : Prism.Typography.title5)
            }
            // The actions first: the next step is in reach without scrolling.
            ActionsView(actions: PageActions.ofBlock(item.actions), act: act)
            ForEach(Array((item.fields ?? []).enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: Prism.Spacing.px3) {
                    if let label = field.label, !label.isEmpty {
                        Text(label).prism(Prism.Typography.label)
                            .foregroundStyle(inDetails ? AnyShapeStyle(PrismDarkGap.muted(scheme)) : AnyShapeStyle(.secondary))
                    }
                    FormattedText(text: field.value ?? "—", format: field.format).prism(Prism.Typography.bodysmall)
                        .foregroundStyle(inDetails ? AnyShapeStyle(PrismDarkGap.muted(scheme)) : AnyShapeStyle(.primary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let links = item.links, !links.isEmpty {
                Text("Links are not supported in this client yet.").prism(Prism.Typography.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Text([link.label, link.url].compactMap { $0 }.joined(separator: ": ")).prism(Prism.Typography.bodysmall)
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

/// A block that is not shown. An unknown block shows what it says in plain words (its
/// title and lines, D-0105); otherwise, or when it says nothing, its type, and why when it
/// could not be read.
struct FallbackView: View {
    let type: String?
    let reason: Fallback.Reason?
    var plain: (title: String?, lines: [String])? = nil

    var body: some View {
        if let plain, plain.title != nil || !plain.lines.isEmpty {
            VStack(alignment: .leading, spacing: Prism.Spacing.px5) {
                if let title = plain.title {
                    Text(title).prism(Prism.Typography.title7).accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(plain.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).prism(Prism.Typography.bodysmall)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                Image(systemName: reason == nil || reason == .unknownType ? "square.dashed" : "exclamationmark.triangle")
                Text(type ?? "?").monospaced()
                if let reason, reason != .unknownType {
                    Text(reason.description)
                }
            }
            .prism(Prism.Typography.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }
}

#if DEBUG
struct NestedListPreview: PreviewProvider {
    static var previews: some View {
        let blocks: [JSONValue] = [
            .object(["id": .string("card"), "type": .string("item"), "props": .object([
                "title": .string("Decision"), "fields": .array([
                    .object(["label": .string("Status"), "value": .string("Accepted")])
                ])
            ])]),
            .object(["id": .string("verdicts"), "type": .string("list"), "props": .object([
                "rows": .array([
                    .object(["label": .string("accept_decision"), "kind": .string("Gate verdict"),
                             "key": .string("GV-0178"), "to": .string("/verdict/1")]),
                    .object(["label": .string("accept_decision"), "kind": .string("Gate verdict"),
                             "key": .string("GV-0177"), "to": .string("/verdict/2")])
                ])
            ])])
        ]
        let markup: [JSONValue] = [
            .object(["kind": .string("section"), "start": .string("verdicts"), "end": .string("verdicts"),
                     "props": .object(["title": .string("Gate verdicts")])])
        ]
        return PageView(page: PageMessage(blocks: blocks.map(Block.init(raw:)),
                                          markup: markup.map(MarkupEntry.init(raw:)),
                                          path: "/preview", title: "Decision"),
                        header: true, open: { _ in })
            .frame(width: 700, height: 500)
    }
}
#endif
