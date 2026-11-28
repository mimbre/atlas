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
        XCTAssertTrue(CGPreflightPostEventAccess(), "Native hover proof requires macOS input-posting permission")
        let app = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousMouse = CGEvent(source: nil)?.location
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                                               width: 240, height: 280),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        var opened: URL?
        let tab = SidebarItem(id: .tab("test"), label: "Navigation", icon: nil, count: nil, forYou: false)
        func content(disabled: Bool) -> some View {
            VStack(spacing: 0) {
                SidebarRow(item: tab, selected: false, stale: false, select: {}).frame(height: 40)
                PrismActionButton(label: "Action", help: "", pending: false, variant: .primary, take: {})
                    .frame(height: 40)
                PrismActionButton(label: "Disabled", help: "", pending: true, variant: .primary, take: {})
                    .frame(height: 40)
                Text("Plain background").frame(height: 40)
                KeyButton(label: "Panel link", help: "", take: {}).frame(height: 40)
                MarkdownText(source: "[Link](https://example.com) plain", openLink: { url in
                    opened = url
                    return .handled
                }).textSelection(.enabled).disabled(disabled).frame(height: 40)
                Color.clear.frame(height: 40)
            }.frame(width: 240, height: 280)
        }
        let host = NSHostingView(rootView: content(disabled: false))
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
        func click(_ x: CGFloat, _ y: CGFloat, count: Int64 = 1) {
            let point = panel.convertPoint(toScreen: NSPoint(x: x, y: y))
            let position = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
            for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: position, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: count)
                event?.post(tap: .cghidEventTap)
            }
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline {
                if let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
        let activationDeadline = Date().addingTimeInterval(3)
        while Date() < activationDeadline && (!app.isActive || !panel.isKeyWindow) {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
        XCTAssertTrue(app.isActive, "test app must be active")
        XCTAssertTrue(panel.isKeyWindow, "test window must be key")
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
        move(15, 60, hand: true)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "inline Markdown link")
        host.rootView = content(disabled: true)
        move(15, 60, hand: false)
        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand, "disabled inline link")
        host.rootView = content(disabled: false)
        move(15, 60, hand: true)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "re-enabled inline link")
        click(15, 60)
        XCTAssertEqual(opened, URL(string: "https://example.com"))
        move(60, 60, hand: false)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "selectable Markdown text")
        click(60, 60)
        click(60, 60, count: 2)
        XCTAssertEqual((panel.firstResponder as? any NSAccessibilityProtocol)?.accessibilitySelectedText(), "plain")
        move(30, 260, hand: true)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "re-entry")
        move(120, 20, hand: false)
        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand, "leave")
    }
}
#endif
