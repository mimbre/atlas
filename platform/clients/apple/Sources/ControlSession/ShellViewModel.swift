import AtlasControlKit

/// What the shell shows, from the session: the title bar, the sidebar and which page goes
/// in which column. Only what `boot` and the pages sent; the app adds no tab of its own.
public struct ShellViewModel: Sendable, Equatable {
    /// A tab in the sidebar, in boot's order. The first nine have `⌘1`–`⌘9`.
    public struct Tab: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var to: String
        public var shortcut: Int?
        /// How many items its page has, when the page says so (its own group's count).
        public var count: Int?
    }

    /// A group of the middle column's page (its `groups` block), under its tab in the
    /// sidebar: choosing one shows only its items there. A group that is a tab's own page
    /// is that tab, and gives the tab its count.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String { to }
        public var label: String
        public var count: Int
        public var to: String
        public var active: Bool
    }

    /// The shell's title; nil before the first boot.
    public var title: String?
    /// The environment: the shell's, else the one the app was started for.
    public var env: String
    /// Production wears the inverted badge, as in the TUI.
    public var isProduction: Bool
    public var tabs: [Tab]
    public var activeTab: String?
    /// The active tab's groups, from the page in the middle column.
    public var groups: [Group]
    /// The tabs may be out of date (not booted on this connection, or the last boot failed).
    public var stale: Bool
    public var bootFailure: SessionState.BootFailure?
    /// What waits for the user, in the model's words: the sidebar section's header.
    public var count: String?
    /// The middle column: the active tab's index page.
    public var index: PageMessage?
    /// The right column: the page opened from a row.
    public var opened: PageMessage?

    /// Actual displayed identity, never the pending open request.
    public var selectedPath: String?

    public init(_ state: SessionState) {
        let shell = state.shell
        title = shell?.title
        env = shell?.env ?? state.settings.env
        isProduction = env == "prod"
        let pageGroups: [GroupModel] = (state.index?.blocks ?? []).flatMap { block -> [GroupModel] in
            if case .groups(let groups) = block.content { return groups.groups }
            return []
        }
        tabs = (shell?.tabs ?? []).enumerated().map { offset, tab in
            Tab(id: tab.id, label: tab.label, to: tab.to, shortcut: offset < 9 ? offset + 1 : nil,
                count: pageGroups.first { $0.to == tab.to }?.count)
        }
        let tabPaths = Set(tabs.map(\.to))
        groups = pageGroups.filter { !tabPaths.contains($0.to) }.map {
            Group(label: $0.label, count: $0.count, to: $0.to, active: $0.active == true)
        }
        activeTab = state.activeTab
        stale = state.shellStale && shell != nil
        bootFailure = state.bootFailure
        count = state.count
        index = state.index
        opened = state.opened
        selectedPath = state.pageOnScreen?.path
    }

    /// The tab `⌘<number>` switches to.
    public func tab(shortcut number: Int) -> Tab? {
        tabs.first { $0.shortcut == number }
    }

    /// The group the middle column shows, when it shows one rather than its tab's page.
    public var activeGroup: String? { groups.first { $0.active }?.to }
}
