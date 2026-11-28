import AtlasControlKit
@testable import BlockViews
import Foundation
import Prism
import XCTest

final class MarkdownTextTests: XCTestCase {
    func testOnlyExplicitMarkdownChangesPlainText() throws {
        for (syntax, expected) in [(nil, false), ("future", false), ("markdown", true)] as [(String?, Bool)] {
            var fields = ["text": "# Literal"]
            fields["syntax"] = syntax
            let data = try JSONSerialization.data(withJSONObject: fields)
            let block = try JSONDecoder().decode(TextBlock.self, from: data)
            XCTAssertEqual(TextLine.isMarkdown(block), expected)
            XCTAssertEqual(TextLine.line(block, now: Date()), "# Literal")
            var pairFields = ["value": "# Literal"]
            pairFields["syntax"] = syntax
            let pairData = try JSONSerialization.data(withJSONObject: pairFields)
            let pair = try JSONDecoder().decode(PairModel.self, from: pairData)
            XCTAssertEqual(MarkdownDocument.isMarkdown(pair.syntax), expected)
            XCTAssertEqual(pair.value, "# Literal")
        }
        let legacyTextData = try JSONSerialization.data(withJSONObject: ["text": "# Literal", "format": "markdown"])
        let legacyText = try JSONDecoder().decode(TextBlock.self, from: legacyTextData)
        XCTAssertFalse(TextLine.isMarkdown(legacyText))
        let legacyPairData = try JSONSerialization.data(withJSONObject: ["value": "# Literal", "format": "markdown"])
        let legacyPair = try JSONDecoder().decode(PairModel.self, from: legacyPairData)
        XCTAssertFalse(MarkdownDocument.isMarkdown(legacyPair.syntax))
    }

    func testHTMLIsShownAsLiteralSource() {
        let source = "Before <script>alert(1)</script> after"
        let document = MarkdownDocument(source)
        XCTAssertEqual(document.parts.map { String($0.text.characters) }.joined(), source)
    }

    func testAllHeadingLevelsKeepTheirHierarchy() {
        let source = (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n\n")
        let document = MarkdownDocument(source)
        XCTAssertEqual(document.parts.compactMap(\.headingLevel), [1, 2, 3, 4, 5, 6])
    }

    func testHeadingTypographyUsesPrismBelowPageTitle() {
        let expected = [Prism.Typography.title4, Prism.Typography.title5, Prism.Typography.title6,
                        Prism.Typography.title7, Prism.Typography.title7, Prism.Typography.title7]
        XCTAssertEqual((1...6).map(MarkdownText.headingTypography), expected)
        XCTAssertTrue(expected.allSatisfy { $0.size < Prism.Typography.title3.size })
    }

    func testFencedCodeIsLiteralAndNotALink() {
        let document = MarkdownDocument("```sh\n[run](https://example.com)\n```")
        let code = document.parts.filter(\.isCode)
        XCTAssertFalse(code.isEmpty)
        XCTAssertEqual(code.map { String($0.text.characters) }.joined().trimmingCharacters(in: .whitespacesAndNewlines), "[run](https://example.com)")
        XCTAssertTrue(code.allSatisfy { $0.text.runs.allSatisfy { $0.link == nil } })
    }

    func testOnlyWebLinksCanBeOpened() throws {
        for value in ["https://example.com/path", "http://example.com"] {
            XCTAssertTrue(MarkdownDocument.allows(try XCTUnwrap(URL(string: value))))
        }
        for value in ["file:///tmp/file", "javascript:alert(1)", "atlas://action"] {
            XCTAssertFalse(MarkdownDocument.allows(try XCTUnwrap(URL(string: value))))
        }
    }

    func testFormattingAndListsArePreserved() {
        let document = MarkdownDocument("A **bold** [link](https://example.com).\n\n- First\n- Second")
        XCTAssertTrue(document.parts.contains { $0.text.runs.contains { $0.link != nil } })
        XCTAssertEqual(document.parts.filter { $0.prefix.contains("•") }.count, 2)
    }

    func testAngleBracketPlaceholdersDoNotDisableHeadingsOrLists() {
        let document = MarkdownDocument("## Notes\n\n- Scene SC-<code>-NN\n- Use case UC-<code>-NN")
        XCTAssertEqual(document.parts.compactMap(\.headingLevel), [2])
        let items = document.parts.filter { $0.prefix == "• " }
        XCTAssertEqual(items.map { String($0.text.characters) }, [
            "Scene SC-<code>-NN", "Use case UC-<code>-NN"
        ])
    }
}
