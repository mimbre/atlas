#if os(macOS)
import AppKit
import AtlasControlKit
import BlockViews
import ControlSession

/// The keys of the shown page's actions, as Control declares them (an action's `key`;
/// a decision's option answers on theirs, the recommended one on `0` too, `Option.actions`):
/// the opened page's, else the index page's; in the sheet, its more actions'. A key is
/// one character without ⌘, ⌃ or ⌥, and is the action's whichever column has the focus
/// (a list there would take letters for itself), except while text is being typed, in a
/// sheet that asks (its form or confirm has its own keys) and over the agent's plan (it
/// has its own).
/// ↑, ↓ and Return go to the focused column (`PanelKeys`), as in the TUI: the middle list
/// moves with them until → gives the focus to the page's panel; ← gives it back. Not while
/// text is typed or a sheet is up. The window's own focus follows: the list is first
/// responder only while it has the focus, so its selection looks focused only then.
@MainActor
final class ActionKeys {
    private var monitor: Any?
    let panels = PanelKeys()
    /// The list that last had the window's focus, to give it back on ←.
    private weak var list: NSTableView?

    private let menu = ActionsMenu()

    func start(_ session: Session) {
        guard monitor == nil else { return }
        menu.start(session)
        let panels = panels
        panels.moved = { [weak self] column in self?.move(column) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated { () -> Bool in
                // A list with the window's focus is the one the arrows move: with the panel
                // focused, the window's focus is on no list, so one has it only by a click.
                if let table = event.window?.firstResponder as? NSTableView {
                    self?.list = table
                    panels.focusList()
                }
                if let column = Self.columnKey(for: event) {
                    return panels.press(column: column, isRepeat: event.isARepeat)
                }
                if let key = Self.panelKey(for: event) {
                    return panels.press(key, isRepeat: event.isARepeat)
                }
                let shell = ShellViewModel(session.state)
                if let action = Self.action(for: event, shell: shell) {
                    session.act(action)
                    return true
                }
                guard let url = Self.link(for: event, shell: shell) else { return false }
                NSWorkspace.shared.open(url)
                return true
            }
            return taken ? nil : event
        }
    }

    func stop() {
        menu.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panels.moved = nil
    }

    /// The window's focus follows the column's: away from the list to the panel (which has
    /// no responder of its own), back to the list.
    private func move(_ column: KeyColumn) {
        guard let window = NSApp.keyWindow else { return }
        switch column {
        case .panel:
            if window.firstResponder is NSTableView { window.makeFirstResponder(nil) }
        case .list:
            if let list, list.window === window { window.makeFirstResponder(list) }
        }
    }

    /// A key in the window itself (no sheet over it or of it), without ⌘ ⌃ ⌥ or ⇧, with no
    /// text being typed: its key code.
    private static func windowKey(for event: NSEvent) -> UInt16? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
              let window = event.window, !(window.firstResponder is NSText),
              window.sheetParent == nil, window.attachedSheet == nil else { return nil }
        return event.keyCode
    }

    /// The panel's key an event is: ↑, ↓ or Return (either).
    static func panelKey(for event: NSEvent) -> PanelKey? {
        windowKey(for: event).flatMap(PanelKey.init(keyCode:))
    }

    /// The column ← (the list) or → (the panel) gives the focus to.
    static func columnKey(for event: NSEvent) -> KeyColumn? {
        windowKey(for: event).flatMap(KeyColumn.init(keyCode:))
    }

    static func action(for event: NSEvent, shell: ShellViewModel) -> ActionModel? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let key = event.characters, key.count == 1,
              let window = event.window, !(window.firstResponder is NSText) else { return nil }
        if window.sheetParent != nil {
            guard shell.plan == nil, let sheet = shell.sheet, !SessionState.asks(sheet) else { return nil }
            return PageActions.action(key: key, on: [sheet])
        }
        guard window.attachedSheet == nil else { return nil }
        return PageActions.action(key: key, on: [shell.opened, shell.index])
    }

    /// A panel's link with the key on the shown pages, in the window (not over a sheet):
    /// opened in the browser.
    static func link(for event: NSEvent, shell: ShellViewModel) -> URL? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let key = event.characters, key.count == 1,
              let window = event.window, !(window.firstResponder is NSText),
              window.sheetParent == nil, window.attachedSheet == nil else { return nil }
        return PageActions.link(key: key, on: [shell.opened, shell.index])
    }
}

/// The menu bar's Actions menu: where the keys of the shown page's actions are found, as
/// the page shows none (D-0104: Control decides the actions; this app shows their keys
/// only here and in tooltips). Each item is an action with its key, the same `ActionKeys`
/// takes (the sheet's, else the opened page's, then the index page's; one item per key);
/// choosing one takes it. The menu never takes a key itself: `ActionKeys` does, so a key
/// typed in text stays text. SwiftUI owns the main menu and may rebuild it, so the menu is
/// put back whenever it is gone.
@MainActor
final class ActionsMenu: NSObject, NSMenuDelegate {
    private let item = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
    private var session: Session?
    private var observer: NSObjectProtocol?

    func start(_ session: Session) {
        self.session = session
        let menu = NSMenu(title: "Actions")
        menu.delegate = self
        item.submenu = menu
        install()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.install() } }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        item.menu?.removeItem(item)
        session = nil
    }

    /// Before the Window menu, else last.
    private func install() {
        guard let main = NSApp.mainMenu, item.menu !== main else { return }
        let window = main.items.firstIndex { $0.submenu === NSApp.windowsMenu }
        main.insertItem(item, at: window ?? main.items.count)
    }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for action in actions() {
            let entry = NSMenuItem(title: action.label ?? "", action: #selector(take(_:)),
                                   keyEquivalent: action.key.map { $0.count == 1 ? $0 : "" } ?? "")
            entry.keyEquivalentModifierMask = []
            entry.target = self
            entry.representedObject = Box(action)
            menu.addItem(entry)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No actions here", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func take(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? Box)?.action else { return }
        session?.act(action)
    }

    /// The shown pages' doable actions with a key, the first per key.
    private func actions() -> [ActionModel] {
        guard let session else { return [] }
        let shell = ShellViewModel(session.state)
        let pages: [PageMessage?] = shell.sheet.map { [$0] } ?? [shell.opened, shell.index]
        var keys = Set<String>()
        return pages.compactMap { $0 }.flatMap(PageActions.all).filter { action in
            guard let key = action.key, PageActions.doable(action), !keys.contains(key) else { return false }
            keys.insert(key)
            return true
        }
    }

    private final class Box: NSObject {
        let action: ActionModel
        init(_ action: ActionModel) { self.action = action }
    }
}
#endif
