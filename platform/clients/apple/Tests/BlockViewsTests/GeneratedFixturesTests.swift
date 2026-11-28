import AtlasControlKit
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
        }
    }
}
