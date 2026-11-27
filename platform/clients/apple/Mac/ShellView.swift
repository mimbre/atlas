#if os(macOS)
import AppUpdate
import AtlasControlKit
import BlockViews
import ControlSession
import Prism
import SwiftUI

/// The three columns: the tabs boot sent (sidebar), the active tab's index page (middle)
/// and the page opened from a row (right); the title bar with the page's title only (the
/// viewer's name and the environment are in the sidebar's foot) and the index page's own
/// actions (`PageActions.ofPage`); no status bar: the shell's state is in the sidebar's foot. The opened page shows its own
/// actions next to its title, at its top; what else can be done with the opened item (its
/// `actions` blocks: Update, Hand to, Failures…, Delete) is in the toolbar at the right
/// (`ItemToolbar`), in its context menu and in the Actions menu, and follows the item open;
/// none when nothing is. An action's page (its confirm, form or more
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
                                   act: session.act, submit: submit, edit: session.edit, leave: session.leave)
                }
            }
            .environment(\.pendingAction, shell.pending)
        }
        // The title bar shows the page's title only: the viewer's name and the environment
        // live in the sidebar's foot.
        .navigationTitle(shell.title ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // A tab's block page shows its own actions with its header.
                if let index = shell.index, !shell.indexIsPage {
                    ActionButtons(actions: PageActions.ofPage(index), act: session.act)
                }
            }
        }
        .environment(\.pendingAction, shell.pending)
        .environment(\.panelKeys, keys.panels)
    }

    /// Sidebar, list and page; a tab's block page (`indexIsPage`) has no list: it is the
    /// page, shown as an opened one is (a page opened from it takes its place).
    @ViewBuilder
    private func columns(_ shell: ShellViewModel) -> some View {
        if shell.indexIsPage {
            NavigationSplitView(columnVisibility: $visibility) {
                Sidebar(shell: shell, connection: connection(shell), select: session.selectTab, filter: session.filter)
            } detail: {
                page(shell.opened ?? shell.index, shell)
            }
        } else {
            NavigationSplitView(columnVisibility: $visibility) {
                Sidebar(shell: shell, connection: connection(shell), select: session.selectTab, filter: session.filter)
            } content: {
                Column(page: shell.index, header: false, selectedPath: shell.selectedPath, open: session.open,
                       act: session.act)
                    .navigationSplitViewColumnWidth(WindowLayout.list)
            } detail: {
                page(shell.opened, shell)
            }
        }
    }

    /// A page in the page column, what else can be done with it in the toolbar.
    private func page(_ page: PageMessage?, _ shell: ShellViewModel) -> some View {
        Column(page: page, header: true, selectedPath: shell.selectedPath, open: session.open, act: session.act)
            .toolbar {
                ItemToolbar(actions: PageActions.others(page), pending: shell.pending, act: session.act)
            }
    }
}

/// The tabs, in boot's order, each with its icon and count, under its section's heading;
/// under every tab with groups, its groups with their counts, folded by the tab's chevron
/// (the fold is kept per tab), so any group can be chosen from anywhere; at the bottom,
/// the person, the environment and the connection (`SidebarView`). It scrolls, so it
/// holds boot's limit of 64.
struct Sidebar: View {
    let shell: ShellViewModel
    let connection: SidebarConnection
    let select: (String) -> Void
    let filter: (String) -> Void

    /// The tabs whose groups are folded, by id, one per line; kept across launches.
    @AppStorage("sidebar.foldedTabs") private var folded = ""

    var body: some View {
        let foldedIds = Set(folded.split(separator: "\n").map(String.init))
        SidebarView(
            work: SidebarItem.rows(shell, section: "work", folded: foldedIds),
            browse: SidebarItem.rows(shell, section: "browse", folded: foldedIds),
            selection: shell.activeGroup.map(SidebarItem.ID.group) ?? shell.activeTab.map(SidebarItem.ID.tab),
            stale: shell.stale, name: shell.name, assistant: shell.assistant, env: shell.env,
            production: shell.isProduction,
            connection: connection,
            select: { choice in
                switch choice {
                case .tab(let id): select(id)
                case .group(let to): filter(to)
                }
            },
            fold: fold)
        // The sidebar's fixed width (`WindowLayout.sidebar`): room for the longest work tab's
        // label beside its icon, chevron and count without cutting it.
        .navigationSplitViewColumnWidth(WindowLayout.sidebar)
    }

    private func fold(_ id: String, open: Bool) {
        var ids = folded.split(separator: "\n").map(String.init).filter { $0 != id }
        if !open { ids.append(id) }
        folded = ids.joined(separator: "\n")
    }
}

/// A column's page, or nothing yet.
struct Column: View {
    let page: PageMessage?
    let header: Bool
    let selectedPath: String?
    let open: (String) -> Void
    let act: (ActionModel) -> Void

    var body: some View {
        if let page {
            PageView(page: page, header: header, selectedPath: selectedPath, open: open, act: act)
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
