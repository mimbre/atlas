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

    /// Prism's smaller end, one set (docs/design/clients.md, Typography): running text
    /// `bodysmall` (commands in the monospaced face at its size), labels `label`, meta and
    /// eyebrows `caption`/`labelsmall`, a count's badge `captionsmall`, titles
    /// `title6`/`title7`. Nothing that acts or is copied (a button, a command) larger than the
    /// text that explains it.
    private static let scale: Set<String> = ["title6", "title7", "label", "labelsmall", "caption", "captionsmall",
                                             "bodysmall"]

    func testAtlasViewsSetTheirTextInPrismTypographyOnly() throws {
        let found = try Self.lines().filter { _, code in
            let range = NSRange(code.startIndex..., in: code)
            return Self.forbidden.contains { $0.firstMatch(in: code, range: range) != nil }
        }.map(\.at)
        XCTAssertEqual(found, [], "use Prism's typography (`.prism(Prism.Typography.…)`)")
    }

    func testAtlasViewsUseOneSetOfPrismsTypographies() throws {
        let role = try NSRegularExpression(pattern: #"Prism\.Typography\.(\w+)"#)
        var found: [String] = []
        for (at, code) in try Self.lines() {
            for match in role.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let name = String(code[Range(match.range(at: 1), in: code)!])
                if !Self.scale.contains(name) { found.append("\(at): \(name)") }
            }
        }
        XCTAssertEqual(found, [], "use one of \(Self.scale.sorted())")
    }

    /// Every code line (comments cut off) of Atlas's views, with where it is.
    private static func lines() throws -> [(at: String, code: String)] {
        let folders = ["Sources/BlockViews", "Mac"].map { apple.appendingPathComponent($0) }
        var sources: [URL] = []
        for folder in folders {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            sources += files.filter { $0.pathExtension == "swift" }
        }
        XCTAssertFalse(sources.isEmpty, "no view sources under \(apple.path)")
        var lines: [(at: String, code: String)] = []
        for source in sources {
            for (number, line) in try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                lines.append(("\(source.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))", code))
            }
        }
        return lines
    }
}
