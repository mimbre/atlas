import AtlasControlKit

/// What the shell shows, from the session: the title bar, the sidebar and which page goes
/// in which column. Only what `boot` and the pages sent; the app adds no tab of its own.
public struct ShellViewModel: Sendable, Equatable {
    /// A tab in the sidebar, in boot's order. The first nine have `⌘1`–`⌘9`.
    public struct Tab: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var to: String
        /// Where the sidebar lists it: "work" (what waits for the user) or "browse".
        public var section: String
        /// Its icon, a semantic name boot gives (the app draws it as a symbol).
        public var icon: String?
        public var shortcut: Int?
        /// How many items its page has (its All group's count), as boot or a page said last.
        public var count: Int?
        /// Whether its count is what waits for the user (what is assigned to them), not a
        /// plain count.
        public var forYou: Bool
        /// The groups of its page, under it in the sidebar whichever tab is shown.
        public var groups: [Group]
    }

    /// A group of a tab's page, from boot: choosing one shows only its items in the
    /// middle column, on its tab. Its count is the last one boot or a page gave.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String { to }
        public var label: String
        public var count: Int?
        /// Whether its count is what waits for the user, as its tab's.
        public var forYou: Bool
        public var to: String
        /// Its kind's icon, a semantic name, for a group of one kind; nil otherwise.
        public var icon: String? = nil
    }

    /// The shell's title; nil before the first boot.
    public var title: String?
    /// The viewer's name, as Control sent it (only to a person); nil when none.
    public var name: String?
    /// The line under the viewer's name, in full as Control sent it ("assistant: coordinator");
    /// nil when none.
    public var assistant: String?
    /// The environment: the shell's, else the one the app was started for.
    public var env: String
    /// Production gets no mark; any other environment a warning tag in the foot.
    public var isProduction: Bool
    public var tabs: [Tab]
    public var activeTab: String?
    /// The tabs may be out of date (not booted on this connection, or the last boot failed).
    public var stale: Bool
    public var bootFailure: SessionState.BootFailure?
    /// The middle column: the active tab's index page, or one of its groups.
    public var index: PageMessage?
    /// The right column: the page opened from a row (under an action's page, the page the
    /// action was taken on).
    public var opened: PageMessage?
    /// The tab's page is a block page (it has a `header` block; a list page has none): it is
    /// shown as an opened page is, in the page column with its details beside it and its
    /// actions in the toolbar, with no list column.
    public var indexIsPage: Bool { index.map(Self.isBlockPage) ?? false }

    /// A page that names itself with a `header` block, as an opened item's does.
    public static func isBlockPage(_ page: PageMessage) -> Bool {
        (page.blocks ?? []).contains { if case .header = $0.content { true } else { false } }
    }
    /// The page of the action being taken (its confirm, form or more actions), shown over
    /// the columns; nil while it is on its way.
    public var sheet: PageMessage?
    /// What the user typed into the sheet's form.
    public var draft: [String: String]
    /// A submit waits for Control's reply.
    public var submitting: Bool
    /// What the user did that is not answered yet: its button, the sheet and the status
    /// bar show it at once.
    public var pending: SessionState.Pending?
    /// Why the sheet's submit was not stored, when Control said so only in a notice.
    public var answer: NoticeMessage?
    /// The agent's plan, shown over the columns (over an action's sheet too); nil when none.
    public var plan: PlanBlock?
    /// The steps of the proposed plan the user dropped.
    public var droppedSteps: Set<Int>

    /// The row selected: the page asked for in the right column while it is on its way (the
    /// clicked row stays selected while its page loads, as the sidebar's group does), else
    /// the page displayed.
    public var selectedPath: String?
    /// The group the middle column shows, or was asked to show (chosen in the sidebar, its
    /// page still on the way), when it is one rather than its tab's page: the sidebar
    /// selects it once, on the click, and keeps it while its page loads.
    public var activeGroup: String?

    public init(_ state: SessionState) {
        let shell = state.shell
        title = shell?.title
        name = shell?.name.flatMap { $0.isEmpty ? nil : $0 }
        assistant = shell?.assistant.flatMap { $0.isEmpty ? nil : $0 }
        env = shell?.env ?? state.settings.env
        isProduction = env == "prod"
        // A tab without a page to go to cannot be shown.
        let shown = ((shell?.tabs ?? nil) ?? []).filter { $0.to != nil }
        tabs = shown.enumerated().map { offset, tab in
            let to = tab.to ?? ""
            return Tab(id: tab.id ?? to, label: tab.label ?? to, to: to, section: tab.section ?? "browse",
                       icon: tab.icon, shortcut: offset < 9 ? offset + 1 : nil, count: state.groupCounts[to],
                       forYou: tab.forYou ?? false,
                       groups: (tab.groups ?? []).compactMap { group in
                           group.to.map {
                               Group(label: group.label ?? $0, count: state.groupCounts[$0],
                                     forYou: group.forYou ?? false, to: $0, icon: group.icon)
                           }
                       })
        }
        activeTab = state.activeTab
        stale = state.shellStale && shell != nil
        bootFailure = state.bootFailure
        index = state.index
        // An action's page, once it is on screen, and any page that asks (a form or a
        // confirm) go over the columns; under it, the page the action was taken on.
        let page = state.opened
        if let page, let action = state.action, page.path != action.from?.path {
            opened = action.from
            sheet = page
        } else if let page, SessionState.asks(page) {
            opened = nil
            sheet = page
        } else {
            opened = page
            sheet = nil
        }
        draft = state.draft
        submitting = state.submitting
        pending = state.pending
        answer = state.answer
        plan = state.plan
        droppedSteps = state.droppedSteps
        let asked = state.expectedColumn == .opened ? state.expected : nil
        selectedPath = asked ?? (opened ?? index)?.path
        let middle = state.expectedColumn == .index ? state.expected ?? index?.path : index?.path
        activeGroup = middle.flatMap { path in tabs.lazy.flatMap(\.groups).first { $0.to == path }?.to }
    }

    /// The tab `⌘<number>` switches to.
    public func tab(shortcut number: Int) -> Tab? {
        tabs.first { $0.shortcut == number }
    }
}
