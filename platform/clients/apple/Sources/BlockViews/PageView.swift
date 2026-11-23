import AtlasControlKit
import SwiftUI

/// A page: its title and its blocks. Its lists' rows are the page's selection: selecting
/// one (a click, or the arrow keys) calls `open` with its `to`, and the row whose `to` is
/// `selectedPath` shows selected. `submit` is called with a call a block declares (a
/// choice's answer) and its values.
public struct PageView: View {
    let presentation: PagePresentation
    let selectedPath: String?
    let open: (String) -> Void
    let submit: (CallModel, [String: String]) -> Void

    public init(page: PageMessage, selectedPath: String? = nil, open: @escaping (String) -> Void,
                submit: @escaping (CallModel, [String: String]) -> Void = { _, _ in }) {
        presentation = PagePresentation(page)
        self.selectedPath = selectedPath
        self.open = open
        self.submit = submit
    }

    public var body: some View {
        let lines = lines
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
                case .title(let title):
                    still(Text(title).prism(Prism.Typography.title7).padding(.top, Prism.Spacing.s10))
                case .empty(let empty):
                    still(Text(empty).prism(Prism.Typography.caption).foregroundStyle(.secondary))
                case .row(let row):
                    RowLabel(row: row).listRowSeparator(.hidden)
                case .actions(let actions):
                    still(UnsupportedActionsView(actions: actions))
                case .entry(let entry):
                    still(entryView(entry))
                case .section(let section):
                    still(sectionView(section))
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(presentation.title)
    }

    /// A row of the page's list: a list block's title, its empty text, one of its rows (the
    /// page's selection), its actions; or any other block, or a section, as one row.
    private struct Line: Identifiable {
        enum Content {
            case title(String)
            case empty(String)
            case row(RowModel)
            case actions([ActionModel])
            case entry(PagePresentation.Entry)
            case section(PagePresentation.Section)
        }

        let id: String
        let content: Content

        /// The page a row opens; nil for any other line.
        var to: String? {
            if case .row(let row) = content { row.to } else { nil }
        }
    }

    /// The page's rows, top down, each id made of its block's.
    private var lines: [Line] {
        presentation.groups.flatMap { group -> [Line] in
            switch group {
            case .section(let section):
                return [Line(id: group.id, content: .section(section))]
            case .entry(let entry):
                guard case .list(let list) = entry.item else {
                    return [Line(id: group.id, content: .entry(entry))]
                }
                var lines: [Line] = []
                if let title = list.title { lines.append(Line(id: group.id + "/title", content: .title(title))) }
                if list.rows.isEmpty, let empty = list.empty {
                    lines.append(Line(id: group.id + "/empty", content: .empty(empty)))
                }
                for (offset, row) in list.rows.enumerated() {
                    lines.append(Line(id: group.id + "/row/\(offset)", content: .row(row)))
                }
                if let actions = list.actions, !actions.isEmpty {
                    lines.append(Line(id: group.id + "/actions", content: .actions(actions)))
                }
                return lines
            }
        }
    }

    /// A row of the page that is not one of its selection.
    private func still(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionDisabled()
            .listRowSeparator(.hidden)
    }

    @ViewBuilder private func entryView(_ entry: PagePresentation.Entry) -> some View {
        switch entry.item {
        case .list(let list): ListBlockView(list: list, selectedPath: selectedPath, open: open)
        case .item(let item): ItemBlockView(item: item)
        case .singleChoice(let choice):
            // A view of its own per page and revision: nothing typed for one
            // decision stays for another.
            SingleChoiceView(block: choice, submit: submit)
                .id(SingleChoiceView.identity(path: presentation.path, block: choice))
        case .notShown(let type): FallbackView(type: type, reason: nil)
        case .fallback(let fallback): FallbackView(type: fallback.type, reason: fallback.reason)
        }
    }

    private func blocks(_ section: PagePresentation.Section) -> some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            ForEach(section.entries) { entryView($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sectionView(_ section: PagePresentation.Section) -> some View {
        if section.collapsible {
            DisclosureGroup(isExpanded: expansion(section)) {
                blocks(section).padding(.top, Prism.Spacing.s10)
            } label: {
                Text(section.title).prism(Prism.Typography.label)
            }
        } else {
            VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
                Text(section.title).prism(Prism.Typography.label)
                    .accessibilityAddTraits(.isHeader)
                Divider()
                blocks(section)
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
            UnsupportedActionsView(actions: list.actions ?? [])
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
        .background(background, in: RoundedRectangle(cornerRadius: Prism.radius))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: Prism.radius / 2).fill(Prism.Colors.primary)
                    .frame(width: Prism.Spacing.s3)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Prism's selection tint: primarylight under dark text in light appearance; in dark
    /// appearance primary, faint, so light text stays legible.
    private var background: Color {
        let dark = scheme == .dark
        if selected { return dark ? Prism.Colors.primary.opacity(0.35) : Prism.Colors.primaryLight }
        if hovering { return dark ? Color.primary.opacity(0.06) : Prism.Colors.grey5 }
        return .clear
    }
}

/// A row's content: its id (a calm row has none, and then there is no id column at all),
/// its label, its detail, and whether a write to it is being processed.
struct RowLabel: View {
    let row: RowModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Prism.Spacing.s13) {
            if let id = row.id {
                Text(id).monospaced().prism(Prism.Typography.tableRow).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 120, alignment: .leading)
            }
            Text(row.label).prism(Prism.Typography.tableRow).foregroundStyle(.primary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail = row.detail {
                Text(detail).prism(Prism.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
}

/// A calm card (Prism). Blank labels are prose. Nil values use the TUI's absent-value marker.
/// Text stays literal, selectable and unbounded, including embedded blank lines.
struct ItemBlockView: View {
    let item: ItemBlock

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s10) {
            Text(item.title).prism(Prism.Typography.title7)
            ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: Prism.Spacing.s3) {
                    if !field.label.isEmpty {
                        Text(field.label).prism(Prism.Typography.labelSmall).foregroundStyle(.secondary)
                    }
                    Text(field.value ?? "—").prism(Prism.Typography.tableRow)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            UnsupportedActionsView(actions: item.actions ?? [])
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
        .modifier(PrismCard())
    }
}

struct UnsupportedActionsView: View {
    let actions: [ActionModel]

    var body: some View {
        if !actions.isEmpty {
            Text("Actions are not supported in this client yet: " + actions.map(\.label).joined(separator: ", "))
                .font(.callout).foregroundStyle(.secondary)
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
