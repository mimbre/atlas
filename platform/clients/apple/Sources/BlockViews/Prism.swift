import Prism
import SwiftUI

// Prism's tokens and components come from its package (Package.swift pins the release).
// Here only what Atlas lays on top of them: the page's measure, Prism's radius in points
// for SwiftUI's shapes, a typography and a shadow as SwiftUI modifiers, and Atlas's cards.
// Dark appearance, which Prism has no tokens for yet, is PrismDarkGap.swift's alone.
extension Prism {
    /// `Radii.default` (0.25rem) in points, for SwiftUI's shapes.
    static let radius: CGFloat = 4

    /// One character of the body font (`Typography.bodysmall`), on average: the unit of
    /// an opened page's layout, the TUI's in characters (docs/design/clients.md, Layout A).
    static let characterWidth: CGFloat = 7.2
}

extension View {
    /// A Prism typography: its font, weight and line height. Every text of Atlas's own views
    /// is in one (docs/design/clients.md, Typography; `TypographyTests` keeps it so).
    public func prism(_ typography: PrismTypography) -> some View {
        prismText(PrismLook(typography: typography))
    }

    /// A Prism shadow under a view; SwiftUI's radius is half Prism's blur.
    func prismShadow(_ shadow: PrismShadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.blur / 2, x: shadow.x, y: shadow.y)
    }
}

/// A calm card (`PrismDarkGap.card`).
struct PrismCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(Prism.Spacing.px15)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The shadow is the card's alone (not its text's or sections'), with room around
            // it so no column, list row or scroll edge cuts it off.
            .background {
                RoundedRectangle(cornerRadius: Prism.radius)
                    .fill(PrismDarkGap.card(scheme))
                    .prismShadow(Prism.Shadows.prismCard)
            }
            .padding(.horizontal, Prism.Spacing.px13)
            .padding(.top, Prism.Spacing.px9)
            .padding(.bottom, Prism.Spacing.px19)
    }
}

/// The card of the panel a page leads with: white in light, a raised surface in dark,
/// rounded, with a soft shadow a little stronger than `PrismCard`'s, cast by the card alone
/// (not by what is on it). While the panel has the keys' focus (`PanelKeys`), a thin ring
/// in the accent's text colour marks it (≥ 3:1 on the card); a click in it gives it the focus.
/// Not `focusable` (a step's card), it takes no keys: no ring, and a click gives it nothing.
/// Without `room`, whatever stacks it gives the room for its shadow (`ShadowRoom`).
struct PanelCard: ViewModifier {
    var focusable = true
    var room = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelKeys) private var panelKeys

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Prism.radius * 2)
        let card = content
            .padding(Prism.Spacing.px18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(PrismDarkGap.panelCard(scheme))
                    .prismShadow(PrismShadow(color: PrismDarkGap.panelShadow(scheme), y: 5, blur: 24))
            }
            .overlay {
                if focusable, panelKeys?.focus == .panel {
                    shape.strokeBorder(PrismDarkGap.accentText(scheme), lineWidth: 1.5)
                }
            }
            .contentShape(shape)
            .simultaneousGesture(TapGesture().onEnded { if focusable { panelKeys?.focusPanel() } })
        if room { card.modifier(ShadowRoom()) } else { card }
    }
}

/// Room for a `PanelCard`'s shadow on every side, so no column, list row or scroll edge
/// cuts it off.
struct ShadowRoom: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Prism.Spacing.px15)
            .padding(.top, Prism.Spacing.px10)
            .padding(.bottom, Prism.Spacing.px22)
    }
}

/// The card of the page's details under the panel, recessed: no shadow and no stroke, on
/// a light grey surface (grey5 in light, a step below the page in dark), as wide as the
/// panel's card above it.
struct RecessedCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(Prism.Spacing.px15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Prism.radius * 2))
            .padding(.horizontal, Prism.Spacing.px15)
    }

    private var fill: Color { PrismDarkGap.recessed(scheme) }
}
