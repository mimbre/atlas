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

    }

    /// `default` radius, 0.25rem.
    static let radius: CGFloat = 4

    /// One character of the body font (`Typography.bodySmall`), on average: the unit of
    /// an opened page's layout, the TUI's in characters (docs/design/apple-clients.md, Layout).
    static let characterWidth: CGFloat = 7.2

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

/// A calm card (`PrismDarkGap.card`).
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
                    .fill(PrismDarkGap.card(scheme))
                    .prismShadow(Prism.cardShadow)
            }
            .padding(.horizontal, Prism.Spacing.s13)
            .padding(.top, Prism.Spacing.s9)
            .padding(.bottom, Prism.Spacing.s19)
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
            .padding(Prism.Spacing.s18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(PrismDarkGap.panelCard(scheme))
                    .prismShadow(Prism.Shadow(color: PrismDarkGap.panelShadow(scheme), radius: 12, y: 5))
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

    private var fill: Color { PrismDarkGap.recessed(scheme, error: error) }
}

// Prism's `Tag` and `Button`, drawn as Prism's Swift package draws them (prism
// `targets/swift/Sources/Prism/Tag.swift`, `Button.swift`): the same tokens, radius and
// padding. Copied until Prism's package supports macOS; then Prism's own replace these.

/// A tag's tone, as Prism's.
enum PrismTagTone { case accent, success, warning, danger, neutral }

/// Prism's `Tag`: a label in the tone's colour on the tone at 20%, over white; radius
/// default, padding 6 × 12, 14/16 at subheading weight.
struct PrismTag: View {
    let text: String
    var tone: PrismTagTone = .accent

    var body: some View {
        Text(text).font(.system(size: 14, weight: .medium)).lineSpacing(2)
            .foregroundStyle(color)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: Prism.radius))
            .background(Prism.Colors.white, in: RoundedRectangle(cornerRadius: Prism.radius))
            .fixedSize()
    }

    private var color: Color {
        switch tone {
        case .accent: Prism.Colors.primary
        case .success: Prism.Colors.success
        case .warning: Prism.Colors.warning
        case .danger: Prism.Colors.error
        case .neutral: Color(hex: 0x666666)
        }
    }
}

/// A button's variant and tone, as Prism's (those Atlas uses).
enum PrismButtonVariant { case primary, secondary, plain, text }
enum PrismButtonTone { case accent, success, warning, danger, neutral }

/// Prism's `Button` look as a `ButtonStyle`: radius default, the button type (18/18,
/// strong). `primary`: filled in the tone (accent: primary), white label, padding 15 × 16.
/// `secondary`: no fill, a 2pt border and label in the tone, padding 13 × 16. `plain`:
/// grey1 label, `text`: the tone's label; both padding 15 × 16, or 4 × 0 (plain) and 1 × 0
/// (text) when not `padded`. Pressed, primary and secondary sink as Prism's do; disabled,
/// at half opacity. Prism's grey1 has no dark value (`PrismDarkGap.text`).
struct PrismButtonStyle: ButtonStyle {
    var variant: PrismButtonVariant
    var tone: PrismButtonTone = .accent
    var padded = true

    init(_ variant: PrismButtonVariant, tone: PrismButtonTone = .accent, padded: Bool = true) {
        self.variant = variant
        self.tone = tone
        self.padded = padded
    }

    func makeBody(configuration: Configuration) -> some View {
        Look(style: self, configuration: configuration)
    }

    private struct Look: View {
        let style: PrismButtonStyle
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let pressed = configuration.isPressed
            let (top, side, bottom) = padding(pressed)
            configuration.label
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.top, top).padding(.bottom, bottom).padding(.horizontal, side)
                .background(fill, in: RoundedRectangle(cornerRadius: Prism.radius))
                .overlay {
                    if style.variant == .secondary {
                        RoundedRectangle(cornerRadius: Prism.radius).strokeBorder(toneColor, lineWidth: 2)
                    }
                }
                .opacity(isEnabled || style.variant == .plain || style.variant == .text ? 1 : 0.5)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.15), value: pressed)
        }

        private var toneColor: Color {
            switch style.tone {
            case .accent: Prism.Colors.primary
            case .success: Prism.Colors.success
            case .warning: Prism.Colors.warning
            case .danger: Prism.Colors.error
            case .neutral: PrismDarkGap.text(scheme)
            }
        }

        private var foreground: Color {
            switch style.variant {
            case .primary: Prism.Colors.white
            case .secondary, .text: toneColor
            case .plain: style.tone == .accent ? PrismDarkGap.text(scheme) : toneColor
            }
        }

        private var fill: Color { style.variant == .primary ? toneColor : .clear }

        private func padding(_ pressed: Bool) -> (CGFloat, CGFloat, CGFloat) {
            switch style.variant {
            case .primary: pressed ? (16, 16, 14) : (15, 16, 15)
            // Prism's 13 × 16 inside its 2pt border, which SwiftUI draws within the padding.
            case .secondary: pressed ? (16, 18, 14) : (15, 18, 15)
            case .plain: style.padded ? (pressed ? (16, 16, 14) : (15, 16, 15)) : (pressed ? (5, 0, 3) : (4, 0, 4))
            case .text: style.padded ? (pressed ? (16, 16, 14) : (15, 16, 15)) : (pressed ? (2, 0, 0) : (1, 0, 1))
            }
        }
    }
}
