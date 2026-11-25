#if os(macOS)
import AppKit
import AppUpdate
import ControlSession
import SwiftUI

/// The macOS app (docs/design/apple-clients.md §2, "The shell"): one window with three
/// columns, the title bar and the status bar. It connects only where its launch arguments
/// say (`--env`, `--host`, `--port`, from the launcher, §5) or, a release opened from the
/// Finder, where its bundle says (`AtlasControl`); without either it says how to start it
/// and asks for nothing. A release updates itself from the feed its bundle names.
@main
struct AtlasMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var launch = Launch(arguments: CommandLine.arguments)

    var body: some Scene {
        Window("Atlas", id: "shell") {
            Group {
                switch launch {
                case .ready(let session, let updater):
                    ShellView(session: session, updater: updater)
                        .task { session.start() }
                case .notLaunched(let problem):
                    NotLaunchedView(problem: problem)
                }
            }
            .frame(minWidth: 900, minHeight: 500)
        }
        .commands {
            if case .ready(let session, _) = launch {
                TabCommands(session: session)
            }
        }
    }
}

/// What the app was started with: a session and the app's update, or why there is none.
enum Launch {
    case ready(Session, Updater)
    case notLaunched(SessionSettings.Problem)

    @MainActor
    init(arguments: [String]) {
        let info = Bundle.main.infoDictionary
        do {
            let settings = try SessionSettings.launch(Array(arguments.dropFirst()), bundle: info)
            let session = Session(settings: settings, connector: NetworkLineConnector(), clock: DispatchSessionClock())
            let installer = BundleInstaller(app: Bundle.main.bundleURL) { page in
                var next = settings
                next.startPage = page
                return next.arguments
            }
            let updater = Updater(installed: InstalledApp(info: info), feed: URLSessionReleaseFeed(),
                                  installer: installer) { seconds, action in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    action()
                }
            }
            self = .ready(session, updater)
        } catch {
            self = .notLaunched(error)
        }
    }
}

/// A command-line build (`swift run`) is a plain process: make it a regular app with a
/// window in front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `⌘1`–`⌘9`: the first nine tabs, in the View menu, by the labels boot sent.
struct TabCommands: Commands {
    let session: Session

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            let shell = ShellViewModel(session.state)
            ForEach(shell.tabs.filter { $0.shortcut != nil }) { tab in
                Button(tab.label) { session.selectTab(tab.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(tab.shortcut ?? 0))), modifiers: .command)
            }
            Divider()
        }
    }
}
#else
/// The macOS app has no iOS build; the iOS app is its own target (§2).
@main
enum AtlasMacApp {
    static func main() {}
}
#endif
