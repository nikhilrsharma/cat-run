import Foundation
import XCTest
@testable import KeepAwakeCore

final class AuditLogTextTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testFullSnapshotPreservesRecordingOrderAndRepeatedDateGroups() {
        let day = Date(timeIntervalSince1970: 1_792_272_600)
        let events = [
            AuditEvent(date: day, message: "Latest event."),
            AuditEvent(date: day.addingTimeInterval(86_400), message: "Before clock rollback."),
            AuditEvent(date: day.addingTimeInterval(-1), message: "Oldest event.")
        ]
        let text = AuditLogText.string(events: events, locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines[2], lines[8])
        XCTAssertTrue(lines[3].hasSuffix("Latest event."))
        XCTAssertTrue(lines[6].hasSuffix("Before clock rollback."))
        XCTAssertTrue(lines[9].hasSuffix("Oldest event."))
        XCTAssertFalse(text.contains("Today"))
        XCTAssertFalse(text.contains("Yesterday"))
        XCTAssertFalse(events.contains { text.contains($0.id.uuidString) })
    }

    func testRepeatedDaylightSavingHourIncludesDifferentOffsets() throws {
        let formatter = ISO8601DateFormatter()
        let events = [
            AuditEvent(date: try XCTUnwrap(formatter.date(from: "2026-11-01T06:30:00Z")), message: "Later."),
            AuditEvent(date: try XCTUnwrap(formatter.date(from: "2026-11-01T05:30:00Z")), message: "Earlier.")
        ]
        let text = AuditLogText.string(events: events, locale: locale,
                                      timeZone: try XCTUnwrap(TimeZone(identifier: "America/Toronto")))
        let timeLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("01:30:00") }
        XCTAssertEqual(timeLines.count, 2)
        let later = timeLines[0].components(separatedBy: "  ")[0]
        let earlier = timeLines[1].components(separatedBy: "  ")[0]
        XCTAssertNotEqual(later, earlier)
    }

    func testAllFourThousandEventsExportWithoutTruncation() {
        let date = Date(timeIntervalSince1970: 1_792_272_600)
        let events = (0..<4_000).map { AuditEvent(date: date.addingTimeInterval(Double(-$0)), message: "Activity number \($0).") }
        let text = AuditLogText.string(events: events, locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.contains("Activity number ") }.count, 4_000)
        XCTAssertTrue(text.hasSuffix("Activity number 3999."))
        XCTAssertEqual(AuditLogText.string(events: []), "")
    }
}
