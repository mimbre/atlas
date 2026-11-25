@testable import ControlSession
import XCTest

final class SettingsTests: XCTestCase {
    func testLaunchArguments() throws {
        let settings = try SessionSettings.launch(["--env", "test", "--host", "127.0.0.1", "--port", "7693"])
        XCTAssertEqual(settings, SessionSettings(env: "test", host: "127.0.0.1", port: 7693))
        XCTAssertEqual(settings.reconcileSeconds, 5)
    }

    func testTheSystemsArgumentsAreIgnored() throws {
        let settings = try SessionSettings.launch(["-NSDocumentRevisionsDebugMode", "YES", "--env", "prod", "--host", "h", "--port", "1", "--reconcile-seconds", "2"])
        XCTAssertEqual(settings.env, "prod")
        XCTAssertEqual(settings.reconcileSeconds, 2)
    }

    func testWithoutTheLauncher() {
        XCTAssertThrowsError(try SessionSettings.launch([])) { XCTAssertEqual($0 as? SessionSettings.Problem, .notLaunched) }
        XCTAssertThrowsError(try SessionSettings.launch(["--env", "test"])) { XCTAssertEqual($0 as? SessionSettings.Problem, .missing("--host")) }
        XCTAssertThrowsError(try SessionSettings.launch(["--env", "test", "--host", "h", "--port", "x"])) { XCTAssertEqual($0 as? SessionSettings.Problem, .invalid("--port")) }
        XCTAssertThrowsError(try SessionSettings.launch(["--env"])) { XCTAssertEqual($0 as? SessionSettings.Problem, .missing("--env")) }
    }

    func testAnEnvironmentsSettingsFile() throws {
        let file = Data(#"{"env":"test","control":{"host":"127.0.0.1","port":7693,"tabs":[]},"reconcile_seconds":3}"#.utf8)
        XCTAssertEqual(try SessionSettings.file(file), SessionSettings(env: "test", host: "127.0.0.1", port: 7693, reconcileSeconds: 3))
    }

    func testASettingsFileWithoutControl() {
        XCTAssertThrowsError(try SessionSettings.file(Data(#"{"env":"test"}"#.utf8)))
    }

    // MARK: A release, and the app it starts after updating itself (IS-Atlas-66)

    func testAReleaseOpenedFromTheFinderConnectsWhereItsBundleSays() throws {
        let info: [String: Any] = ["AtlasControl": ["env": "prod", "host": "127.0.0.1", "port": 7593]]
        XCTAssertEqual(try SessionSettings.launch([], bundle: info), SessionSettings(env: "prod", host: "127.0.0.1", port: 7593))
        XCTAssertEqual(try SessionSettings.launch(["--env", "test", "--host", "h", "--port", "1"], bundle: info).env, "test",
                       "launch arguments win over the bundle")
    }

    func testTheUpdatedAppStartsWithTheSameSettingsOnThePageShown() throws {
        var settings = SessionSettings(env: "prod", host: "127.0.0.1", port: 7593, reconcileSeconds: 2.5)
        settings.startPage = "/k/issue/IS-1"
        XCTAssertEqual(try SessionSettings.launch(settings.arguments), settings)
    }
}
