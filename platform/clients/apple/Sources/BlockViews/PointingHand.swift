import SwiftUI

private struct PointingHand: ViewModifier {
    let enabled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        #if os(macOS)
        content.pointerStyle(enabled && isEnabled ? .link : .default)
        #else
        content
        #endif
    }
}

extension View {
    /// Use on the interactive view, inside any `disabled` modifier.
    func pointingHand(enabled: Bool = true) -> some View {
        modifier(PointingHand(enabled: enabled))
    }
}
