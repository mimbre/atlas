import AtlasControlKit
import Foundation

/// The session with Control as plain state and rules, no actor, no time and no socket:
/// each input (a connection event, a message, a tick of the clock, what the user does)
/// changes the state and says what to do (`Effect`). `Session` carries the effects out;
/// tests drive both.
///
/// The rules are the TUI's (`AtlasTui.Console`, `AtlasTui.App`): hello with the contract
/// version; a welcome for another environment, version or surface, or a bye, ends the
/// session; the page hello brings is consumed, then `boot` gives the shell and `open` its
/// start; one `open` on the wire at a time; a dropped connection retries every 2 s and, on
/// return, boots for the page it was on and opens it again; every `reconcileSeconds` it
/// boots again (shell changes) and sends `refresh`, except while a page with a form or
/// confirm is being edited; a draft is never replaced by a page Control pushes; only an
/// `open` answers an `open`. A message of a known op that does not decode still answers
/// what the session waits for, as a failure. Unlike the TUI, only hello's boot that times
/// out drops the connection: a later one marks the shell stale and is tried again
/// (Control may be busy reading a page).
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
        /// Control said bye (another environment, a client too old, …), with its text.
        case bye(String)
        /// Control's welcome names another environment, contract version or surface.
        case incompatible(WelcomeMessage)
        /// Control's welcome does not decode, and why (the TUI ends such a session too).
        case unreadableWelcome(Fallback.Reason)
        /// The app stopped it.
        case stopped
    }

    /// Why the last boot gave no shell. The last good shell stays, marked stale.
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
        case spec
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
    public private(set) var opened: PageMessage?
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
    /// What waits for the user, in the model's words (`count` of the last page shown).
    public private(set) var count: String?
    /// The last count of each tab and group, by its `to`, as boot or a page's `groups` said
    /// it, whichever came last: what the sidebar shows under every tab, also before it is
    /// opened.
    public private(set) var groupCounts: [String: Int] = [:]
    /// A submit is sent and Control has not replied to it (a page stored or refused, or
    /// one opened since); another waits until it has.
    public private(set) var submitting = false

    public init(settings: SessionSettings) {
        self.settings = settings
    }

    // MARK: Derived

    /// The page on screen: the opened page, else the index page. Control's session is on it.
    public var pageOnScreen: PageMessage? { opened ?? index }

    /// Whether the page on screen is being edited: it holds a form or a confirm.
    public var isEditing: Bool {
        pageOnScreen?.blocks.contains { block in
            switch block.content {
            case .form, .confirm: true
            default: false
            }
        } ?? false
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
        /// The user opened a page Control named (a row's or an action's `to`).
        case open(to: String)
        /// The user typed into the page on screen.
        case edit(name: String, value: String)
        /// The user gave a call a block of the page declares (a choice's `answer`), with
        /// the values it asks for: sent as it is, as `submit`.
        case submit(call: CallModel, values: [String: String])
    }

    public mutating func handle(_ input: Input) -> [Effect] {
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
            return navigate(to, column: .opened)
        case .edit(let name, let value):
            guard isEditing else { return [] }
            draft[name] = value
            return []
        case .submit(let call, let values):
            guard connection == .connected, phase == .ready || phase == .content else { return [] }
            // Not while a page is on its way (its reply would drop the submit's), and once
            // only until Control replies.
            guard expected == nil, inFlight == nil, !submitting else { return [] }
            submitting = true
            let request = SubmitRequest(endpoint: call.endpoint, params: call.params ?? [:], values: values)
            return [.send(.submit(request))]
        }
    }

    // MARK: Messages

    mutating func receive(_ message: ControlMessage) -> [Effect] {
        switch message {
        case .welcome(let welcome):
            return self.welcome(welcome)
        case .bye(let bye):
            connection = .ended(.bye(bye.text))
            return [.close]
        case .notice(let notice):
            self.notice = notice
            return []
        case .bootShell(let shell):
            return boot(.success(shell))
        case .bootError(let error):
            return boot(.failure(.control(error.error)))
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
        guard welcome.env == settings.env, welcome.spec == Contract.version, welcome.surface == "console" else {
            connection = .ended(.incompatible(welcome))
            return [.close]
        }
        connection = .connected
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
            for tab in shell.tabs {
                if let count = tab.count { groupCounts[tab.to] = count }
                for group in tab.groups ?? [] {
                    if let count = group.count { groupCounts[group.to] = count }
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
        let target = isEditing ? (pageOnScreen?.path ?? shell.initialTo) : shell.initialTo
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
        guard let activeTab, shell.tabs.contains(where: { $0.id == activeTab }) else {
            self.activeTab = shell.activeTab
            guard !isEditing, expected == nil else { return [] }
            if let index, Self.tab(showing: index.path, in: shell) != nil { return [] }
            opened = nil
            draft = [:]
            index = nil
            self.activeTab = shell.activeTab ?? shell.tabs.first(where: { $0.to == shell.initialTo })?.id
            return navigate(shell.initialTo, column: .index)
        }
        return []
    }

    private mutating func page(_ page: PageMessage, _ reason: Reason) -> [Effect] {
        if let effects = pageForPhase() { return effects }
        // Control's reply to a submit: the page it was stored or refused on.
        if reason == .stored || reason == .refused { submitting = false }

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

    private func column(showing path: String) -> Column? {
        if opened?.path == path { return .opened }
        if index?.path == path { return .index }
        return nil
    }

    private mutating func show(_ page: PageMessage, _ reason: Reason, in column: Column) {
        switch column {
        case .index:
            index = page
            if opened == nil { syncActiveTab() }
        case .opened:
            if opened?.path != page.path { draft = [:] }
            opened = page
        }
        let update = Update(reason: reason, at: page.at, position: page.position, path: page.path)
        lastUpdate = update
        if reason == .hint { lastHint = update }
        count = page.count
        for block in page.blocks {
            if case .groups(let groups) = block.content {
                for group in groups.groups { groupCounts[group.to] = group.count }
            }
        }
    }

    /// The tab whose index page is in the middle column: its own page or one of its groups.
    private mutating func syncActiveTab() {
        guard let shell, let index else { return }
        if let tab = Self.tab(showing: index.path, in: shell) { activeTab = tab.id }
    }

    /// The tab that shows `path` in the middle column: the tab's page, or one of its groups.
    static func tab(showing path: String, in shell: Shell) -> ShellTabModel? {
        shell.tabs.first { $0.to == path || ($0.groups ?? []).contains { $0.to == path } }
    }

    // MARK: What the user does

    private mutating func selectTab(_ id: String) -> [Effect] {
        guard connection == .connected, phase == .ready || phase == .content else { return [] }
        guard let tab = shell?.tabs.first(where: { $0.id == id }) else { return [] }
        guard !isEditing else { return [] }
        activeTab = tab.id
        opened = nil
        draft = [:]
        if index?.path != tab.to { index = nil }
        return navigate(tab.to, column: .index)
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
    static let tabPages: Set<Page> = [.home, .list, .workers, .openForYou, .supervisedByYou]

    /// What is wrong with `shell` for `env`, if anything (the TUI's `validate_shell`).
    static func check(_ shell: Shell, env: String) -> ShellProblem? {
        guard shell.env == env else { return .env }
        guard shell.spec == Contract.version else { return .spec }
        guard text(shell.title, limit: 128) else { return .title }
        guard text(shell.revision, limit: 128) else { return .revision }
        guard (1...tabLimit).contains(shell.tabs.count) else { return .tabCount }
        for (index, tab) in shell.tabs.enumerated() {
            guard text(tab.id, limit: 64), text(tab.label, limit: 128), path(tab.to),
                  ["work", "browse"].contains(tab.section), let page = Page.match(tab.to)?.page, tabPages.contains(page)
            else { return .tab(index: index) }
        }
        guard Set(shell.tabs.map(\.id)).count == shell.tabs.count,
              Set(shell.tabs.map(\.to)).count == shell.tabs.count else { return .duplicateTab }
        guard path(shell.initialTo) else { return .initialTo }
        if let active = shell.activeTab, !shell.tabs.contains(where: { $0.id == active }) { return .activeTab }
        return nil
    }

    private static func path(_ value: String) -> Bool {
        text(value, limit: 2048) && Page.match(value) != nil
    }

    private static func text(_ value: String, limit: Int) -> Bool {
        value.utf8.count <= limit
            && !value.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
