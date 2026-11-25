import AtlasControlKit
import Foundation
import Observation

/// The session with Control for a view: `SessionState`'s rules, carried out on a
/// connection and a clock that are injected (`LineConnector`, `SessionClock`), so tests
/// drive it with fakes and never wait.
///
/// It owns at most one connection. Events of a connection it has given up are dropped,
/// and so are timers of an earlier connection or boot.
@MainActor
@Observable
public final class Session {
    public private(set) var state: SessionState

    @ObservationIgnored private let connector: any LineConnector
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private var connection: (any LineConnection)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticking: (any ScheduledAction)?
    @ObservationIgnored private let steerConnector: (any SteerConnector)?
    @ObservationIgnored private var agent: (any SteerConnection)?

    /// `agent` starts the steer agent for `agent:<intent>` actions; without it, such an
    /// action says the agent is not there.
    public init(settings: SessionSettings, connector: any LineConnector, clock: any SessionClock,
                agent: (any SteerConnector)? = nil) {
        state = SessionState(settings: settings)
        self.connector = connector
        self.clock = clock
        steerConnector = agent
    }

    /// Connect, and reconcile every `reconcileSeconds` from now on.
    public func start() {
        guard ticking == nil else { return }
        scheduleTick()
        handle(.start)
    }

    /// Close the connection and stop; the session does not come back.
    public func stop() {
        ticking?.cancel()
        agent?.stop()
        agent = nil
        handle(.stop)
    }

    public func selectTab(_ id: String) { handle(.selectTab(id: id)) }

    /// Show one group of the tab's page (a `groups` block's `to`) in the middle column.
    public func filter(_ to: String) { handle(.filter(to: to)) }

    /// Open a page Control named: a row's `to`.
    public func open(_ to: String) { handle(.open(to: to)) }

    /// Take an action a block declares: submit its `submit_to`, or open its page (a
    /// confirm, a form, more actions) over the page it was taken on.
    public func act(_ action: ActionModel) { handle(.act(action)) }

    /// Leave the page shown over the columns (Cancel): back to where it says.
    public func leave() { handle(.leave) }

    /// Submit a call a block of the page declares, with the values it asks for; `label`
    /// says what is sent (the button's), while it is pending.
    public func submit(_ call: CallModel, values: [String: String] = [:], label: String? = nil) {
        handle(.submit(call: call, values: values, label: label))
    }

    /// Run the agent's proposed plan (its kept steps).
    public func runPlan() { handle(.runPlan) }

    /// Keep or drop a step of the agent's proposed plan.
    public func togglePlanStep(_ n: Int) { handle(.togglePlanStep(n: n)) }

    /// Stop the agent's running plan before its next step.
    public func stopPlan() { handle(.stopPlan) }

    /// Close the agent's plan (cancelled while it is made or proposed).
    public func closePlan() { handle(.closePlan) }

    public func edit(_ name: String, _ value: String) { handle(.edit(name: name, value: value)) }

    func handle(_ input: SessionState.Input) {
        let effects = state.handle(input)
        for effect in effects { run(effect) }
    }

    private func run(_ effect: SessionState.Effect) {
        switch effect {
        case .connect:
            connection?.cancel()
            generation += 1
            let current = generation
            let connection = connector.connection(host: state.settings.host, port: state.settings.port)
            self.connection = connection
            connection.start { [weak self] event in
                guard let self, self.generation == current else { return }
                switch event {
                case .ready: self.handle(.ready)
                case .line(let line): self.handle(.line(line))
                case .closed:
                    self.connection = nil
                    self.handle(.closed)
                }
            }
        case .close:
            generation += 1
            connection?.cancel()
            connection = nil
        case .send(let request):
            guard let line = try? WireLine.encode(request) else { return }
            connection?.send(line)
        case .scheduleRetry:
            clock.schedule(after: SessionState.retrySeconds) { [weak self] in
                self?.handle(.retry)
            }
        case .handshakeDeadline:
            let current = generation
            clock.schedule(after: SessionState.handshakeSeconds) { [weak self] in
                guard let self, self.generation == current else { return }
                self.handle(.handshakeTimedOut)
            }
        case .steer(let request):
            guard let line = try? WireLine.encode(request) else { return }
            if agent == nil {
                guard let steerConnector else {
                    handle(.steerGone("this app was started without it"))
                    return
                }
                do {
                    let agent = try steerConnector.connection(env: state.settings.env)
                    self.agent = agent
                    agent.start { [weak self, weak agent] event in
                        guard let self, let agent, self.agent === agent else { return }
                        switch event {
                        case .line(let line): self.handle(.steerLine(line))
                        case .exited(let why):
                            self.agent = nil
                            self.handle(.steerGone(why))
                        }
                    }
                } catch {
                    handle(.steerGone(error.why))
                    return
                }
            }
            agent?.send(line)
        case .bootDeadline(let serial):
            let current = generation
            clock.schedule(after: SessionState.bootSeconds) { [weak self] in
                guard let self, self.generation == current else { return }
                self.handle(.bootTimedOut(serial: serial))
            }
        }
    }

    private func scheduleTick() {
        ticking = clock.schedule(after: state.settings.reconcileSeconds) { [weak self] in
            guard let self else { return }
            self.handle(.tick)
            if case .ended = self.state.connection { return }
            self.scheduleTick()
        }
    }
}
