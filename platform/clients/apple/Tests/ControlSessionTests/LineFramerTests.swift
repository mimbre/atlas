@testable import ControlSession
import XCTest

final class LineFramerTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testALineSplitOverChunksIsOneLine() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(data("{\"op\":")), [])
        XCTAssertEqual(try framer.append(data("\"bye\"}\n")), [data("{\"op\":\"bye\"}")])
    }

    func testSeveralLinesInAChunkInOrderAndTheRestWaits() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(data("a\nb\nc")), [data("a"), data("b")])
        XCTAssertEqual(try framer.append(data("\n")), [data("c")])
    }

    func testACarriageReturnBeforeTheNewlineIsDropped() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(data("a\r\n")), [data("a")])
    }

    func testALineOverTheLimitFails() {
        var framer = LineFramer(limit: 4)
        XCTAssertThrowsError(try framer.append(data("12345\n")))
        var waiting = LineFramer(limit: 4)
        XCTAssertThrowsError(try waiting.append(data("12345")))
    }

    func testALineAtTheLimitPasses() throws {
        var framer = LineFramer(limit: 4)
        XCTAssertEqual(try framer.append(data("1234\n")), [data("1234")])
    }

    func testTheDefaultLimitIsTheTUIsBuffer() {
        XCTAssertEqual(LineFramer().limit, 4_194_304)
    }
}
