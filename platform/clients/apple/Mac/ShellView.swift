#if os(macOS)
import AppUpdate
import AtlasControlKit
import BlockViews
import ControlSession
import Prism
import SwiftUI

/// The three columns: the tabs boot sent (sidebar), the active tab's index page (middle)
/// and the page opened from a row (right); the title bar with the page's title only (the
/// viewer's name and the environment are in the sidebar's foot); the index page's own
/// actions (Create to-do: `PageActions.listToolbar`) in the list column's toolbar above the
/// list, as quiet icons (`ItemToolbar`); no status bar: the shell's state is in the
/// sidebar's foot. The opened page shows its own
/// actions next to its title, at its top; what else can be done with the opened item (its
/// `actions` blocks and its answers of weight `other`: Update, Ask a question, Hand over,
/// Leave it to the proposer, Hand to, Failures…, Delete) is in the toolbar at the right
/// (`ItemToolbar`, `PageActions.toolbar`), in its context menu and in the Actions menu, and
/// follows the item open; none when nothing is. An action's page (its confirm, form or more
/// actions) is a sheet over them; the keys of the shown page's actions take them. What is
/// done and not answered yet shows at once: on its button, on the sheet and in the status
/// bar. The agent's plan, from an `agent:<intent>` action, is a sheet over all of it.
struct ShellView: View {
    let session: Session
    let updater: Updater
    @State private var keys = ActionKeys()
    /// The split view's columns: all of them in a wide window; in a narrow one
    /// (`WindowLayout.showsSidebar`) the sidebar folds away, as Mail's does (macOS's split
    /// view folds no other column). Set only when the window crosses that width, so the
    /// sidebar toggle still shows and hides it in between.
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var sidebarShown: Bool?

    /// The shell's state for the sidebar's foot, its one place: the connection's mark, and in
    /// its popover the plain words, the last notice, the app's update and the details.
    private func connection(_ shell: ShellViewModel) -> SidebarConnection {
        let status = StatusViewModel(session.state)
        let boot = shell.bootFailure.map { failure in
            switch failure {
            case .control(let text): text
            case .invalid: "shell not accepted; showing the last good tabs"
            case .unreadable(let reason): "shell could not be read (\(reason)); showing the last good tabs"
            case .timedOut: "boot timed out"
            }
        }
        let notes = [status.notice?.text, updater.status.statusText(installed: updater.installed)?.text,
                     boot].compactMap { $0 }
        return SidebarConnection(mark: status.mark, details: SidebarLook.details(status, extra: notes))
    }

    /// A submit, with what it is in the words of the page that declares it.
    private func submit(_ call: CallModel, _ values: [String: String]) {
        let shell = ShellViewModel(session.state)
        session.submit(call, values: values,
                       label: PageActions.label(of: call, on: [shell.sheet, shell.opened, shell.index]))
    }

    var body: some View {
        let shell = ShellViewModel(session.state)
        columns(shell)
        .onGeometryChange(for: Bool.self) { WindowLayout.showsSidebar(window: $0.size.width) } action: { shows in
            guard shows != sidebarShown else { return }
            sidebarShown = shows
            visibility = shows ? .all : .doubleColumn
        }
        .onAppear { keys.start(session) }
        .onDisappear { keys.stop() }
        // The app's update (IS-Atlas-66): asked at start, and at once when Control's welcome
        // says a newer contract (D-0105); taken when no form or confirm is open, on the page shown.
        .task {
            updater.canTakeNow = { [session] in !session.state.isEditing && !session.state.submitting }
            updater.page = { [session] in session.state.pageOnScreen?.path ?? session.state.expected }
            updater.start()
        }
        .onChange(of: session.state.newerControl) { _, newer in
            if let newer { updater.controlIsNewer(spec: newer) }
        }
        .onChange(of: session.state.isEditing) { updater.pageChanged() }
        .sheet(isPresented: Binding(get: { shell.sheet != nil || shell.plan != nil },
                                    set: { if !$0 { shell.plan != nil ? session.closePlan() : session.leave() } })) {
            Group {
                if let plan = shell.plan {
                    PlanView(plan: plan, dropped: shell.droppedSteps, run: session.runPlan,
                             toggle: session.togglePlanStep, stop: session.stopPlan, close: session.closePlan)
                } else if let page = shell.sheet {
                    ActionPageView(page: page, draft: shell.draft, submitting: shell.submitting, answer: shell.answer,
                                   act: session.act, open: session.open, submit: submit, edit: session.edit, leave: session.leave)
                }
            }
            .environment(\.pendingAction, shell.pending)
        }
        // The title bar shows the page's title only: the viewer's name and the environment
        // live in the sidebar's foot.
        .navigationTitle(shell.title ?? "")
        .environment(\.pendingAction, shell.pending)
        .environment(\.panelKeys, keys.panels)
    }

    /// Sidebar, list and page; a tab's block page (`indexIsPage`) has no list: it is the
    /// page, shown as an opened one is (a page opened from it takes its place).
    @ViewBuilder
    private func columns(_ shell: ShellViewModel) -> some View {
        if shell.indexIsPage {
            NavigationSplitView(columnVisibility: $visibility) {
                Sidebar(shell: shell, connection: connection(shell), select: session.selectTab)
            } detail: {
                page(shell.opened ?? shell.index, shell)
            }
        } else {
            NavigationSplitView(columnVisibility: $visibility) {
                Sidebar(shell: shell, connection: connection(shell), select: session.selectTab)
            } content: {
                Column(page: shell.index, header: false, selectedPath: shell.selectedPath, open: session.open,
                       act: session.act, filter: session.filter,
                       selectedGroup: shell.activeGroup ?? shell.tabs.first(where: { $0.id == shell.activeTab })?.to)
                    .navigationSplitViewColumnWidth(WindowLayout.list)
                    // The list's own actions (Create to-do) above it, quiet icons.
                    .toolbar {
                        ItemToolbar(actions: PageActions.listToolbar(shell.index), pending: shell.pending, trailing: false, act: session.act)
                    }
            } detail: {
                page(shell.opened, shell)
            }
        }
    }

    /// A page in the page column, what else can be done with it in the toolbar.
    private func page(_ page: PageMessage?, _ shell: ShellViewModel) -> some View {
        Column(page: page, header: true, selectedPath: shell.selectedPath, open: session.open, act: session.act)
            .toolbar {
                ItemToolbar(actions: PageActions.toolbar(page), pending: shell.pending, trailing: true, act: session.act)
            }
    }
}

/// The top-level tabs, in boot's order, with the person's connection in the foot.
struct Sidebar: View {
    let shell: ShellViewModel
    let connection: SidebarConnection
    let select: (String) -> Void

    var body: some View {
        SidebarView(
            work: SidebarItem.rows(shell, section: "work"),
            browse: SidebarItem.rows(shell, section: "browse"),
            selection: shell.activeTab.map(SidebarItem.ID.tab),
            stale: shell.stale, name: shell.name, assistant: shell.assistant, env: shell.env,
            production: shell.isProduction,
            connection: connection,
            select: { choice in
                if case .tab(let id) = choice { select(id) }
            })
        // The sidebar's fixed width leaves room for labels and counts.
        .navigationSplitViewColumnWidth(WindowLayout.sidebar)
    }
}

/// A column's page, or nothing yet.
struct Column: View {
    let page: PageMessage?
    let header: Bool
    let selectedPath: String?
    let open: (String) -> Void
    let act: (ActionModel) -> Void
    var filter: ((String) -> Void)? = nil
    var selectedGroup: String? = nil

    var body: some View {
        if let page {
            PageView(page: page, header: header, selectedPath: selectedPath, open: open, act: act,
                     filter: filter, selectedGroup: selectedGroup)
        } else {
            Color.clear
        }
    }
}

/// Started without the launcher: how to start it.
struct NotLaunchedView: View {
    let problem: SessionSettings.Problem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start the app with the environment it is for:").prism(Prism.Typography.title7)
            Text("bin/atlas mac --env test").prism(Prism.Typography.monosmall).textSelection(.enabled)
            Text("or, against a Control already listening:").foregroundStyle(.secondary)
            Text("swift run AtlasMac --env test --host 127.0.0.1 --port <control port>")
                .prism(Prism.Typography.monosmall).textSelection(.enabled)
            switch problem {
            case .notLaunched: EmptyView()
            case .missing(let name): Text("Missing: \(name)").foregroundStyle(.red)
            case .invalid(let name): Text("Not valid: \(name)").foregroundStyle(.red)
            }
        }
        .prism(Prism.Typography.bodysmall)
        .padding(32)
    }
}
#endif
