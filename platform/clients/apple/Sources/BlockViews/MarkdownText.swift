import Foundation
import Prism
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Foundation parses Markdown into attributed text; no HTML view or code execution is involved.
struct MarkdownDocument {
    struct Part {
        var text: AttributedString
        let intent: PresentationIntent?

        var headingLevel: Int? {
            intent?.components.compactMap { component in
                if case .header(let level) = component.kind { return level }
                return nil
            }.first
        }

        var isCode: Bool {
            intent?.components.contains { if case .codeBlock = $0.kind { return true }; return false } ?? false
        }

        var prefix: String {
            guard let components = intent?.components else { return "" }
            var prefix = components.contains { if case .blockQuote = $0.kind { return true }; return false } ? "▎ " : ""
            if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
               case .listItem(let ordinal) = item.kind {
                let ordered = components.contains { if case .orderedList = $0.kind { return true }; return false }
                prefix += ordered ? "\(ordinal). " : "• "
            }
            return prefix
        }
    }

    let parts: [Part]
    static func isMarkdown(_ syntax: String?) -> Bool { syntax == "markdown" }


    init(_ source: String) {
        guard let parsed = try? AttributedString(markdown: source), !parsed.characters.isEmpty else {
            parts = [Part(text: AttributedString(source), intent: nil)]
            return
        }
        var result: [Part] = []
        for run in parsed.runs {
            let fragment = AttributedString(parsed[run.range])
            let intent = run.presentationIntent
            if let last = result.indices.last, result[last].intent == intent {
                result[last].text.append(fragment)
            } else {
                result.append(Part(text: fragment, intent: intent))
            }
        }
        parts = result
    }

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}

struct FormattedText: View {
    let text: String
    let syntax: String?

    var body: some View {
        Group {
            if MarkdownDocument.isMarkdown(syntax) {
                MarkdownText(source: text)
            } else {
                Text(text)
            }
        }
    }
}

#if os(macOS)
private struct LinkText: TextAttribute {}
#endif

struct MarkdownText: View {
    let source: String
    var openLink: (URL) -> OpenURLAction.Result = { _ in .systemAction }

    var body: some View {
        let document = MarkdownDocument(source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(document.parts.enumerated()), id: \.offset) { _, part in
                if let level = part.headingLevel {
                    Self.text(part, typography: Self.headingTypography(level))
                        .prism(Self.headingTypography(level))
                        .linkPointer(part)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Self.text(part, typography: part.isCode ? Prism.Typography.monosmall : Prism.Typography.bodysmall)
                        .prism(part.isCode ? Prism.Typography.monosmall : Prism.Typography.bodysmall)
                        .linkPointer(part)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            MarkdownDocument.allows(url) ? openLink(url) : .discarded
        })
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func text(_ part: MarkdownDocument.Part, typography: PrismTypography) -> Text {
        part.text.runs.reduce(Text(part.prefix)) { result, run in
            var fragment = Text(AttributedString(part.text[run.range]))
            #if os(macOS)
            if let url = run.link, MarkdownDocument.allows(url) {
                fragment = fragment.customAttribute(LinkText())
            }
            #endif
            let intent = run.inlinePresentationIntent
            if intent?.contains(.stronglyEmphasized) == true {
                let strong = typography.emphasis(.strong)
                fragment = fragment.font((strong.weight > typography.weight ? strong : typography).font)
            }
            if intent?.contains(.emphasized) == true { fragment = fragment.italic() }
            if intent?.contains(.code) == true { fragment = fragment.monospaced() }
            return Text("\(result)\(fragment)")
        }
    }

    // The page title is title3; Prism has four smaller title levels.
    nonisolated static func headingTypography(_ level: Int) -> PrismTypography {
        switch level {
        case 1: Prism.Typography.title4
        case 2: Prism.Typography.title5
        case 3: Prism.Typography.title6
        default: Prism.Typography.title7
        }
    }
}

#if os(macOS)
/// A cursor rectangle, without a hit-testing surface over the selectable text.
private final class LinkCursorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct LinkCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> LinkCursorView { LinkCursorView() }
    func updateNSView(_ view: LinkCursorView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }
}

private struct LinkPointer: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { geometry in
                if isEnabled {
                    let bounds = layouts.flatMap { anchored in
                        let origin = geometry[anchored.origin]
                        return anchored.layout.flatMap { line in
                            line.compactMap { run -> CGRect? in
                                guard run[LinkText.self] != nil else { return nil }
                                return run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                            }
                        }
                    }
                    ForEach(Array(bounds.enumerated()), id: \.offset) { _, rect in
                        LinkCursorRegion()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private extension View {
    @ViewBuilder func linkPointer(_ part: MarkdownDocument.Part) -> some View {
        if part.text.runs.contains(where: { $0.link.map(MarkdownDocument.allows) == true }) {
            modifier(LinkPointer())
        } else {
            self
        }
    }
}
#else
private extension View {
    func linkPointer(_ part: MarkdownDocument.Part) -> some View { self }
}
#endif
