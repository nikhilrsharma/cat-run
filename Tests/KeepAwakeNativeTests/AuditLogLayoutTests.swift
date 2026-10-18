import AppKit
import KeepAwakeCore
import XCTest
@testable import KeepAwake

final class AuditLogLayoutTests: XCTestCase {
    func testLogsNavigationKeepsWindowSizeAndReturnsToSettings() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let originalSize = controller.window!.frame.size
            var requested = 0
            controller.onViewLogs = { requested += 1 }
            let navigation = try button("navigation", root)
            navigation.performClick(nil)
            XCTAssertFalse(try view("settings-page", root).isHidden)
            try button("view-logs", root).performClick(nil)
            XCTAssertEqual(requested, 1)
            XCTAssertFalse(try view("logs-page", root).isHidden)
            XCTAssertTrue(try view("settings-page", root).isHidden)
            XCTAssertEqual(navigation.title, "Back")
            XCTAssertEqual(controller.window!.frame.size, originalSize)
            navigation.performClick(nil)
            XCTAssertFalse(try view("settings-page", root).isHidden)
            XCTAssertTrue(try view("logs-page", root).isHidden)
            XCTAssertEqual(navigation.title, "Back")
            navigation.performClick(nil)
            XCTAssertFalse(try view("main-page", root).isHidden)
            XCTAssertEqual(navigation.title, "Settings")
            XCTAssertEqual(controller.window!.frame.size, originalSize)
        }
    }

    func testLogRowsWrapAndDateHeadersFitAtBothWindowLimits() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let page = try XCTUnwrap(try view("logs-page", root) as? AuditLogView)
            let table = try XCTUnwrap(try view("logs-table", root) as? NSTableView)
            let scroll = try XCTUnwrap(try view("logs-scroll", root) as? NSScrollView)
            let date = Date(timeIntervalSince1970: 1_792_272_600)
            let events = [
                AuditEvent(date: date, message: "Timer stopped · Time elapsed."),
                AuditEvent(date: date.addingTimeInterval(-60), message: "Unexpected interruption detected. The exact cause and stop time are unknown; the previous timer was not resumed."),
                AuditEvent(date: date.addingTimeInterval(-86_400), message: "Launch at login enabled."),
                AuditEvent(date: date.addingTimeInterval(-6 * 86_400), message: "Timer started · 06h 00m · Keep screen awake on.")
            ]
            controller.showLogs()
            for zone in ["America/Toronto", "Asia/Kathmandu", "Pacific/Chatham"] {
                page.render(events: events, error: nil, locale: Locale(identifier: "en_US"),
                            timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
                for visible in [NSRect(x: 0, y: 25, width: 1440, height: 875),
                                NSRect(x: 0, y: 25, width: 1920, height: 1080)] {
                    controller.applyBounds(visibleFrame: visible)
                    let window = controller.window!
                    for size in [window.minSize, window.maxSize] {
                        window.setFrame(NSRect(origin: visible.origin, size: size), display: false)
                        root.layoutSubtreeIfNeeded()
                        XCTAssertTrue(page.bounds.contains(scroll.frame))
                        XCTAssertTrue(scroll.hasVerticalScroller)
                        XCTAssertFalse(scroll.hasHorizontalScroller)
                        XCTAssertTrue(table.floatsGroupRows)
                        XCTAssertEqual(table.numberOfRows, 7)
                        for row in 0..<table.numberOfRows {
                            let expectedHeight = table.delegate!.tableView!(table, heightOfRow: row)
                            XCTAssertEqual(table.rect(ofRow: row).height, expectedHeight, accuracy: 0.5,
                                           "Native row height must update synchronously after opening or resizing")
                            if row > 0 {
                                XCTAssertEqual(table.rect(ofRow: row).minY, table.rect(ofRow: row - 1).maxY, accuracy: 0.5,
                                               "Rows must not leave stale blank gaps or overlap")
                            }
                            let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                            // Materialize even offscreen rows at the real table-calculated size.
                            cell.frame = NSRect(origin: .zero, size: NSSize(width: table.tableColumns[0].width,
                                height: expectedHeight))
                            cell.layoutSubtreeIfNeeded()
                            for text in descendants(cell).compactMap({ $0 as? NSTextField }) {
                                XCTAssertTrue(cell.bounds.insetBy(dx: -0.5, dy: -0.5).contains(text.frame), "\(text.stringValue), \(zone), \(size)")
                                let required = text.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: text.bounds.width, height: 100_000))
                                XCTAssertLessThanOrEqual(required.height, text.bounds.height + 0.5, "Clipped: \(text.stringValue), \(zone), \(size)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testDateGroupsPreserveRecordedOrderAcrossClockChanges() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let page = try XCTUnwrap(try view("logs-page", root) as? AuditLogView)
            let table = try XCTUnwrap(try view("logs-table", root) as? NSTableView)
            let date = Date(timeIntervalSince1970: 1_792_272_600)
            let events = [
                AuditEvent(date: date, message: "Newest recorded event."),
                AuditEvent(date: date.addingTimeInterval(86_400), message: "Before the clock moved back."),
                AuditEvent(date: date.addingTimeInterval(-60), message: "Oldest recorded event.")
            ]
            page.render(events: events, error: nil, locale: Locale(identifier: "en_US"),
                        timeZone: TimeZone(secondsFromGMT: 0)!)
            controller.showLogs(); root.layoutSubtreeIfNeeded()
            XCTAssertEqual(table.numberOfRows, 6)
            var dates: [String] = []
            var messages: [String] = []
            for row in 0..<table.numberOfRows {
                let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                for text in descendants(cell).compactMap({ $0 as? NSTextField }) {
                    if text.identifier?.rawValue == "log-date-label" { dates.append(text.stringValue) }
                    if text.identifier?.rawValue == "log-message" { messages.append(text.stringValue) }
                }
            }
            XCTAssertEqual(messages, events.map(\.message))
            XCTAssertEqual(dates.count, 3)
            XCTAssertEqual(dates.first, dates.last)
            XCTAssertFalse(dates.contains { $0.contains("Today") || $0.contains("Yesterday") })
        }
    }

    func testEmptyAndUnavailableLogsHaveHelpfulTextWithoutScrollingOtherPages() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            controller.showLogs()
            controller.renderLogs(events: [], error: nil)
            let empty = try XCTUnwrap(try view("logs-empty", root) as? NSTextField)
            XCTAssertEqual(empty.stringValue, "No activity logged yet.")
            XCTAssertFalse(empty.isHiddenOrHasHiddenAncestor)
            controller.renderLogs(events: [], error: "Logs unavailable. The encryption key could not be read. Try again later.")
            XCTAssertTrue(empty.stringValue.hasPrefix("Logs unavailable."))
            XCTAssertFalse(empty.isHiddenOrHasHiddenAncestor)
            for showSettings in [true, false] {
                controller.showSettings(showSettings)
                XCTAssertFalse(descendants(root).contains { $0 is NSScrollView && !$0.isHiddenOrHasHiddenAncestor })
            }
        }
    }

    func testDisabledDurationButtonsAreVisiblyMutedAndDoNotAct() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            var durationChanges = 0
            controller.onDuration = { _ in durationChanges += 1 }
            var state = WindowState(); state.duration = 60
            controller.render(state)
            let controls = try [button("minus", root), button("plus", root)]
            let enabled = try controls.map { try titleBrightness($0) }
            state.active = true; state.remaining = 3600; controller.render(state)
            for (index, control) in controls.enumerated() {
                XCTAssertFalse(control.isEnabled)
                let disabled = try titleBrightness(control)
                XCTAssertLessThan(disabled, enabled[index] * 0.45, "Disabled symbols must visibly differ from enabled symbols")
                control.performClick(nil)
                control.highlight(true)
                XCTAssertEqual(try titleBrightness(control), disabled, accuracy: 0.02, "Disabled controls must not show pressed feedback")
            }
            XCTAssertEqual(durationChanges, 0)
            let extend = try button("extend", root)
            XCTAssertTrue(extend.isEnabled)
            XCTAssertFalse(extend.isHiddenOrHasHiddenAncestor)
        }
    }

    private func titleBrightness(_ button: FlatButton) throws -> CGFloat {
        let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / button.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / button.bounds.height
        let title = button.visibleTitleBounds.insetBy(dx: -1, dy: -1)
        var peak: CGFloat = 0
        for y in max(0, Int(title.minY * scaleY))..<min(bitmap.pixelsHigh, Int(ceil(title.maxY * scaleY))) {
            for x in max(0, Int(title.minX * scaleX))..<min(bitmap.pixelsWide, Int(ceil(title.maxX * scaleX))) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                peak = max(peak, color.redComponent * color.alphaComponent)
            }
        }
        return peak
    }
    private func makeWindow() -> AppWindow {
        _ = NSApplication.shared
        let window = AppWindow(persistWindowFrame: false)
        window.applyBounds(visibleFrame: NSRect(x: 0, y: 25, width: 1440, height: 875))
        return window
    }
    private func view(_ id: String, _ root: NSView) throws -> NSView {
        try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == id })
    }
    private func button(_ id: String, _ root: NSView) throws -> FlatButton {
        try XCTUnwrap(try view(id, root) as? FlatButton)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() } else { try DispatchQueue.main.sync(execute: body) }
    }
}
