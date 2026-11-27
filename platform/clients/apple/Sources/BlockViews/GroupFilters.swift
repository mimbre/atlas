import AtlasControlKit
import Prism
import SwiftUI

/// The destinations and counts Control supplies on the current list page.
public struct GroupFilters: View {
    let groups: [GroupModel]
    let selected: String?
    let filter: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    public init(page: PageMessage, selected: String?, filter: @escaping (String) -> Void) {
        groups = (page.blocks ?? []).flatMap { block in
            if case .groups(let groups) = block.content { return groups.groups ?? [] }
            return []
        }
        self.selected = selected
        self.filter = filter
    }

    public var body: some View {
        if !groups.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Prism.Spacing.px10) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if let to = group.to {
                            let active = selected.map { $0 == to } ?? (group.active == true)
                            Button { filter(to) } label: {
                                let looks = pillLook(active: active)
                                Text([group.label ?? to, group.count.map(String.init)].compactMap { $0 }.joined(separator: " "))
                                    .prismLook(looks.label)
                                    .foregroundStyle(active ? PrismDarkGap.accentText(scheme) : PrismDarkGap.text(scheme))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                }
                .padding(.horizontal, Prism.Spacing.px10)
                .padding(.vertical, Prism.Spacing.px10)
            }
        }
    }

    private func pillLook(active: Bool) -> PrismTagLooks {
        var looks = PrismTagLooks(tone: active ? .accent : .neutral)
        looks.label.radius = .capsule
        return looks
    }
}
