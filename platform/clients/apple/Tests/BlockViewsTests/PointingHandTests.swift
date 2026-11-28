#if os(macOS)
import AppKit
@testable import BlockViews
import SwiftUI
import XCTest

final class PointingHandTests: XCTestCase {
    /// Opt in on a Mac with a graphical session; moves and then restores the pointer.
    @MainActor func testNativeHover() throws {
        guard ProcessInfo.processInfo.environment["ATLAS_CURSOR_UI_TEST"] == "1" else {
            throw XCTSkip("Set ATLAS_CURSOR_UI_TEST=1 in a graphical session")
        }
        let app = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousMouse = CGEvent(source: nil)?.location
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                                               width: 240, height: 280),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        let tab = SidebarItem(id: .tab("test"), label: "Navigation", icon: nil, count: nil, forYou: false)
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            SidebarRow(item: tab, selected: false, stale: false, select: {}).frame(height: 40)
            PrismActionButton(label: "Action", help: "", pending: false, variant: .primary, take: {})
                .frame(height: 40)
            PrismActionButton(label: "Disabled", help: "", pending: true, variant: .primary, take: {})
                .frame(height: 40)
            Text("Plain background").frame(height: 40)
            KeyButton(label: "Panel link", help: "", take: {}).frame(height: 40)
            MarkdownText(source: "[Link](https://example.com)").textSelection(.enabled).frame(height: 40)
            Color.clear.frame(height: 40)
        }.frame(width: 240, height: 280))
        panel.contentView = host
        panel.acceptsMouseMovedEvents = true
        panel.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer {
            panel.orderOut(nil)
            if let previousMouse { CGWarpMouseCursorPosition(previousMouse) }
            previousApp?.activate()
        }
        func move(_ x: CGFloat, _ y: CGFloat, hand: Bool) {
            let point = panel.convertPoint(toScreen: NSPoint(x: x, y: y))
            let position = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
            CGWarpMouseCursorPosition(position)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            let minimum = Date().addingTimeInterval(0.15)
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline && (Date() < minimum || (NSCursor.current == NSCursor.pointingHand) != hand) {
                if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.03), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        move(120, 20, hand: false)
        move(30, 260, hand: true)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "sidebar navigation")
        move(120, 220, hand: true)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "action")
        move(120, 180, hand: false)
        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand, "disabled action")
        move(120, 140, hand: false)
        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand, "plain content")
        move(120, 100, hand: true)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "panel link")
        move(30, 260, hand: true)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "re-entry")
        move(120, 20, hand: false)
        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand, "leave")
    }
}
#endif
