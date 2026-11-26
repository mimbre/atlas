#if os(macOS)
import AppUpdate
import AtlasControlKit
import BlockViews
import ControlSession
import SwiftUI

/// The three columns: the tabs boot sent (sidebar), the active tab's index page (middle)
/// and the page opened from a row (right); the title bar with the title, the shell's
/// greeting (when it has one) as its subtitle, the environment and the index page's own
/// actions (`PageActions.ofPage`); the status bar below. The opened page shows its own
/// actions next to its title, at its top. An action's page (its confirm, form or more
/// actions) is a sheet over them; the keys of the shown page's actions take them. What is
/// done and not answered yet shows at once: on its button, on the sheet and in the status
/// bar. The agent's plan, from an `agent:<intent>` action, is a sheet over all of it.
struct ShellView: View {
    let session: Session
    let updater: Updater
    @State private var keys = ActionKeys()

    /// A submit, with what it is in the words of the page that declares it.
    private func submit(_ call: CallModel, _ values: [String: String]) {
        let shell = ShellViewModel(session.state)
        session.submit(call, values: values,
                       label: PageActions.label(of: call, on: [shell.sheet, shell.opened, shell.index]))
    }

    var body: some View {
        let shell = ShellViewModel(session.state)
        NavigationSplitView {
            Sidebar(shell: shell, select: session.selectTab, filter: session.filter)
        } content: {
            // Room for a row's key, title (two lines) and to-do side by side.
            Column(page: shell.index, header: false, selectedPath: shell.selectedPath, open: session.open,
                   act: session.act)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
            Column(page: shell.opened, header: true, selectedPath: shell.selectedPath, open: session.open,
                   act: session.act)
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
        .navigationTitle(shell.title ?? "")
        .greeting(shell.greeting)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EnvironmentBadge(env: shell.env, production: shell.isProduction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let index = shell.index {
                    ActionButtons(actions: PageActions.ofPage(index), act: session.act)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(status: StatusViewModel(session.state), shell: shell,
                      update: updater.status.statusText(installed: updater.installed))
        }
        .environment(\.pendingAction, shell.pending)
        .environment(\.panelKeys, keys.panels)
    }
}

extension View {
    /// The shell's greeting as the window's subtitle, only when the shell has one: a shell
    /// without a greeting keeps the title bar as it was.
    @ViewBuilder
    fileprivate func greeting(_ text: String?) -> some View {
        if let text {
            navigationSubtitle(text)
        } else {
            self
        }
    }
}

/// The tabs, in boot's order, each with its icon and count, under its section's heading;
/// under every tab with groups, its groups with their counts (as a mail app's folders),
/// folded by the tab's chevron (the fold is kept per tab), so any group can be chosen
/// from anywhere. It scrolls, so it holds boot's limit of 64.
///
/// The rows are one flat list, each the same kind of view: a `DisclosureGroup` per tab
/// (an outline) drew rows of the old outline over the new one when boot changed the
/// tabs or their groups (IS-Atlas-75: a group drawn on top of Workers).
struct Sidebar: View {
    let shell: ShellViewModel
    let select: (String) -> Void
    let filter: (String) -> Void

    /// A tab, by its id, or a group of a tab's page, by its `to`.
    enum Choice: Hashable {
        case tab(String)
        case group(String)
    }

    /// One row: a tab (with its icon, and its fold when it has groups) or a group under it.
    struct Row: Identifiable {
        let id: Choice
        let label: String
        let count: Int?
        let icon: String?
        /// Whether its groups are shown (a tab with groups); nil for any other row.
        let open: Bool?
    }

    /// The tabs whose groups are folded, by id, one per line; kept across launches.
    @AppStorage("sidebar.foldedTabs") private var folded = ""

    private var choice: Binding<Choice?> {
        Binding(
            get: { shell.activeGroup.map(Choice.group) ?? shell.activeTab.map(Choice.tab) },
            set: { choice in
                switch choice {
                case .tab(let id): select(id)
                case .group(let to): filter(to)
                case nil: break
                }
            })
    }

    private func rows(_ section: String) -> [Row] {
        let foldedIds = Set(folded.split(separator: "\n").map(String.init))
        return shell.tabs.filter { $0.section == section }.flatMap { tab -> [Row] in
            let open = !foldedIds.contains(tab.id)
            let row = Row(id: .tab(tab.id), label: tab.label, count: tab.count, icon: Self.symbol(tab.icon),
                          open: tab.groups.isEmpty ? nil : open)
            guard open else { return [row] }
            return [row] + tab.groups.map {
                Row(id: .group($0.to), label: $0.label, count: $0.count, icon: nil, open: nil)
            }
        }
    }

    /// Stale tabs are dimmed row by row: dimming the sidebar `List` itself drops the tab
    /// icons (all but the selected row's).
    var body: some View {
        List(selection: choice) {
            Section("Work") {
                rowViews(rows("work"))
            }
            Section("Browse") {
                rowViews(rows("browse"))
            }
        }
        .listStyle(.sidebar)
        // Room for the longest work tab's label beside its icon, chevron and count
        // ("Supervised by you   12") without cutting it.
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
    }

    private func rowViews(_ rows: [Row]) -> some View {
        ForEach(rows) { row in
            rowView(row)
                .opacity(shell.stale ? 0.6 : 1)
                .badge(row.count.map { Text("\($0)") })
                .tag(row.id)
        }
    }

    /// A tab: its fold's chevron (a blank of the same width without groups), icon and
    /// label; a group: its label, under its tab's.
    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 4) {
            if case .tab(let id) = row.id {
                Button { fold(id, open: row.open == false) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(row.open == true ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .opacity(row.open == nil ? 0 : 1)
                .disabled(row.open == nil)
                Label(row.label, systemImage: row.icon ?? "circle")
            } else {
                Text(row.label).padding(.leading, 44)
            }
        }
    }

    private func fold(_ id: String, open: Bool) {
        var ids = folded.split(separator: "\n").map(String.init).filter { $0 != id }
        if !open { ids.append(id) }
        folded = ids.joined(separator: "\n")
    }

    /// The symbol for a tab's icon, a semantic name Control gives; a plain one for a name
    /// this app does not know.
    static func symbol(_ icon: String?) -> String {
        switch icon {
        case "inbox": "tray"
        case "watching": "eye"
        case "machines": "cpu"
        case "agents": "person.2"
        case "checklist": "checklist"
        case "history": "clock.arrow.circlepath"
        case "mine": "person.crop.circle"
        case "stack": "rectangle.stack"
        default: "circle"
        }
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

/// The environment in the title bar; production as the inverted badge, as in the TUI.
struct EnvironmentBadge: View {
    let env: String
    let production: Bool

    var body: some View {
        Text(env)
            .font(.callout.weight(production ? .bold : .regular))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(production ? Color(nsColor: .windowBackgroundColor) : .secondary)
            .background(production ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }
}


/// Started without the launcher: how to start it.
struct NotLaunchedView: View {
    let problem: SessionSettings.Problem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start the app with the environment it is for:").font(.headline)
            Text("bin/atlas mac --env test").monospaced().textSelection(.enabled)
            Text("or, against a Control already listening:").foregroundStyle(.secondary)
            Text("swift run AtlasMac --env test --host 127.0.0.1 --port <control port>").monospaced().textSelection(.enabled)
            switch problem {
            case .notLaunched: EmptyView()
            case .missing(let name): Text("Missing: \(name)").foregroundStyle(.red)
            case .invalid(let name): Text("Not valid: \(name)").foregroundStyle(.red)
            }
        }
        .padding(32)
    }
}
#endif
