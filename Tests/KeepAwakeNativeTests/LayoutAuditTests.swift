import AppKit
import KeepAwakeCore
import ServiceManagement
import XCTest
@testable import KeepAwake

/// Exercises the actual window's text cells, including fallback fonts and longer month names.
/// It never creates the app coordinator or changes login, battery, or power settings.
final class LayoutAuditTests: XCTestCase {
    func testLocalizedOutcomeDatesFitAtBothWindowLimitsThroughoutTheYear() throws {
        let locales = ["en_US", "en_GB", "de_DE", "fr_FR", "es_ES", "pt_BR", "pl_PL",
                       "ru_RU", "uk_UA", "fi_FI", "ar_SA", "he_IL", "hi_IN", "bn_IN",
                       "th_TH", "ja_JP", "zh_CN", "ko_KR"]
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Chatham"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dates = try (1...12).map { month in
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: 28,
                                                             hour: 23, minute: 59)))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var notices: [(String, String)] = []
        for locale in locales {
            for date in dates {
                for reason in [SessionStopReason.expired, .batteryUnavailable, .systemSleep] {
                    var recordData: [String: Any] = [
                        "version": 1, "id": UUID().uuidString,
                        "startedAt": date.addingTimeInterval(-900).timeIntervalSince1970,
                        "state": "finished", "reason": reason.rawValue
                    ]
                    // Missed sleep callbacks can establish detection time only.
                    recordData[reason == .systemSleep ? "detectedAt" : "endedAt"] = date.timeIntervalSince1970
                    let data = try JSONSerialization.data(withJSONObject: recordData)
                    let record = try decoder.decode(SessionRecord.self, from: data)
                    notices.append(("\(locale), \(date), \(reason)",
                                    SessionNotice.message(for: record, locale: Locale(identifier: locale), timeZone: zone)))
                }
            }
        }
        try onMain {
            _ = NSApplication.shared
            let controller = AppWindow(persistWindowFrame: false)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            let root = try XCTUnwrap(window.contentView)
            let notice = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "notice" })
            let action = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "action" })
            let battery = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "battery" })
            controller.applyBounds(visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1080))
            for size in [window.minSize, window.maxSize] {
                window.setFrame(NSRect(origin: .zero, size: size), display: false)
                for (context, message) in notices {
                    var state = WindowState()
                    state.recent = [360, 345, 330]
                    state.notice = message
                    controller.render(state)
                    root.layoutSubtreeIfNeeded()
                    try assertTextFits(notice, context: "\(size) \(context)")
                    let noticeFrame = notice.convert(notice.bounds, to: root)
                    let actionFrame = action.convert(action.bounds, to: root)
                    let batteryFrame = battery.convert(battery.bounds, to: root)
                    XCTAssertGreaterThanOrEqual(noticeFrame.minY, batteryFrame.maxY + 4,
                                                "Outcome collides with battery: \(context)")
                    XCTAssertLessThanOrEqual(noticeFrame.maxY, actionFrame.minY,
                                             "Outcome collides with Start: \(context)")
                }
            }
        }
    }

    func testEveryLoginServiceStatusFitsAndApprovalButtonStaysInsideSettings() throws {
        let statuses: [SMAppService.Status] = [.enabled, .notRegistered, .requiresApproval, .notFound]
        try onMain {
            _ = NSApplication.shared
            let controller = AppWindow(persistWindowFrame: false)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            let root = try XCTUnwrap(window.contentView)
            controller.showSettings(true)
            controller.applyBounds(visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1080))
            for size in [window.minSize, window.maxSize] {
                window.setFrame(NSRect(origin: .zero, size: size), display: false)
                for status in statuses {
                    for requested in [nil, true, false] as [Bool?] {
                        for active in [false, true] {
                            var state = WindowState()
                            state.active = active
                            state.loginEnabled = status == .enabled || status == .requiresApproval
                            state.loginNeedsApproval = status == .requiresApproval
                            state.loginNote = LoginStatusText.note(for: status, failedRequest: requested)
                            controller.render(state)
                            root.layoutSubtreeIfNeeded()
                            let context = "\(size), status \(status.rawValue), request \(String(describing: requested)), active \(active)"
                            for label in descendants(root).compactMap({ $0 as? NSTextField })
                                where !label.isHiddenOrHasHiddenAncestor && !label.stringValue.isEmpty {
                                try assertTextFits(label, context: context)
                            }
                            for view in descendants(root) where !view.isHiddenOrHasHiddenAncestor {
                                guard view is NSControl else { continue }
                                XCTAssertTrue(root.bounds.insetBy(dx: -0.5, dy: -0.5)
                                    .contains(view.convert(view.bounds, to: root)), context)
                            }
                        }
                    }
                }
            }
        }
    }

    private func assertTextFits(_ label: NSTextField, context: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let cell = try XCTUnwrap(label.cell, file: file, line: line)
        let required = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000))
        XCTAssertLessThanOrEqual(required.height, label.bounds.height + 0.5,
                                 "Clipped text (needs \(required.height), has \(label.bounds.height)): \(label.stringValue), \(context)",
                                 file: file, line: line)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }
}
