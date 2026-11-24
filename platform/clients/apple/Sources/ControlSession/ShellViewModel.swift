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
        /// The groups of its page, under it in the sidebar whichever tab is shown.
        public var groups: [Group]
    }

    /// A group of a tab's page, from boot: choosing one shows only its items in the
    /// middle column, on its tab. Its count is the last one boot or a page gave.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String { to }
        public var label: String
        public var count: Int?
        public var to: String
    }

    /// The shell's title; nil before the first boot.
    public var title: String?
    /// The shell's greeting of the viewer by name, in the model's words (Control sends it
    /// only to a person); nil when the shell has none.
    public var greeting: String?
    /// The environment: the shell's, else the one the app was started for.
    public var env: String
    /// Production wears the inverted badge, as in the TUI.
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
    /// The page of the action being taken (its confirm, form or more actions), shown over
    /// the columns; nil while it is on its way.
    public var sheet: PageMessage?
    /// What the user typed into the sheet's form.
    public var draft: [String: String]
    /// A submit waits for Control's reply.
    public var submitting: Bool

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
        greeting = shell?.greeting.flatMap { $0.isEmpty ? nil : $0 }
        env = shell?.env ?? state.settings.env
        isProduction = env == "prod"
        tabs = (shell?.tabs ?? []).enumerated().map { offset, tab in
            Tab(id: tab.id, label: tab.label, to: tab.to, section: tab.section, icon: tab.icon,
                shortcut: offset < 9 ? offset + 1 : nil, count: state.groupCounts[tab.to],
                groups: (tab.groups ?? []).map {
                    Group(label: $0.label, count: state.groupCounts[$0.to], to: $0.to)
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
