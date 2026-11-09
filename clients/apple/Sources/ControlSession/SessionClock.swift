import Foundation

/// A scheduled action that can be called off.
@MainActor
public protocol ScheduledAction: AnyObject {
    func cancel()
}

/// The session's time: it runs an action after a number of seconds, on the main actor.
/// Injected, so tests advance a fake clock instead of waiting.
@MainActor
public protocol SessionClock: AnyObject {
    @discardableResult
    func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction
}

/// The real clock, on the main dispatch queue.
public final class DispatchSessionClock: SessionClock {
    public init() {}

    public func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction {
        let scheduled = DispatchScheduled(action: action)
        // The queue keeps the token alive even when the caller discards it.
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                scheduled.fire()
            }
        }
        scheduled.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return scheduled
    }

    private final class DispatchScheduled: ScheduledAction {
        var action: (@MainActor () -> Void)?
        var item: DispatchWorkItem?

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func fire() {
            let action = self.action
            self.action = nil
            item = nil
            action?()
        }

        func cancel() {
            action = nil
            item?.cancel()
            item = nil
        }
    }
}
