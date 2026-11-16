import ControlSession
import Foundation
import XCTest

@MainActor
final class SessionClockTests: XCTestCase {
    private final class Counter {
        var calls = 0
    }

    private final class WeakReference {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    // Returning from a separate frame leaves only the scheduler owning the action.
    @inline(never)
    private func schedule(_ clock: DispatchSessionClock, calls: Counter, cancel: Bool) -> (WeakReference, WeakReference) {
        let capture = Counter()
        let token = clock.schedule(after: 0) {
            capture.calls += 1
            calls.calls += 1
        }
        let references = (WeakReference(token), WeakReference(capture))
        if cancel {
            token.cancel()
            token.cancel()
        }
        return references
    }

    // A later main-queue marker, then another turn, lets due work items return before
    // checking weak references. The timeout bounds failure; it is not the success condition.
    private func drainDueActions() {
        var drained = false
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            DispatchQueue.main.async { drained = true }
        }
        let timeout = Date().addingTimeInterval(5)
        while !drained && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(drained, "main queue did not drain")
    }

    func testDiscardedTokensStillFireOnceAndRelease() {
        let clock = DispatchSessionClock()
        let calls = Counter()
        let references = (0..<100).map { _ in schedule(clock, calls: calls, cancel: false) }

        drainDueActions()
        drainDueActions()

        XCTAssertEqual(calls.calls, 100)
        XCTAssertTrue(references.allSatisfy { $0.0.value == nil }, "fired tokens retained")
        XCTAssertTrue(references.allSatisfy { $0.1.value == nil }, "fired actions retained")
    }

    func testCancellationReleasesActionsAndSuppressesDueCallbacks() {
        let clock = DispatchSessionClock()
        let calls = Counter()
        // These deadlines are already due, but cannot run until this actor yields.
        let references = (0..<100).map { _ in schedule(clock, calls: calls, cancel: true) }
        XCTAssertTrue(references.allSatisfy { $0.1.value == nil }, "cancel must release actions immediately")

        drainDueActions()
        drainDueActions()

        XCTAssertEqual(calls.calls, 0)
        XCTAssertTrue(references.allSatisfy { $0.0.value == nil }, "cancelled tokens retained")
    }

    func testHoldingAFiredTokenDoesNotHoldItsAction() {
        let clock = DispatchSessionClock()
        let calls = Counter()
        weak var capture: Counter?
        var token: (any ScheduledAction)?
        do {
            let value = Counter()
            capture = value
            token = clock.schedule(after: 0) {
                value.calls += 1
                calls.calls += 1
            }
        }
        drainDueActions()

        XCTAssertEqual(calls.calls, 1)
        XCTAssertNil(capture)
        XCTAssertNotNil(token)
        token?.cancel()
        token?.cancel()
        token = nil
        drainDueActions()
        XCTAssertEqual(calls.calls, 1)
    }

    func testCallbackCanCancelAndReleaseItsOwnToken() {
        let clock = DispatchSessionClock()
        let calls = Counter()
        var token: (any ScheduledAction)?
        token = clock.schedule(after: 0) {
            calls.calls += 1
            token?.cancel()
            token?.cancel()
            token = nil
        }
        weak var reference = token

        drainDueActions()
        drainDueActions()

        XCTAssertEqual(calls.calls, 1)
        XCTAssertNil(reference)
    }
}
