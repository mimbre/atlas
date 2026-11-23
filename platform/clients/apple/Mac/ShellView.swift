#if os(macOS)
import AtlasControlKit
import BlockViews
import ControlSession
import SwiftUI

/// The three columns: the tabs boot sent (sidebar), the active tab's index page (middle)
/// and the page opened from a row (right); the title bar with the title and the
/// environment; the status bar below.
struct ShellView: View {
    let session: Session

    private func submit(_ call: CallModel, _ values: [String: String]) {
        session.submit(call, values: values)
    }

    var body: some View {
        let shell = ShellViewModel(session.state)
        NavigationSplitView {
            Sidebar(shell: shell, select: session.selectTab, filter: session.filter)
        } content: {
            Column(page: shell.index, selectedPath: shell.selectedPath, open: session.open, submit: submit)
        } detail: {
            Column(page: shell.opened, selectedPath: shell.selectedPath, open: session.open, submit: submit)
        }
        .navigationTitle(shell.title ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EnvironmentBadge(env: shell.env, production: shell.isProduction)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(status: StatusViewModel(session.state), shell: shell)
        }
        .overlay {
            if case .ended(let ending) = session.state.connection {
                EndedView(ending: ending)
            }
        }
    }
}

/// The tabs, in boot's order, each with its icon and count, with the count (what waits for
/// the user) as the section's header; under every tab with groups, its groups with their
/// counts (as a mail app's folders), in a disclosure that is open until folded (the fold is
/// kept per tab), so any group can be chosen from anywhere. It scrolls, so it holds boot's
/// limit of 64.
struct Sidebar: View {
    let shell: ShellViewModel
    let select: (String) -> Void
    let filter: (String) -> Void

    /// A tab, by its id, or a group of a tab's page, by its `to`.
    enum Choice: Hashable {
        case tab(String)
        case group(String)
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

    var body: some View {
        List(selection: choice) {
            Section {
                ForEach(shell.tabs) { tab in
                    if tab.groups.isEmpty {
                        tabLabel(tab)
                    } else {
                        DisclosureGroup(isExpanded: expansion(tab.id)) {
                            ForEach(tab.groups) { group in
                                Text(group.label).badge(badge(group.count)).tag(Choice.group(group.to))
                            }
                        } label: {
                            tabLabel(tab)
                        }
                    }
                }
            } header: {
                if let count = shell.count { Text(count) }
            }
        }
        .listStyle(.sidebar)
        .opacity(shell.stale ? 0.6 : 1)
        .navigationSplitViewColumnWidth(min: 160, ideal: 220)
    }

    private func tabLabel(_ tab: ShellViewModel.Tab) -> some View {
        Label(tab.label, systemImage: Self.symbol(tab.icon)).badge(badge(tab.count)).tag(Choice.tab(tab.id))
    }

    /// A count as a badge, 0 too; none while no page has said it.
    private func badge(_ count: Int?) -> Text? {
        count.map { Text("\($0)") }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !folded.split(separator: "\n").contains(Substring(id)) },
            set: { open in
                var ids = folded.split(separator: "\n").map(String.init).filter { $0 != id }
                if !open { ids.append(id) }
                folded = ids.joined(separator: "\n")
            })
    }

    /// The symbol for a tab's icon, a semantic name Control gives; a plain one for a name
    /// this app does not know.
    static func symbol(_ icon: String?) -> String {
        switch icon {
        case "inbox": "tray"
        case "watching": "eye"
        case "mine": "person.crop.circle"
        case "stack": "rectangle.stack"
        case "checklist": "checklist"
        case "machines": "cpu"
        default: "circle"
        }
    }
}

/// A column's page, or nothing yet.
struct Column: View {
    let page: PageMessage?
    let selectedPath: String?
    let open: (String) -> Void
    let submit: (CallModel, [String: String]) -> Void

    var body: some View {
        if let page {
            PageView(page: page, selectedPath: selectedPath, open: open, submit: submit)
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

/// Why the session is over, over the window.
struct EndedView: View {
    let ending: SessionState.Ending

    var body: some View {
        VStack(spacing: 8) {
            switch ending {
            case .bye(let text):
                Text(text)
            case .incompatible(let welcome):
                Text("Control \(welcome.env) speaks contract \(welcome.spec); this app implements \(Contract.version) for this environment.")
            case .unreadableWelcome(let reason):
                Text("Control's welcome could not be read (\(reason)); this app implements contract \(Contract.version).")
            case .stopped:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 520)
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
