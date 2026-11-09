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

    var body: some View {
        let shell = ShellViewModel(session.state)
        NavigationSplitView {
            Sidebar(shell: shell, select: session.selectTab)
        } content: {
            Column(page: shell.index, selectedPath: shell.selectedPath, open: session.open)
        } detail: {
            Column(page: shell.opened, selectedPath: shell.selectedPath, open: session.open)
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

/// The tabs, in boot's order, with the count (what waits for the user) as the section's
/// header. It scrolls, so it holds boot's limit of 64.
struct Sidebar: View {
    let shell: ShellViewModel
    let select: (String) -> Void

    var body: some View {
        List(selection: Binding(get: { shell.activeTab }, set: { if let id = $0 { select(id) } })) {
            Section {
                ForEach(shell.tabs) { tab in
                    Text(tab.label).tag(tab.id as String?)
                }
            } header: {
                if let count = shell.count { Text(count) }
            }
        }
        .listStyle(.sidebar)
        .opacity(shell.stale ? 0.6 : 1)
        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
    }
}

/// A column's page, or nothing yet.
struct Column: View {
    let page: PageMessage?
    let selectedPath: String?
    let open: (String) -> Void

    var body: some View {
        if let page {
            PageView(page: page, selectedPath: selectedPath, open: open)
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
