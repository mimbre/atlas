import AtlasControlKit
@testable import ControlSession
import XCTest

/// Against a real Control (docs/design/apple-clients.md §7): the e2e's private test
/// instance, whose settings file `ATLAS_ENV_FILE` names. Skipped without it, so a plain
/// `swift test` stays a unit run. `swift test --filter ControlIntegration` runs only this.
@MainActor
final class ControlIntegrationTests: XCTestCase {
    func testWelcomeAPageAndABootShell() throws {
        guard let file = ProcessInfo.processInfo.environment["ATLAS_ENV_FILE"], !file.isEmpty else {
            throw XCTSkip("ATLAS_ENV_FILE is not set: no Control to connect to")
        }
        let settings = try SessionSettings.file(Data(contentsOf: URL(fileURLWithPath: file)))
        let session = Session(settings: settings, connector: NetworkLineConnector(), clock: DispatchSessionClock())

        session.start()
        defer { session.stop() }

        // Real network: the main run loop turns until the shell and a page are there, or 30 s pass.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let state = session.state
            if case .ended(let ending) = state.connection { return XCTFail("the session ended: \(ending)") }
            if state.connection == .connected, state.shell != nil, state.pageOnScreen != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let state = session.state
        let shell = try XCTUnwrap(state.shell)
        XCTAssertEqual(shell.env, settings.env)
        XCTAssertEqual(shell.spec, Contract.version)
        XCTAssertFalse(shell.tabs?.isEmpty ?? true)
        XCTAssertFalse(state.shellStale)
        let page = try XCTUnwrap(state.pageOnScreen)
        XCTAssertNotNil(Page.match(try XCTUnwrap(page.path)))
        XCTAssertEqual(ShellViewModel(state).tabs.map(\.id), shell.tabs?.compactMap(\.id))
    }
}
