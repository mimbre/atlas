import Foundation
import Prism
import SwiftUI

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
    static func isMarkdown(_ format: String?) -> Bool { format == "markdown" }


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
    let format: String?

    var body: some View {
        Group {
            if MarkdownDocument.isMarkdown(format) {
                MarkdownText(source: text)
            } else {
                Text(text)
            }
        }
    }
}

struct MarkdownText: View {
    let source: String

    var body: some View {
        let document = MarkdownDocument(source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(document.parts.enumerated()), id: \.offset) { _, part in
                if let level = part.headingLevel {
                    Self.text(part, typography: Self.headingTypography(level))
                        .prism(Self.headingTypography(level))
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Self.text(part, typography: part.isCode ? Prism.Typography.monosmall : Prism.Typography.bodysmall)
                        .prism(part.isCode ? Prism.Typography.monosmall : Prism.Typography.bodysmall)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            MarkdownDocument.allows(url) ? .systemAction : .discarded
        })
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func text(_ part: MarkdownDocument.Part, typography: PrismTypography) -> Text {
        part.text.runs.reduce(Text(part.prefix)) { result, run in
            var fragment = Text(AttributedString(part.text[run.range]))
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
