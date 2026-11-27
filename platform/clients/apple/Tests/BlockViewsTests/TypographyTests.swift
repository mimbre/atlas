import Foundation
import XCTest

/// One type system: Atlas's own views (BlockViews and the Mac app) set their text in Prism's
/// typography (`.prism(Prism.Typography.…)`), never in SwiftUI's text styles, the system
/// font at a size of their own, or a weight of their own (docs/design/clients.md, Typography).
final class TypographyTests: XCTestCase {

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()


    /// One button size: every Prism button (`PrismButtonStyle`, `.prism(…)` as a button
    /// style, `PrismButtonLooks`) in Prism's `small` size, about 32pt tall, no larger than
    /// the running text it acts on.
    func testPrismButtonsAreSmall() throws {
        let button = try NSRegularExpression(pattern: #"PrismButtonStyle\(|PrismButtonLooks\(|buttonStyle\(\s*\.prism\("#)
        let found = try Self.lines().filter { _, code in
            button.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
                && !code.contains("size: .small")
        }.map(\.at)
        XCTAssertEqual(found, [], "give every Prism button `size: .small`")
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
