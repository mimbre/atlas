import Foundation
import XCTest

/// One type system: Atlas's own views (BlockViews and the Mac app) set their text in Prism's
/// typography (`.prism(Prism.Typography.…)`), never in SwiftUI's text styles, the system
/// font at a size of their own, or a weight of their own (docs/design/clients.md, Typography).
final class TypographyTests: XCTestCase {
    /// What sets a font outside Prism: a text style or the system font (`.font(.body)`,
    /// `.font(.system(size: 11))`, `Font.caption`), or a weight or design on top of one.
    private static let forbidden = [
        #"\.font\(\s*\."#,
        #"\.font\(\s*Font\b"#,
        #"\bFont\.(system|body|callout|caption|caption2|footnote|headline|subheadline|title|title2|title3|largeTitle|custom)\b"#,
        #"\.system\(\s*size:"#,
        #"\.fontWeight\("#,
        #"\.bold\("#,
        #"\.italic\("#,
        #"\.fontDesign\("#,
        #"\.fontWidth\("#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testAtlasViewsSetTheirTextInPrismTypographyOnly() throws {
        let folders = ["Sources/BlockViews", "Mac"].map { Self.apple.appendingPathComponent($0) }
        var sources: [URL] = []
        for folder in folders {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            sources += files.filter { $0.pathExtension == "swift" }
        }
        XCTAssertFalse(sources.isEmpty, "no view sources under \(Self.apple.path)")
        var found: [String] = []
        for source in sources {
            let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                let range = NSRange(code.startIndex..., in: code)
                if Self.forbidden.contains(where: { $0.firstMatch(in: code, range: range) != nil }) {
                    found.append("\(source.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "use Prism's typography (`.prism(Prism.Typography.…)`)")
    }
}
