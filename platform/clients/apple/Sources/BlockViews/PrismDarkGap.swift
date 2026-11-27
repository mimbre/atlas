import Prism
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

    /// A button's icon: Prism's primary in light, the readable tint of it in dark.
    static func icon(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.primary, dark: accentText(scheme))
    }

    /// Prism's selection tint for a row: primarylight under dark text in light; in dark
    /// primary, faint, so light text stays legible.
    static func row(_ scheme: ColorScheme, selected: Bool, hovering: Bool) -> Color {
        if selected { return pick(scheme, light: Prism.Colors.primarylight, dark: Prism.Colors.primary.opacity(0.35)) }
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

    /// A recessed card: grey5; a step below the page in dark.
    static func recessed(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey5, dark: Color(white: 0.08))
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
        pick(scheme, light: Prism.Colors.grey1, dark: Prism.Colors.primarylight)
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
            return pick(scheme, light: Prism.Colors.primarylight, dark: Prism.Colors.primary.opacity(0.3))
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

    /// The sidebar's ground: white, as Next's side panel; the system's background in dark.
    static func sidebarGround(_ scheme: ColorScheme) -> Color {
        card(scheme)
    }

    /// The sidebar's selection pill: a soft grey4; a faint white in dark. Hovered: grey6.
    static func sidebarPill(_ scheme: ColorScheme, selected: Bool, hovering: Bool) -> Color {
        if selected { return pick(scheme, light: Prism.Colors.grey4, dark: Color.white.opacity(0.12)) }
        if hovering { return pick(scheme, light: Prism.Colors.grey6, dark: Color.white.opacity(0.05)) }
        return .clear
    }

    /// A sidebar tab's icon: grey2 (a lighter grey in dark); the selected tab's in primary
    /// (its tint in dark).
    static func sidebarIcon(_ scheme: ColorScheme, selected: Bool) -> Color {
        selected
            ? pick(scheme, light: Prism.Colors.primary, dark: accentText(scheme))
            : pick(scheme, light: Prism.Colors.grey2, dark: Color(white: 0.6))
    }

    /// A plain count's badge: grey4 under `text`; a faint white in dark. A count for you is
    /// primary under white in both.
    static func plainBadge(_ scheme: ColorScheme) -> Color {
        pick(scheme, light: Prism.Colors.grey4, dark: Color.white.opacity(0.14))
    }

    /// A Prism button's style in this appearance: Prism's own, but a `plain` one in dark,
    /// whose grey1 label is unreadable on a dark surface: Prism's plain look with the label
    /// in `text` (white). `icon`: the label holds its icon before its title (Prism's
    /// with-icon look). Always Prism's `small` size: one button size, no larger than the
    /// running text it acts on.
    static func buttonStyle(_ variant: PrismButtonVariant, tone: PrismButtonTone, padded: Bool, loading: Bool,
                            icon: Bool = false, scheme: ColorScheme) -> AnyButtonStyle {
        scheme == .dark && variant == .plain
            ? AnyButtonStyle(PlainInDark(padded: padded, loading: loading, icon: icon))
            : AnyButtonStyle(PrismButtonStyle(variant, tone: tone, size: .small, padded: padded, loading: loading,
                                              icon: icon ? .start : nil))
    }

    /// Prism's `Tag` in its tone at about the height of a `labelsmall` line (Prism's Tag has
    /// one size, 28pt, too tall for a line of meta text): its look with less padding, enough
    /// above and below for the text to sit inside. Until Prism's Tag has `size: small`.
    @MainActor static func smallTag(_ text: String, tone: PrismTagTone) -> some View {
        var looks = PrismTagLooks(tone: tone)
        looks.label.padding = .init(top: 3, leading: 7, bottom: 3, trailing: 7)
        looks.label.typography = Prism.Typography.labelsmall
        return Text(text)
            .prismLook(looks.label)
            .fixedSize()
    }

    private struct PlainInDark: ButtonStyle {
        let padded: Bool
        let loading: Bool
        let icon: Bool

        func makeBody(configuration: Configuration) -> some View {
            var looks = PrismButtonLooks(.plain, size: .small, padded: padded, withIcon: icon, pressed: configuration.isPressed,
                                         loading: loading)
            looks.root.foreground = PrismDarkGap.text(.dark)
            return label(configuration, looks)
                .overlay { if loading { ProgressView().progressViewStyle(.prism(.inverse, size: .size20)) } }
                .prismText(looks.root)
                .prismBox(looks.root)
        }

        /// The caller's label as is: an icon button's label already holds its icon
        /// (`PrismActionButton`), so splitting it as a `Label` showed the icon twice.
        private func label(_ configuration: Configuration, _ looks: PrismButtonLooks) -> some View {
            configuration.label.prismLook(looks.label)
        }
    }

    #if canImport(AppKit)
    private static let systemBackground = Color(nsColor: .controlBackgroundColor)
    #else
    private static let systemBackground = Color(uiColor: .secondarySystemBackground)
    #endif
}

extension Color {
    /// A colour of Atlas's own, by its hex value (Prism's is internal to it).
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Any `ButtonStyle`, so a view can choose one by appearance.
struct AnyButtonStyle: ButtonStyle {
    private let body: (Configuration) -> AnyView

    init<Style: ButtonStyle>(_ style: Style) {
        body = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { body(configuration) }
}
