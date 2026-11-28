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

    /// Exercise wrapped link hit regions before and after a native scroll.
    @MainActor func testWrappedLinkAfterScrolling() throws {
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
        var lines: [CGRect] = []
        var opened: URL?
        let host = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 0) {
                MarkdownText(source: "[A long wrapped link with several words on multiple lines](https://example.com)",
                             openLink: { url in opened = url; return .handled })
                Text("plain selectable")
            }
                .textSelection(.enabled)
                .frame(width: 120, alignment: .leading)
                .padding(.top, 40)
                .padding(.leading, 25)
                .frame(width: 240, height: 500, alignment: .topLeading)
                .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { geometry in
                        let bounds = layouts.flatMap { anchored in
                            let origin = geometry[anchored.origin]
                            return anchored.layout.map { $0.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y) }
                        }
                        Color.clear.allowsHitTesting(false)
                            .onChange(of: bounds, initial: true) { _, value in lines = value }
                    }
                }
        )
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 500)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 280))
        scroll.hasVerticalScroller = true
        scroll.documentView = host
        panel.contentView = scroll
        panel.acceptsMouseMovedEvents = true
        panel.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer {
            panel.orderOut(nil)
            if let previousMouse { CGWarpMouseCursorPosition(previousMouse) }
            previousApp?.activate()
        }
        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.03), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
        func screenPoint(_ rect: CGRect) -> CGPoint {
            let point = NSPoint(x: rect.midX, y: host.isFlipped ? rect.midY : host.bounds.height - rect.midY)
            let inWindow = host.convert(point, to: nil)
            let onScreen = panel.convertPoint(toScreen: inWindow)
            return CGPoint(x: onScreen.x, y: NSScreen.screens[0].frame.maxY - onScreen.y)
        }
        func hover(_ rect: CGRect) {
            let point = screenPoint(rect)
            CGWarpMouseCursorPosition(point)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            pump(0.3)
        }
        pump(0.8)
        let first = try XCTUnwrap(lines.first)
        let second = try XCTUnwrap(lines.dropFirst().first)
        hover(first)
        XCTAssertEqual(NSCursor.current, .pointingHand, "first wrapped line")
        hover(CGRect(x: second.midX, y: first.maxY + 1, width: 0, height: 0))
        XCTAssertNotEqual(NSCursor.current, .pointingHand, "gap between wrapped lines")
        hover(second)
        XCTAssertEqual(NSCursor.current, .pointingHand, "second wrapped line")
        let before = screenPoint(second)
        let oldOffset = scroll.contentView.bounds.origin
        let delta: CGFloat = host.isFlipped ? 12 : -12
        scroll.contentView.scroll(to: NSPoint(x: oldOffset.x, y: oldOffset.y + delta))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(0.3)
        let after = screenPoint(second)
        XCTAssertGreaterThan(abs(after.y - before.y), 1, "the document actually scrolled")
        XCTAssertNotEqual(NSCursor.current, .pointingHand, "stationary pointer after scrolling into a line gap")
        hover(second)
        XCTAssertEqual(NSCursor.current, .pointingHand, "wrapped line after scrolling")
        let point = screenPoint(second)
        for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        pump(0.3)
        XCTAssertEqual(opened, URL(string: "https://example.com"), "link remains clickable after scrolling")
        let plain = try XCTUnwrap(lines.last)
        let plainPoint = screenPoint(CGRect(x: plain.minX + 15, y: plain.midY, width: 0, height: 0))
        CGWarpMouseCursorPosition(plainPoint)
        for count in [1, 2] {
            for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: plainPoint, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
            pump(0.1)
        }
        XCTAssertEqual((panel.firstResponder as? any NSAccessibilityProtocol)?.accessibilitySelectedText(), "plain",
                       "text remains selectable after scrolling")
    }
}
#endif
