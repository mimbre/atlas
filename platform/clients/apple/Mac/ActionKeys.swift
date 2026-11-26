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
/// ↑, ↓ and Return go to the panel on screen (`PanelKeys`) whichever column has the
/// focus, so they work as soon as its page opens; not while text is typed or a sheet is up.
@MainActor
final class ActionKeys {
    private var monitor: Any?
    let typing = TypingFocus()
    let panels = PanelKeys()

    func start(_ session: Session) {
        guard monitor == nil else { return }
        let typing = typing
        let panels = panels
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let taken = MainActor.assumeIsolated { () -> Bool in
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
    }

    /// The panel's key an event is: ↑, ↓ or Return (either), without ⌘ ⌃ ⌥ or ⇧, in the
    /// window itself (no sheet over it or of it), with no text being typed.
    static func panelKey(for event: NSEvent) -> PanelKey? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
              let window = event.window, !(window.firstResponder is NSText),
              window.sheetParent == nil, window.attachedSheet == nil else { return nil }
        return PanelKey(keyCode: event.keyCode)
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
