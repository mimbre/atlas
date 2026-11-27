import Foundation
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
        // Foundation can omit raw HTML; show the source instead so no sent content disappears.
        let containsHTML = source.range(of: #"<[^>]*>"#, options: .regularExpression) != nil
        guard !containsHTML, let parsed = try? AttributedString(markdown: source), !parsed.characters.isEmpty else {
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
                    Text("\(Text(part.prefix))\(Text(part.text))")
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Text("\(Text(part.prefix))\(Text(part.text))")
                        .font(part.isCode ? .system(.body, design: .monospaced) : nil)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            MarkdownDocument.allows(url) ? .systemAction : .discarded
        })
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Every Markdown heading is smaller than the page title; preserve all six levels.
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 17
        case 3: 16
        case 4: 15
        case 5: 14
        default: 13
        }
    }
}
