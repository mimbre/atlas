import AtlasControlKit
import SwiftUI

/// A page: its title and its blocks. `open` is called with a row's `to`; `submit` with a
/// call a block declares (a choice's answer) and its values.
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
        ScrollView {
            VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
                ForEach(presentation.groups) { group in
                    switch group {
                    case .entry(let entry): entryView(entry)
                    case .section(let section): sectionView(section)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(presentation.title)
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
            // A calm row has no id: then there is no id column at all.
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
            .padding(.horizontal, Prism.Spacing.s10)
            .padding(.vertical, Prism.Spacing.s9)
            .frame(maxWidth: .infinity, alignment: .leading)
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
