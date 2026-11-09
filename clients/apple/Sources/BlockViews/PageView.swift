import AtlasControlKit
import SwiftUI

/// A page: its title and its blocks. `open` is called with a row's `to`.
public struct PageView: View {
    let presentation: PagePresentation
    let selectedPath: String?
    let open: (String) -> Void

    public init(page: PageMessage, selectedPath: String? = nil, open: @escaping (String) -> Void) {
        presentation = PagePresentation(page)
        self.selectedPath = selectedPath
        self.open = open
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(presentation.entries) { entry in
                    switch entry.item {
                    case .list(let list): ListBlockView(list: list, selectedPath: selectedPath, open: open)
                    case .item(let item): ItemBlockView(item: item)
                    case .notShown(let type): FallbackView(type: type, reason: nil)
                    case .fallback(let fallback): FallbackView(type: fallback.type, reason: fallback.reason)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(presentation.title)
    }
}

/// Shared bounded summaries. Full values stay in the received model and item detail.
struct ListBlockView: View {
    let list: ListBlock
    let selectedPath: String?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = list.title {
                Text(title).font(.headline)
            }
            if list.rows.isEmpty, let empty = list.empty {
                Text(empty).foregroundStyle(.secondary)
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

    var body: some View {
        // The button owns its padded rectangle. Future nested controls must be
        // siblings of this button, with no overlay or parent tap gesture.
        Button { open(row.to) } label: {
            HStack(alignment: .top, spacing: 12) {
                if let id = row.id {
                    Text(id).monospaced().foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                }
                Text(row.label).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = row.detail {
                    Text(detail).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if row.pending == true {
                    Text("⋯ being processed").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.18) :
                        (hovering ? Color.primary.opacity(0.06) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Blank labels are prose. Nil values use the TUI's absent-value marker.
/// Text stays literal, selectable and unbounded, including embedded blank lines.
struct ItemBlockView: View {
    let item: ItemBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.headline)
            ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 2) {
                    if !field.label.isEmpty {
                        Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(field.value ?? "—")
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
