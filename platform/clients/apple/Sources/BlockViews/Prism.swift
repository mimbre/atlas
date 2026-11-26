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
            .background(scheme == .dark ? Self.systemBackground : Prism.Colors.white,
                        in: RoundedRectangle(cornerRadius: Prism.radius))
            .prismShadow(Prism.cardShadow)
    }

    #if canImport(AppKit)
    static let systemBackground = Color(nsColor: .controlBackgroundColor)
    #else
    static let systemBackground = Color(uiColor: .secondarySystemBackground)
    #endif
}
