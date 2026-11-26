import SwiftUI

/// Prism's design tokens as SwiftUI constants (novasoftwarefoundation/prism @370696e7,
/// `design/lib/tokens.ex`). Copied, not imported: Prism's own Swift package is iOS/UIKit only.
enum Prism {
    enum Colors {
        static let primary = Color(hex: 0x4272EF)
        static let primaryLight = Color(hex: 0xE3EAFD)
        static let secondary = Color(hex: 0xFF5E5E)
        static let tertiary = Color(hex: 0xFFCF60)
        static let success = Color(hex: 0x52BA12)
        static let successLight = Color(hex: 0xEBFFDF)
        static let warning = Color(hex: 0xF28D15)
        static let warningLight = Color(hex: 0xFFEFDC)
        static let error = Color(hex: 0xDB1E1E)
        static let errorLight = Color(hex: 0xFFECEC)
        static let grey1 = Color(hex: 0x222222)
        static let grey2 = Color(hex: 0x999999)
        static let grey3 = Color(hex: 0xCCCCCC)
        static let grey4 = Color(hex: 0xEEEEEE)
        static let grey5 = Color(hex: 0xF6F6F6)
        static let grey6 = Color(hex: 0xFAFAFA)
        static let white = Color(hex: 0xFFFFFF)
        /// Primary at 97%: the lightest shade of it under which white text is 4.5:1 (primary
        /// itself is 4.3:1), for bars with white text. As the TUI's `primaryshade`.
        static let primaryShade = Color(hex: 0x406FE8)

        /// Muted text that stays 4.5:1 on a card: grey1, softened, in light appearance
        /// (grey2 is 2.8:1 on white); grey2 in dark.
        static func muted(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? grey2 : grey1.opacity(0.8)
        }

        /// Primary as text (a panel's eyebrow): primary is 4.3:1 on white, so a shade of it
        /// in light (4.7:1 on grey5, more on white), a tint of it in dark (6.2:1 on #1E1E1E).
        static func accentText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(hex: 0x7B9AF4) : Color(hex: 0x3A66DB)
        }

        /// Prism's selection tint for a row: primarylight under dark text in light
        /// appearance; in dark appearance primary, faint, so light text stays legible.
        static func row(_ scheme: ColorScheme, selected: Bool, hovering: Bool) -> Color {
            let dark = scheme == .dark
            if selected { return dark ? primary.opacity(0.35) : primaryLight }
            if hovering { return dark ? Color.primary.opacity(0.06) : grey5 }
            return .clear
        }
    }

    /// `default` radius, 0.25rem.
    static let radius: CGFloat = 4

    /// One character of the body font (`Typography.bodySmall`), on average: the unit of
    /// an opened page's layout, the TUI's in characters (docs/design/apple-clients.md, Page width).
    static let characterWidth: CGFloat = 7.2
    /// An opened page, centred in its column, at most 100 characters wide; its details
    /// under what is decided. Chrome (toolbar, sidebar, list, status) is not the page's
    /// and keeps its own width.
    static let readableWidth = 100 * characterWidth

    /// Prism's spacing scale, in points, by its step names.
    enum Spacing {
        static let s1: CGFloat = 1, s2: CGFloat = 2, s3: CGFloat = 3, s5: CGFloat = 5, s6: CGFloat = 6
        static let s7: CGFloat = 7, s9: CGFloat = 9, s10: CGFloat = 10, s11: CGFloat = 11, s13: CGFloat = 13
        static let s14: CGFloat = 14, s15: CGFloat = 15, s17: CGFloat = 17, s18: CGFloat = 18, s19: CGFloat = 19
        static let s22: CGFloat = 22, s30: CGFloat = 30, s44: CGFloat = 44, s48: CGFloat = 48
        static let s60: CGFloat = 60, s64: CGFloat = 64
    }

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    /// Blur radius is Prism's blur halved: SwiftUI's radius is a standard deviation.
    static let cardShadow = Shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    static let containerShadow = Shadow(color: .black.opacity(0.05), radius: 15, y: 10)

    struct TextStyle {
        let size: CGFloat
        let lineHeight: CGFloat
        let weight: Font.Weight

        var font: Font { .system(size: size, weight: weight) }
    }

    /// Prism's typography; weights as on Apple (reading 300, data and supporting 400,
    /// subheading 500, strong 600, headline 700).
    enum Typography {
        static let title5 = TextStyle(size: 24, lineHeight: 26, weight: .semibold)
        static let title6 = TextStyle(size: 20, lineHeight: 22, weight: .semibold)
        static let title7 = TextStyle(size: 16, lineHeight: 20, weight: .semibold)
        static let label = TextStyle(size: 16, lineHeight: 16, weight: .semibold)
        static let labelSmall = TextStyle(size: 14, lineHeight: 14, weight: .semibold)
        static let caption = TextStyle(size: 14, lineHeight: 18, weight: .regular)
        static let captionSmall = TextStyle(size: 12, lineHeight: 14, weight: .regular)
        static let bodySmall = TextStyle(size: 16, lineHeight: 24, weight: .light)
        static let tableRow = TextStyle(size: 14, lineHeight: 16, weight: .regular)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension View {
    /// A Prism text style: its font, and its line height as spacing between lines.
    func prism(_ style: Prism.TextStyle) -> some View {
        font(style.font).lineSpacing(max(0, style.lineHeight - style.size))
    }

    func prismShadow(_ shadow: Prism.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
    }
}

/// A calm card: white in light appearance, the system background in dark, so its text
/// keeps the system's legible colours either way.
struct PrismCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(Prism.Spacing.s15)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The shadow is the card's alone (not its text's or sections'), with room around
            // it so no column, list row or scroll edge cuts it off.
            .background {
                RoundedRectangle(cornerRadius: Prism.radius)
                    .fill(scheme == .dark ? Self.systemBackground : Prism.Colors.white)
                    .prismShadow(Prism.cardShadow)
            }
            .padding(.horizontal, Prism.Spacing.s13)
            .padding(.top, Prism.Spacing.s9)
            .padding(.bottom, Prism.Spacing.s19)
    }

    #if canImport(AppKit)
    static let systemBackground = Color(nsColor: .controlBackgroundColor)
    #else
    static let systemBackground = Color(uiColor: .secondarySystemBackground)
    #endif
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
            .padding(Prism.Spacing.s18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(scheme == .dark ? Color(white: 0.17) : Prism.Colors.white)
                    .prismShadow(Prism.Shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 12, y: 5))
            }
            .overlay {
                if focusable, panelKeys?.focus == .panel {
                    shape.strokeBorder(Prism.Colors.accentText(scheme), lineWidth: 1.5)
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
            .padding(.horizontal, Prism.Spacing.s15)
            .padding(.top, Prism.Spacing.s10)
            .padding(.bottom, Prism.Spacing.s22)
    }
}

/// The card of the page's details under the panel, recessed: no shadow and no stroke, on
/// a light grey surface (grey5 in light, a step below the page in dark), as wide as the
/// panel's card above it. `error` (what went wrong): on Prism's error tint instead
/// (errorlight in light, a faint wash of error in dark).
struct RecessedCard: ViewModifier {
    var error = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(Prism.Spacing.s15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Prism.radius * 2))
            .padding(.horizontal, Prism.Spacing.s15)
    }

    private var fill: Color {
        let dark = scheme == .dark
        if error { return dark ? Prism.Colors.error.opacity(0.14) : Prism.Colors.errorLight }
        return dark ? Color(white: 0.08) : Prism.Colors.grey5
    }
}
