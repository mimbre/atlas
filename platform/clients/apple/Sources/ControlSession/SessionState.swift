import AtlasControlKit
import Foundation

/// The session with Control as plain state and rules, no actor, no time and no socket:
/// each input (a connection event, a message, a tick of the clock, what the user does)
/// changes the state and says what to do (`Effect`). `Session` carries the effects out;
/// tests drive both.
///
/// The rules are the TUI's (`AtlasTui.Console`, `AtlasTui.App`): hello with the contract
/// version; a welcome for another environment or surface, or a bye, ends the session (any
/// contract version is welcome, D-0105: the status bar only says they differ);
/// the page hello brings is consumed, then `boot` gives the shell and `open` its
/// start; one `open` on the wire at a time; a dropped connection retries every 2 s and, on
/// return, boots for the page it was on and opens it again; every `reconcileSeconds` it
/// boots again (shell changes) and sends `refresh`, except while a page with a form or
/// confirm is being edited; a draft is never replaced by a page Control pushes; only an
/// `open` answers an `open`. A message of a known op that does not decode still answers
/// what the session waits for, as a failure. Unlike the TUI, only hello's boot that times
/// out drops the connection: a later one marks the shell stale and is tried again
/// (Control may be busy reading a page). An action is taken as the TUI and the agent CLI
/// take one: its `submit_to` is submitted, else its page is opened, over the page it was
/// taken on, until Control stores it or the user leaves it. Until Control answers an
/// action (its page, the page stored or refused, or a notice that ends the submit), the
/// action is `pending`, so a slow Control never looks like a dead click. An `agent:<intent>`
/// action asks the steer agent about the page it is on, as the TUI's does
/// (`AtlasTui.Model.agent_action`); its plan shows over the columns until it is closed.
public struct SessionState: Sendable, Equatable {
    // MARK: Parts of the state

    /// The connection, as the status bar says it.
    public enum Connection: Sendable, Equatable {
        /// Not started.
        case idle
        /// Making the TCP connection.
        case connecting
        /// Connected; hello sent, no welcome yet.
        case handshake
        /// Welcomed by Control.
        case connected
        /// Closed; it is tried again after `SessionState.retrySeconds`.
        case retrying
        /// Over, not tried again.
        case ended(Ending)
    }

    /// Why the session ended.
    public enum Ending: Sendable, Equatable {
        /// Control said bye (another environment, …), with its text.
        case bye(String)
        /// Control's welcome names another environment or surface.
        case incompatible(WelcomeMessage)
        /// Control's welcome does not decode, and why (the TUI ends such a session too).
        case unreadableWelcome(Fallback.Reason)
        /// The app stopped it.
        case stopped
    }

    /// Why the connection is gone, while it is tried again (the status bar says it).
    public enum Lost: Sendable, Equatable {
        /// Nothing answered where Control is.
        case unreachable
        /// Control was reached but does not answer, or no longer: it may be restarting.
        case silent
    }
    public enum BootFailure: Error, Sendable, Equatable {
        /// Control's boot error, its text.
        case control(String)
        /// A shell the session does not accept, and why.
        case invalid(ShellProblem)
        /// A boot reply that does not decode, and why.
        case unreadable(Fallback.Reason)
        /// No answer before the deadline; the connection is made again.
        case timedOut
    }

    /// What is wrong with a boot shell (the TUI's checks and the boot limits, ADR 0004).
    public enum ShellProblem: Sendable, Equatable {
        case env
        case title
        case revision
        case tabCount
        case tab(index: Int)
        case duplicateTab
        case initialTo
        case activeTab
    }

    /// The column a page is shown in: the tab's index page (middle) or a page opened
    /// from it (right).
    public enum Column: Sendable, Equatable {
        case index
        case opened
    }

    /// Why Control sent a page.
    public enum Reason: String, Sendable, Equatable {
        case open, stored, refused, reconcile, hint, pending
    }

    /// How and when a page came: for the status bar.
    public struct Update: Sendable, Equatable {
        public var reason: Reason
        public var at: String?
        public var position: Int?
        public var path: String
    }

    /// An `open` whose answer did not decode: the page asked for, and why. The pages on
    /// screen stay, but they are not the page Control's session is on.
    public struct OpenFailure: Sendable, Equatable {
        public var path: String
        public var reason: Fallback.Reason
    }

    /// The shell `boot` gave, as Control sent it.
    public typealias Shell = BootShellMessage

    /// An action being taken: the opened page it was taken on (nil when taken on the
    /// index page), shown under the action's pages until the action ends.
    public struct Action: Sendable, Equatable {
        public var from: PageMessage?
    }

    /// What the user did that Control (or the agent) has not answered yet: shown at once,
    /// on the action's button, on the sheet and in the status bar, and gone with the answer.
    public struct Pending: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// An action's page (its confirm, form or more actions) is being opened.
            case opening
            /// A call is submitted (an action's `submit_to`, a confirm, a form, a choice).
            case sending
            /// The agent is asked (`agent:<intent>`) and has not answered.
            case asking
        }

        public var kind: Kind
        /// What is done, in Control's words (the action's or the button's label), if known.
        public var label: String?
        /// The action taken, when it was one: its button shows that it is pending.
        public var action: ActionModel?

        public init(kind: Kind, label: String?, action: ActionModel?) {
            self.kind = kind
            self.label = label
            self.action = action
        }

        /// What the status bar says while it is pending.
        public var text: String {
            let what = label.map { "“\($0)”" }
            switch kind {
            case .opening: return what.map { "Opening \($0)…" } ?? "Opening…"
            case .sending: return what.map { "Sending \($0)…" } ?? "Sending…"
            case .asking: return what.map { "Asking the agent: \($0)…" } ?? "Asking the agent…"
            }
        }
    }

    /// What the state asks `Session` to do.
    public enum Effect: Sendable, Equatable {
        /// Make a new connection to Control.
        case connect
        /// Close the connection (it reports nothing after).
        case close
        /// Send a request.
        case send(ControlRequest)
        /// Retry the connection after `retrySeconds` (`Input.retry`).
        case scheduleRetry
        /// Give up on the handshake after `handshakeSeconds` (`Input.handshakeTimedOut`).
        case handshakeDeadline
        /// Give up on this boot after `bootSeconds` (`Input.bootTimedOut(serial)`).
        case bootDeadline(serial: Int)
        /// Send a message to the steer agent, started when it is first needed
        /// (`Input.steerLine`, `Input.steerGone`).
        case steer(SteerRequest)
    }

    /// The protocol's phases, as in `AtlasTui.Console`.
    enum Phase: Sendable, Equatable {
        /// Waiting for welcome.
        case welcome
        /// Welcomed; waiting for the page hello brings.
        case compatibility
        /// Waiting for the first boot after hello.
        case boot
        /// Boot done; the start page is on its way.
        case content
        /// Showing pages.
        case ready
    }

    public static let retrySeconds: Double = 2
    public static let handshakeSeconds: Double = 5
    public static let bootSeconds: Double = 5
    public static let tabLimit = 64

    public let settings: SessionSettings
    public private(set) var connection: Connection = .idle
    /// Why the last connection is gone; nil once Control welcomes the app again.
    public private(set) var lost: Lost?
    /// The contract version Control's welcome named; nil before it, or when it named none.
    public private(set) var controlSpec: String?
    /// Control's contract version when it is newer than this app's: the app's update asks
    /// the release feed at once (IS-Atlas-66, D-0105). Nil when the same or older.
    public var newerControl: String? {
        controlSpec.flatMap { StatusViewModel.newer($0, than: Contract.version) ? $0 : nil }
    }
    var phase: Phase = .welcome

    /// The last good shell; nil until a boot succeeds.
    public private(set) var shell: Shell?
    /// The shell may be out of date: not booted on this connection, or the last boot failed.
    public private(set) var shellStale = true
    public private(set) var bootFailure: BootFailure?
    var bootPending = false
    public private(set) var bootSerial = 0

    /// The tab the user is on: the shell's `active_tab`, or the one chosen.
    public private(set) var activeTab: String?
    /// The tab's index page (middle column) and a page opened from it (right column).
    public private(set) var index: PageMessage?
    public private(set) var opened: PageMessage? {
        didSet { if opened == nil { action = nil } }
    }
    /// An action taken on a page: its pages (its confirm, form or menu, and the pages
    /// taken from them) are opened as usual and shown over the page it was taken on.
    public private(set) var action: Action?
    /// The page asked for and the column it goes to; nil when none is on its way.
    public private(set) var expected: String?
    public private(set) var expectedColumn: Column = .index
    /// The page an `open` on the wire asked for (one at a time).
    var inFlight: String?
    /// The last `open` whose answer did not decode; cleared by the next `open`.
    public private(set) var openFailure: OpenFailure?

    /// What the user typed into the page on screen; kept while that page is replaced by
    /// Control's pushes, dropped when the user leaves it.
    public private(set) var draft: [String: String] = [:]

    public private(set) var notice: NoticeMessage?
    public private(set) var lastUpdate: Update?
    public private(set) var lastHint: Update?
    /// The last count of each tab and group, by its `to`, as boot or a page's `groups` said
    /// it, whichever came last: what the sidebar shows under every tab, also before it is
    /// opened.
    public private(set) var groupCounts: [String: Int] = [:]
    /// A submit is sent and Control has not replied to it (a page stored or refused, one
    /// opened since, or a notice that answers it); another waits until it has.
    public private(set) var submitting = false
    /// What the user did that is not answered yet (`Pending`).
    public private(set) var pending: Pending?
    /// The error notice that answered the last submit without a page (Control sends no
    /// `refused` page then): shown on the sheet, until a page is shown or opened.
    public private(set) var answer: NoticeMessage?
    /// An action ended by Control's `ok` notice: the stored page that may follow is its,
    /// and closes its pages as it would have.
    var storedAction: Action?

    /// The steer agent's plan as it last sent it (the contract's `plan` block), from the
    /// `agent:<intent>` action that asked until it is closed; nil when none is shown.
    public private(set) var plan: PlanBlock?
    /// The steps of the proposed plan the user dropped, by `n`; the rest run.
    public private(set) var droppedSteps: Set<Int> = []

    /// The page to open after the first boot instead of the shell's `initial_to`: the
    /// page the app showed before it updated itself (`--to`). Used once.
    var startPage: String?

    public init(settings: SessionSettings) {
        self.settings = settings
        startPage = settings.startPage
    }

    // MARK: Derived

    /// The page on screen: the opened page, else the index page. Control's session is on it.
    public var pageOnScreen: PageMessage? { opened ?? index }

    /// Whether the page on screen is being edited: it holds a form or a confirm.
    public var isEditing: Bool { pageOnScreen.map(Self.asks) ?? false }

    /// Whether a page asks something: it holds a form or a confirm. Such a page is shown
    /// over the columns, as an action's pages are.
    public static func asks(_ page: PageMessage) -> Bool {
        (page.blocks ?? []).contains { block in
            switch block.content {
            case .form, .confirm: true
            default: false
            }
        }
    }

    /// Where leaving a page goes, as the page says: its confirm's or form's `cancel_to`,
    /// else its `back`.
    static func cancelTarget(_ page: PageMessage?) -> String? {
        guard let page else { return nil }
        for block in page.blocks ?? [] {
            switch block.content {
            case .confirm(let confirm): return confirm.cancelTo
            case .form(let form): if let to = form.cancelTo { return to }
            default: continue
            }
        }
        return page.back
    }

    var isOver: Bool {
        if case .ended = connection { true } else { false }
    }

    // MARK: Inputs

    public enum Input: Sendable, Equatable {
        case start
        case stop
        /// The connection is ready.
        case ready
        /// The connection closed.
        case closed
        /// A line from Control.
        case line(Data)
        /// The retry `scheduleRetry` asked for is due.
        case retry
        /// The reconcile interval passed.
        case tick
        case handshakeTimedOut
        case bootTimedOut(serial: Int)
        /// The user chose a tab in the sidebar.
        case selectTab(id: String)
        /// The user chose a group of the middle column's page (`groups`): its page goes there.
        case filter(to: String)
        /// The user opened a page Control named (a row's `to`); an action being taken ends.
        case open(to: String)
        /// The user took an action a block of the page declares: its `submit_to` is
        /// submitted as it is; else its `to` (a confirm, a form or a menu of more actions)
        /// is opened over the page it was taken on.
        case act(ActionModel)
        /// The user left the page shown over the columns, an action's or one that asks
        /// (Cancel, Esc): its `cancel_to`, else its `back`, else the page the action was
        /// taken on, is opened.
        case leave
        /// The user typed into the page on screen.
        case edit(name: String, value: String)
        /// The user gave a call a block of the page declares (a choice's `answer`), with
        /// the values it asks for: sent as it is, as `submit`. `label` says what is sent
        /// (the button's), for the pending cue.
        case submit(call: CallModel, values: [String: String], label: String? = nil)
        /// A line from the steer agent.
        case steerLine(Data)
        /// The steer agent stopped (or could not be started), and why.
        case steerGone(String)
        /// Run the proposed plan's kept steps, with their values.
        case runPlan
        /// Keep or drop a step of the proposed plan.
        case togglePlanStep(n: Int)
        /// Stop a running plan before its next step.
        case stopPlan
        /// Close the plan: cancel it while it is being made or proposed; close it once over.
        case closePlan
    }

    public mutating func handle(_ input: Input) -> [Effect] {
        let effects = apply(input)
        settlePending()
        return effects
    }

    /// The pending cue goes once what it waited for is answered: the page opened, the
    /// submit replied to, the connection lost. The agent's goes with its first word.
    private mutating func settlePending() {
        guard let pending else { return }
        switch pending.kind {
        case .opening: if expected == nil || connection != .connected { self.pending = nil }
        case .sending: if !submitting { self.pending = nil }
        case .asking: break
        }
    }

    private mutating func apply(_ input: Input) -> [Effect] {
        switch input {
        case .start:
            guard connection == .idle else { return [] }
            connection = .connecting
            return [.connect]
        case .stop:
            guard !isOver else { return [] }
            connection = .ended(.stopped)
            return [.close]
        case .ready:
            guard connection == .connecting else { return [] }
            connection = .handshake
            phase = .welcome
            let hello = HelloRequest(client: settings.client, env: settings.env, spec: Contract.version, surface: "console")
            return [.send(.hello(hello)), .handshakeDeadline]
        case .closed:
            guard !isOver, connection != .idle, connection != .retrying else { return [] }
            return disconnect(closing: false)
        case .line(let line):
            guard connection == .handshake || connection == .connected else { return [] }
            guard let message = try? WireLine.decode(ControlMessage.self, from: line) else { return [] }
            return receive(message)
        case .retry:
            guard connection == .retrying else { return [] }
            connection = .connecting
            return [.connect]
        case .tick:
            return tick()
        case .handshakeTimedOut:
            guard connection == .handshake || connection == .connected,
                  phase == .welcome || phase == .compatibility else { return [] }
            return disconnect(closing: true)
        case .bootTimedOut(let serial):
            guard connection == .connected, bootPending, serial == bootSerial else { return [] }
            bootFailure = .timedOut
            // Only hello's boot is the connection's: a later one is tried again next tick.
            guard phase == .boot else {
                bootPending = false
                shellStale = true
                return []
            }
            return disconnect(closing: true)
        case .selectTab(let id):
            return selectTab(id)
        case .filter(let to):
            return filter(to)
        case .open(let to):
            guard connection == .connected, phase == .ready || phase == .content else { return [] }
            if let action {
                opened = action.from
                self.action = nil
            }
            dropOpening()
            return navigate(to, column: .opened)
        case .act(let model):
            if let intent = Self.agentIntent(model.to) { return ask(model, intent: intent) }
            guard connection == .connected, phase == .ready || phase == .content else { return [] }
            if let call = model.submitTo {
                let effects = apply(.submit(call: call, values: [:], label: model.label))
                if !effects.isEmpty { pending = Pending(kind: .sending, label: model.label, action: model) }
                return effects
            }
            guard let to = model.to, Page.match(to) != nil else { return [] }
            if action == nil { action = Action(from: opened) }
            let effects = navigate(to, column: .opened)
            pending = Pending(kind: .opening, label: model.label, action: model)
            return effects
        case .leave:
            guard connection == .connected, phase == .ready || phase == .content,
                  action != nil || (opened.map(Self.asks) ?? false) else { return [] }
            let from = action?.from
            // The page shown over the columns, once it is on screen (until then, the page
            // the action was taken on).
            let page = opened?.path == from?.path ? nil : opened
            guard let target = Self.cancelTarget(page) ?? from?.path ?? index?.path else { return [] }
            draft = [:]
            dropOpening()
            if target == index?.path {
                opened = nil
                return navigate(target, column: .index)
            }
            opened = from
            action = nil
            return navigate(target, column: .opened)
        case .edit(let name, let value):
            guard isEditing else { return [] }
            draft[name] = value
            return []
        case .submit(let call, let values, let label):
            guard connection == .connected, phase == .ready || phase == .content else { return [] }
            // Not while a page is on its way (its reply would drop the submit's), and once
            // only until Control replies.
            guard expected == nil, inFlight == nil, !submitting else { return [] }
            guard let endpoint = call.endpoint else { return [] }
            submitting = true
            answer = nil
            pending = Pending(kind: .sending, label: label, action: nil)
            let request = SubmitRequest(endpoint: endpoint, params: call.params ?? [:], values: values)
            return [.send(.submit(request))]
        case .steerLine(let line):
            guard let message = try? WireLine.decode(SteerMessage.self, from: line) else { return [] }
            return steer(message)
        case .steerGone(let why):
            if pending?.kind == .asking { pending = nil }
            if let plan, ["planning", "running"].contains(plan.state) {
                self.plan?.state = "failed"
                self.plan?.title = "The agent stopped"
                self.plan?.summary = why
            }
            notice = NoticeMessage(text: "The agent stopped: \(why)", tone: "error")
            return []
        case .runPlan:
            return runPlan()
        case .togglePlanStep(let n):
            guard plan?.state == "proposed", plan?.steps?.contains(where: { $0.n == n }) == true else { return [] }
            if droppedSteps.contains(n) { droppedSteps.remove(n) } else { droppedSteps.insert(n) }
            return []
        case .stopPlan:
            guard plan?.state == "running" else { return [] }
            notice = NoticeMessage(text: "Stopping after this step…", tone: "pending")
            return [.steer(.stop)]
        case .closePlan:
            guard let plan, plan.state != "running" else { return [] }
            self.plan = nil
            droppedSteps = []
            if pending?.kind == .asking { pending = nil }
            return ["planning", "proposed"].contains(plan.state) ? [.steer(.cancel)] : []
        }
    }

    /// An `open` the user asked for replaces an action's page that is on its way.
    private mutating func dropOpening() {
        if pending?.kind == .opening { pending = nil }
    }

    // MARK: The agent

    /// The intent of an action that asks the agent (`agent:<intent>`), else nil.
    public static func agentIntent(_ to: String?) -> String? {
        guard let to, to.hasPrefix("agent:") else { return nil }
        let intent = String(to.dropFirst("agent:".count))
        return intent.isEmpty ? nil : intent
    }

    /// The page that declares `action` (a block's or the page's): the opened page (an
    /// action's page over it first), else the index page; else the page on screen.
    func page(declaring action: ActionModel) -> PageMessage? {
        let pages = [opened, self.action?.from, index].compactMap { $0 }
        return pages.first { page in
            (page.blocks ?? []).contains { block in
                switch block.content {
                case .item(let item): (item.actions ?? []).contains(action)
                case .list(let list): (list.actions ?? []).contains(action)
                default: false
                }
            }
        } ?? pageOnScreen
    }

    /// Ask the agent about the page the action is on, with the action's intent, as the
    /// TUI does: its label is the request, and its plan shows "Planning…" at once.
    private mutating func ask(_ model: ActionModel, intent: String) -> [Effect] {
        guard let on = page(declaring: model)?.path else { return [] }
        // A plan being made or run is the agent's one task; it is closed first.
        if let plan, ["planning", "running"].contains(plan.state) { return [] }
        plan = PlanBlock(title: "Planning…", request: model.label, state: "planning", steps: [])
        droppedSteps = []
        pending = Pending(kind: .asking, label: model.label, action: model)
        return [.steer(.ask(AskRequest(intent: intent, on: on, request: model.label ?? "")))]
    }

    private mutating func steer(_ message: SteerMessage) -> [Effect] {
        if pending?.kind == .asking { pending = nil }
        switch message {
        case .plan(let message):
            // A plan after the user closed it is not shown again.
            guard let old = plan else { return [] }
            guard case .plan(let block)? = message.block?.content else {
                notice = NoticeMessage(text: "The agent sent a plan this app cannot show.", tone: "error")
                return []
            }
            // A new proposal starts with every step kept, as the agent made it.
            if block.state == "proposed", old.state != "proposed" { droppedSteps = [] }
            // "Stopping after this step…" is answered by the plan itself once it ends.
            if old.state == "running", ["done", "stopped", "failed"].contains(block.state), notice?.tone == "pending" {
                notice = nil
            }
            plan = block
        case .notice(let message):
            notice = message
        case .undecodable:
            notice = NoticeMessage(text: "The agent sent a plan this app cannot show.", tone: "error")
        case .unknown:
            break
        }
        return []
    }

    /// Run the kept steps, in order, with the values the agent gave them (the TUI's `run`).
    private mutating func runPlan() -> [Effect] {
        guard let plan, plan.state == "proposed" else { return [] }
        let kept = (plan.steps ?? []).filter { step in
            step.state != "dropped" && !(step.n.map { droppedSteps.contains($0) } ?? false)
        }
        if kept.isEmpty {
            notice = NoticeMessage(text: "Every step is dropped; cancel this plan.", tone: "info")
            return []
        }
        let blocked = kept.filter { $0.state == "blocked" }
        guard blocked.isEmpty else {
            let numbers = blocked.map { $0.n.map(String.init) ?? "?" }.joined(separator: ", ")
            notice = NoticeMessage(text: "Step \(numbers) cannot run; drop it before running.", tone: "error")
            return []
        }
        let steps = kept.map { step in
            RunStepModel(n: step.n, values: step.inputs.map { inputs in
                Dictionary(inputs.compactMap { input in input.name.map { ($0, input.value ?? "") } }) { first, _ in first }
            })
        }
        return [.steer(.run(RunRequest(steps: steps)))]
    }

    // MARK: Messages

    mutating func receive(_ message: ControlMessage) -> [Effect] {
        switch message {
        case .welcome(let welcome):
            return self.welcome(welcome)
        case .bye(let bye):
            connection = .ended(.bye(bye.text ?? ""))
            return [.close]
        case .notice(let notice):
            self.notice = notice
            return answered(by: notice)
        case .bootShell(let shell):
            return boot(.success(shell))
        case .bootError(let error):
            return boot(.failure(.control(error.error ?? "")))
        case .pageOpen(let page): return self.page(page, .open)
        case .pageStored(let page): return self.page(page, .stored)
        case .pageRefused(let page): return self.page(page, .refused)
        case .pageReconcile(let page): return self.page(page, .reconcile)
        case .pageHint(let page): return self.page(page, .hint)
        case .pagePending(let page): return self.page(page, .pending)
        case .undecodable(let raw, let reason):
            return unreadable(raw, reason)
        default:
            // Unknown messages, and those of later slices, are skipped.
            return []
        }
    }

    /// A message of a known op whose fields do not decode. Like the TUI, which goes by
    /// `op` alone, it still answers what the session waits for: a welcome the session
    /// cannot read ends it; a boot reply fails the boot (the shell stays, stale, and the
    /// connection stays); a page is a page for the phases, and one answering the `open`
    /// on the wire ends that `open`. Anything else is skipped.
    private mutating func unreadable(_ raw: JSONValue, _ reason: Fallback.Reason) -> [Effect] {
        switch raw["op"]?.string {
        case "welcome":
            guard connection == .handshake, phase == .welcome else { return [] }
            connection = .ended(.unreadableWelcome(reason))
            return [.close]
        case "boot":
            return boot(.failure(.unreadable(reason)))
        case "page":
            if let effects = pageForPhase() { return effects }
            guard raw["reason"]?.string == Reason.open.rawValue, let expected else { return [] }
            if let effects = newerWish() { return effects }
            self.expected = nil
            inFlight = nil
            phase = .ready
            openFailure = OpenFailure(path: expected, reason: reason)
            return []
        default:
            return []
        }
    }

    private mutating func welcome(_ welcome: WelcomeMessage) -> [Effect] {
        guard connection == .handshake, phase == .welcome else { return [] }
        // Any contract version is welcome (D-0105): a difference is only a status warning.
        guard welcome.env == settings.env, welcome.surface == "console" else {
            connection = .ended(.incompatible(welcome))
            return [.close]
        }
        connection = .connected
        lost = nil
        controlSpec = welcome.spec
        phase = .compatibility
        notice = nil
        return []
    }

    private mutating func boot(_ result: Result<Shell, BootFailure>) -> [Effect] {
        guard bootPending else { return [] }
        bootPending = false
        let checked: Result<Shell, BootFailure> = result.flatMap { shell in
            if let problem = Self.check(shell, env: settings.env) { return .failure(.invalid(problem)) }
            return .success(shell)
        }
        switch checked {
        case .failure(let failure):
            bootFailure = failure
            shellStale = true
            return []
        case .success(let shell):
            self.shell = shell
            shellStale = false
            bootFailure = nil
            for tab in shell.tabs ?? [] {
                if let to = tab.to, let count = tab.count { groupCounts[to] = count }
                for group in tab.groups ?? [] {
                    if let to = group.to, let count = group.count { groupCounts[to] = count }
                }
            }
            if phase == .boot { return start(shell) }
            return keepTab(shell)
        }
    }

    /// After hello's boot: open the start (`initial_to`, which is the page it was on when
    /// boot asked for it), or, while editing, the page on screen as it is.
    private mutating func start(_ shell: Shell) -> [Effect] {
        phase = .content
        let wished = startPage.flatMap { Page.match($0) != nil ? $0 : nil }
        startPage = nil
        let initialTo = shell.initialTo ?? ""
        let target = isEditing ? (pageOnScreen?.path ?? initialTo) : (wished ?? initialTo)
        let column: Column
        if let opened, opened.path == target {
            column = .opened
        } else if Self.tab(showing: target, in: shell) != nil {
            column = .index
        } else {
            column = .opened
        }
        if column == .index { opened = nil; draft = [:] }
        activeTab = shell.activeTab ?? Self.tab(showing: target, in: shell)?.id ?? activeTab
        return navigate(target, column: column)
    }

    /// A later boot: the shell changes, the page does not, unless the tab the user is on
    /// is gone and nothing is being edited.
    private mutating func keepTab(_ shell: Shell) -> [Effect] {
        guard let activeTab, (shell.tabs ?? []).contains(where: { $0.id == activeTab }) else {
            self.activeTab = shell.activeTab
            guard !isEditing, expected == nil else { return [] }
            if let index, Self.tab(showing: index.path, in: shell) != nil { return [] }
            opened = nil
            draft = [:]
            index = nil
            self.activeTab = shell.activeTab ?? shell.tabs?.first(where: { $0.to == shell.initialTo })?.id
            return navigate(shell.initialTo ?? "", column: .index)
        }
        return []
    }

    /// A notice that answers a submit: `ok` (stored) or `error` (not sent, refused). Control
    /// sends it before the page stored or refused, and alone when it shows no page (the
    /// user opened another meanwhile, or nothing was sent): the submit is over either way.
    /// Stored, the action is done and its pages close at once, onto the page it was taken
    /// on; the stored page, if one follows, is shown as usual. Not stored, the sheet stays,
    /// saying why.
    private mutating func answered(by notice: NoticeMessage) -> [Effect] {
        guard submitting, notice.tone == "ok" || notice.tone == "error" else { return [] }
        submitting = false
        guard notice.tone == "ok" else {
            answer = notice
            return []
        }
        if let action {
            storedAction = action
            draft = [:]
            opened = action.from
            self.action = nil
        } else if let opened, Self.asks(opened) {
            // A page that asks, opened by itself (not from an action): it closes too.
            storedAction = Action(from: nil)
            draft = [:]
            self.opened = nil
        }
        return []
    }

    private mutating func page(_ page: PageMessage, _ reason: Reason) -> [Effect] {
        if let effects = pageForPhase() { return effects }
        // Control's reply to a submit: the page it was stored or refused on.
        if reason == .stored || reason == .refused { submitting = false }
        let stored = storedAction
        if reason != .hint, reason != .reconcile, reason != .pending { storedAction = nil }

        if expected != nil {
            // Only `open` answers an `open` (the TUI's rule); pushes and other replies wait.
            guard reason == .open else { return [] }
            if let effects = newerWish() { return effects }
            // The page asked for (Control may answer another path: a redirect).
            show(page, reason, in: expectedColumn)
            expected = nil
            inFlight = nil
            // An open after a submit: Control shows the page opened, not the submit's.
            submitting = false
            phase = .ready
            return []
        }

        if reason == .open || reason == .stored || reason == .refused {
            // Stored: the action is done, and its pages close; the page stored is shown.
            if reason == .stored, action != nil || stored != nil {
                action = nil
                if page.path == index?.path { opened = nil }
            }
            show(page, reason, in: column(showing: page.path) ?? .opened)
            return []
        }

        // A page Control pushed: drawn only where its path is shown, never older over newer.
        guard let column = column(showing: page.path) else { return [] }
        let current = column == .opened ? opened : index
        if let old = current?.position, let new = page.position, new < old { return [] }
        show(page, reason, in: column)
        return []
    }

    /// What any page, read or not, does before the start page: hello's page is consumed
    /// (the shell comes from boot), and none counts before it. Nil once pages are shown.
    private mutating func pageForPhase() -> [Effect]? {
        switch phase {
        case .compatibility:
            phase = .boot
            return sendBoot()
        case .welcome, .boot:
            return []
        case .content, .ready:
            return nil
        }
    }

    /// The `open` on the wire is for a page the user no longer wants: ask for the one
    /// wished last, now. Nil when the answer is for the page wished.
    private mutating func newerWish() -> [Effect]? {
        guard let inFlight, let expected, inFlight != expected else { return nil }
        self.inFlight = nil
        return navigate(expected, column: expectedColumn)
    }

    private func column(showing path: String?) -> Column? {
        guard let path else { return nil }
        if opened?.path == path { return .opened }
        if index?.path == path { return .index }
        return nil
    }

    private mutating func show(_ page: PageMessage, _ reason: Reason, in column: Column) {
        if reason != .hint, reason != .reconcile, reason != .pending { answer = nil }
        switch column {
        case .index:
            index = page
            if opened == nil { syncActiveTab() }
        case .opened:
            if opened?.path != page.path { draft = [:] }
            opened = page
            // Back on the page the action was taken on: the action is over.
            if page.path == action?.from?.path { action = nil }
        }
        let update = Update(reason: reason, at: page.at, position: page.position, path: page.path ?? "")
        lastUpdate = update
        if reason == .hint { lastHint = update }
        for block in page.blocks ?? [] {
            if case .groups(let groups) = block.content {
                for group in groups.groups ?? [] {
                    if let to = group.to { groupCounts[to] = group.count }
                }
            }
        }
    }

    /// The tab whose index page is in the middle column: its own page or one of its groups.
    private mutating func syncActiveTab() {
        guard let shell, let index else { return }
        if let tab = Self.tab(showing: index.path, in: shell) { activeTab = tab.id }
    }

    /// The tab that shows `path` in the middle column: the tab's page, or one of its groups.
    static func tab(showing path: String?, in shell: Shell) -> ShellTabModel? {
        guard let path else { return nil }
        return (shell.tabs ?? []).first { $0.to == path || ($0.groups ?? []).contains { $0.to == path } }
    }

    // MARK: What the user does

    private mutating func selectTab(_ id: String) -> [Effect] {
        guard connection == .connected, phase == .ready || phase == .content else { return [] }
        guard let tab = shell?.tabs?.first(where: { $0.id == id }), let to = tab.to else { return [] }
        guard !isEditing else { return [] }
        activeTab = tab.id
        opened = nil
        draft = [:]
        if index?.path != to { index = nil }
        return navigate(to, column: .index)
    }

    /// Show one group of a tab's page in the middle column, on that tab (any tab's group
    /// may be chosen, from anywhere).
    private mutating func filter(_ to: String) -> [Effect] {
        guard connection == .connected, phase == .ready || phase == .content else { return [] }
        guard !isEditing else { return [] }
        if let shell, let tab = Self.tab(showing: to, in: shell), tab.id != activeTab {
            activeTab = tab.id
            index = nil
        }
        opened = nil
        draft = [:]
        return navigate(to, column: .index)
    }

    /// Ask for a page Control named; only one `open` is on the wire, a newer wish waits.
    private mutating func navigate(_ target: String, column: Column) -> [Effect] {
        guard Page.match(target) != nil else { return [] }
        expected = target
        expectedColumn = column
        openFailure = nil
        answer = nil
        storedAction = nil
        guard inFlight == nil else { return [] }
        inFlight = target
        return [.send(.open(OpenRequest(to: target)))]
    }

    // MARK: Time and connection

    private mutating func tick() -> [Effect] {
        guard connection == .connected else { return [] }
        var effects: [Effect] = []
        if phase == .boot || phase == .ready, !bootPending, expected == nil {
            effects += sendBoot()
        }
        if phase == .ready, expected == nil, !isEditing {
            effects.append(.send(.refresh))
        }
        return effects
    }

    private mutating func sendBoot() -> [Effect] {
        bootPending = true
        bootSerial += 1
        return [.send(.boot(BootRequest(to: pageOnScreen?.path))), .bootDeadline(serial: bootSerial)]
    }

    /// The connection is gone: say so and try again in 2 s. Pages and the shell stay on
    /// screen, the shell stale, until the connection is back.
    private mutating func disconnect(closing: Bool) -> [Effect] {
        lost = connection == .connecting ? .unreachable : .silent
        connection = .retrying
        phase = .welcome
        bootPending = false
        expected = nil
        inFlight = nil
        submitting = false
        shellStale = true
        return (closing ? [.close] : []) + [.scheduleRetry]
    }

    // MARK: Checks

    /// The index pages a tab may open: the ones Control's shell serves as tabs
    /// (`AtlasControl.Shell`): what is assigned, a kind's list, the workers and the
    /// supervision screens (Open for you, Supervised by you; M3b P4).
    static let tabPages: Set<Page> = [.home, .list, .workers, .machines, .openForYou, .supervisedByYou]

    /// What is wrong with `shell` for `env`, if anything (the TUI's `validate_shell`).
    /// A boot shell must name its environment, its tabs (an id and a page each) and the
    /// start page; other fields are checked only when present (D-0105).
    static func check(_ shell: Shell, env: String) -> ShellProblem? {
        guard shell.env == env else { return .env }
        guard optionalText(shell.title, limit: 128) else { return .title }
        guard optionalText(shell.revision, limit: 128) else { return .revision }
        let tabs = shell.tabs ?? []
        guard (1...tabLimit).contains(tabs.count) else { return .tabCount }
        for (index, tab) in tabs.enumerated() {
            guard text(tab.id, limit: 64), optionalText(tab.label, limit: 128), path(tab.to),
                  tab.section.map({ ["work", "browse"].contains($0) }) ?? true,
                  let page = tab.to.flatMap({ Page.match($0)?.page }), tabPages.contains(page)
            else { return .tab(index: index) }
        }
        guard Set(tabs.map(\.id)).count == tabs.count,
              Set(tabs.map(\.to)).count == tabs.count else { return .duplicateTab }
        guard path(shell.initialTo) else { return .initialTo }
        if let active = shell.activeTab, !tabs.contains(where: { $0.id == active }) { return .activeTab }
        return nil
    }

    private static func optionalText(_ value: String?, limit: Int) -> Bool {
        value.map { text($0, limit: limit) } ?? true
    }

    private static func path(_ value: String?) -> Bool {
        guard let value else { return false }
        return text(value, limit: 2048) && Page.match(value) != nil
    }

    private static func text(_ value: String?, limit: Int) -> Bool {
        guard let value else { return false }
        return value.utf8.count <= limit
            && !value.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
