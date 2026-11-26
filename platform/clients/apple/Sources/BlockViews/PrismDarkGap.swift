import SwiftUI

/// Prism has no dark tokens (it is designing them). Until it ships them, this is the one
/// place Atlas says what a colour becomes in dark appearance: each slot is Prism's token (or
/// the shade of it Atlas needs for contrast) in light, and Atlas's stopgap in dark. No view
/// picks a colour by appearance itself. Temporary: delete this file when Prism has dark
/// tokens, and use those.
enum PrismDarkGap {
    private static func pick(_ scheme: ColorScheme, light: Color, dark: Color) -> Color {
        scheme == .dark ? dark : light
    }

    /// Text in Prism's grey1 (a plain button's label, a command): white in dark.
    static func text(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey1, dark: Prism.Colors.white)
    }

    /// Muted text that stays 4.5:1 on a card: grey1, softened, in light (grey2 is 2.8:1 on
    /// white); grey2 in dark.
    static func muted(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey1.opacity(0.8), dark: Prism.Colors.grey2)
    }

    /// Primary as text (an eyebrow, a focus ring): primary is 4.3:1 on white, so a shade of
    /// it in light (4.7:1 on grey5), a tint of it in dark (6.2:1 on #1E1E1E).
    static func accentText(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Color(hex: 0x3A66DB), dark: Color(hex: 0x7B9AF4))
    }

    /// Prism's selection tint for a row: primarylight under dark text in light; in dark
    /// primary, faint, so light text stays legible.
    static func row(_ scheme: ColorScheme, selected: Bool, hovering: Bool) -> Color {
        if selected { return pick(scheme, light: Prism.Colors.primaryLight, dark: Prism.Colors.primary.opacity(0.35)) }
        if hovering { return pick(scheme, light: Prism.Colors.grey5, dark: Color.primary.opacity(0.06)) }
        return .clear
    }

    /// A calm card: white; the system's background in dark, so its text keeps the system's
    /// legible colours.
    static func card(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.white, dark: systemBackground)
    }

    /// The card a page leads with, and its shadow: white; a raised surface in dark.
    static func panelCard(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.white, dark: Color(white: 0.17))
    }

    static func panelShadow(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: .black.opacity(0.14), dark: .black.opacity(0.4))
    }

    /// A recessed card: grey5; a step below the page in dark. `error`: errorlight; a faint
    /// wash of error in dark.
    static func recessed(_ scheme: ColorScheme, error: Bool) -> Color {
        error
            ? pick(scheme, light: Prism.Colors.errorLight, dark: Prism.Colors.error.opacity(0.14))
            : pick(scheme, light: Prism.Colors.grey5, dark: Color(white: 0.08))
    }

    /// A framed value: grey6; a faint lift in dark.
    static func framed(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey6, dark: Color.white.opacity(0.05))
    }

    /// A command's inset and its edge: grey5 with grey4; a step below the card in dark.
    static func inset(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey5, dark: Prism.Colors.grey1)
    }

    static func insetEdge(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey4, dark: Color.white.opacity(0.08))
    }

    /// A route's part: grey1 on white with a grey3 edge; primarylight on a faint primary in
    /// dark, without an edge.
    static func routeText(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey1, dark: Prism.Colors.primaryLight)
    }

    static func routeFill(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.white, dark: Prism.Colors.primary.opacity(0.35))
    }

    static func routeEdge(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey3, dark: .clear)
    }

    /// The list's ground under its row cards: grey5; a dark ground in dark.
    static func listGround(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey5, dark: Color(white: 0.118))
    }

    /// A list row's card, a little lighter than the ground: white (a raised surface in
    /// dark). Selected while the list has the focus: primarylight (a faint primary in dark);
    /// selected without it: calm grey4; hovered: grey6 (a touch lighter in dark).
    static func listCard(_ scheme: ColorScheme, selected: Bool, focused: Bool, hovering: Bool) -> Color {
        if selected && focused {
            return pick(scheme, light: Prism.Colors.primaryLight, dark: Prism.Colors.primary.opacity(0.3))
        }
        if selected { return pick(scheme, light: Prism.Colors.grey4, dark: Color(white: 0.27)) }
        if hovering { return pick(scheme, light: Prism.Colors.grey6, dark: Color(white: 0.21)) }
        return pick(scheme, light: Prism.Colors.white, dark: Color(white: 0.17))
    }

    /// A selected card's thin border: primary while the list has the focus (the accent's
    /// tint in dark, ≥ 3:1 on the card), else grey3 (a faint white in dark).
    static func listCardEdge(_ scheme: ColorScheme, focused: Bool) -> Color {
        focused
            ? pick(scheme, light: Prism.Colors.primary, dark: accentText(scheme))
            : pick(scheme, light: Prism.Colors.grey3, dark: Color.white.opacity(0.18))
    }

    /// A card's top line, ≥ 4.5:1 on every card fill: grey1 softened, a little lighter on
    /// a selected card; a light grey in dark, a little lighter when selected.
    static func listMuted(_ scheme: ColorScheme, selected: Bool) -> Color {
        pick(scheme, light: Prism.Colors.grey1.opacity(selected ? 0.7 : 0.8),
             dark: Color(white: selected ? 0.75 : 0.7))
    }

    #if canImport(AppKit)
    private static let systemBackground = Color(nsColor: .controlBackgroundColor)
    #else
    private static let systemBackground = Color(uiColor: .secondarySystemBackground)
    #endif
}
