#if os(macOS)
import AppKit
import AtlasControlKit
import BlockViews
import ControlSession

/// The keys of the shown page's actions, as Control declares them (an action's `key`):
/// the opened page's, else the index page's; in the sheet, its more actions'. A key is
/// one character without ⌘, ⌃ or ⌥, and is the action's whichever column has the focus
/// (a list there would take letters for itself), except while text is being typed, while
/// a focused `single_choice` takes it (its digits, `TypingFocus`), in a sheet that asks
/// (its form or confirm has its own keys) and over the agent's plan (it has its own).
/// ↑, ↓ and Return go to the focused column (`PanelKeys`), as in the TUI: the middle list
/// moves with them until → gives the focus to the page's panel; ← gives it back. Not while
/// text is typed or a sheet is up. The window's own focus follows: the list is first
/// responder only while it has the focus, so its selection looks focused only then.
@MainActor
final class ActionKeys {
    private var monitor: Any?
    let typing = TypingFocus()
    let panels = PanelKeys()
    /// The list that last had the window's focus, to give it back on ←.
    private weak var list: NSTableView?

    func start(_ session: Session) {
        guard monitor == nil else { return }
        let typing = typing
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
                if let action = Self.action(for: event, shell: shell, typing: typing) {
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
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panels.moved = nil
    }

    /// The window's focus follows the column's: away from the list to the panel (which has
    /// no responder of its own, but a choice takes it), back to the list.
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

    static func action(for event: NSEvent, shell: ShellViewModel, typing: TypingFocus) -> ActionModel? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let key = event.characters, key.count == 1,
              let window = event.window, !(window.firstResponder is NSText) else { return nil }
        if window.sheetParent != nil {
            guard shell.plan == nil, let sheet = shell.sheet, !SessionState.asks(sheet) else { return nil }
            return PageActions.action(key: key, on: [sheet], typing: typing)
        }
        guard window.attachedSheet == nil else { return nil }
        return PageActions.action(key: key, on: [shell.opened, shell.index], typing: typing)
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
#endif
