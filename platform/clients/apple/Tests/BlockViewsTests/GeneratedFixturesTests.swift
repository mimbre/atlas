import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

final class GeneratedFixturesTests: XCTestCase {
    func testGeneratedBlocksDecodeWithoutFallback() throws {
        guard let path = ProcessInfo.processInfo.environment["ATLAS_BFF_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("Set ATLAS_BFF_FIXTURES to the generated fixtures.json")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fixtures = try XCTUnwrap(root["fixtures"] as? [String: Any])
        let blocks = try XCTUnwrap(fixtures["blocks"] as? [[String: Any]])
        for block in blocks {
            let name = try XCTUnwrap(block["name"] as? String)
            for variant in try XCTUnwrap(block["variants"] as? [[String: Any]]) {
                let sample = try XCTUnwrap(variant["sample"] as? [String: Any])
                let encoded = try JSONSerialization.data(withJSONObject: sample)
                let decoded = try JSONDecoder().decode(Block.self, from: encoded)
                if case .fallback(let reason) = decoded.content {
                    XCTFail("\(name) \(variant["case"] ?? "?"): \(reason)")
                }
            }
            let variants = try XCTUnwrap(block["variants"] as? [[String: Any]])
            let required = try XCTUnwrap(variants.first { $0["case"] as? String == "required" }?["sample"] as? [String: Any])
            let full = try XCTUnwrap(variants.first { $0["case"] as? String == "full" }?["sample"] as? [String: Any])
            let requiredProps = try XCTUnwrap(required["props"] as? [String: Any])
            let fullProps = try XCTUnwrap(full["props"] as? [String: Any])
            let optional = try XCTUnwrap(block["optional"] as? [String])
            for mask in 0..<(1 << optional.count) {
                var sample = required
                var props = requiredProps
                for (index, field) in optional.enumerated() where mask & (1 << index) != 0 {
                    props[field] = try XCTUnwrap(fullProps[field])
                }
                sample["props"] = props
                let decoded = try JSONDecoder().decode(Block.self, from: JSONSerialization.data(withJSONObject: sample))
                if case .fallback(let reason) = decoded.content {
                    XCTFail("\(name) mask \(mask): \(reason)")
                }
            }
        }
    }

    func testGeneratedTextUsesMacSyntaxRendering() throws {
        guard let path = ProcessInfo.processInfo.environment["ATLAS_BFF_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("Set ATLAS_BFF_FIXTURES to the generated fixtures.json")
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let fixtures = try XCTUnwrap(root["fixtures"] as? [String: Any])
        let blocks = try XCTUnwrap(fixtures["blocks"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first { $0["name"] as? String == "text" })
        let variants = try XCTUnwrap(text["variants"] as? [[String: Any]])
        for (name, markdown) in [("value:syntax:plain", false), ("value:syntax:markdown", true)] {
            let variant = try XCTUnwrap(variants.first { $0["case"] as? String == name })
            let sample = try XCTUnwrap(variant["sample"] as? [String: Any])
            let props = try XCTUnwrap(sample["props"] as? [String: Any])
            let block = try JSONDecoder().decode(TextBlock.self, from: JSONSerialization.data(withJSONObject: props))
            XCTAssertEqual(TextLine.isMarkdown(block), markdown)
            XCTAssertTrue(TextLine.line(block, now: Date()).contains("readable example"))
        }
    }
}
