import Foundation
import XCTest
@testable import KeepAwakeCore

final class SessionNoticeTests: XCTestCase {
    func testCompletionUsesRequestedLocalTimezoneAndCalendarDate() throws {
        let date = try instant("2026-10-16T00:30:00Z")
        let toronto = try notice(date, zone: "America/Toronto")
        let kolkata = try notice(date, zone: "Asia/Kolkata")
        XCTAssertTrue(toronto.hasPrefix("Timer finished at "))
        XCTAssertTrue(toronto.contains("Oct 15, 2026"), toronto)
        XCTAssertTrue(toronto.contains("8:30"), toronto)
        XCTAssertTrue(toronto.contains("PM"), toronto)
        XCTAssertTrue(toronto.contains("EDT"), toronto)
        XCTAssertTrue(kolkata.contains("Oct 16, 2026"), kolkata)
        XCTAssertTrue(kolkata.contains("6:00"), kolkata)
        XCTAssertTrue(kolkata.contains("AM"), kolkata)
        XCTAssertNotEqual(toronto, kolkata)
        XCTAssertTrue(toronto.hasSuffix("."))
    }

    func testDaylightSavingRepeatedHourIncludesDistinctTimezone() throws {
        let daylight = try notice(instant("2026-11-01T05:30:00Z"), zone: "America/Toronto")
        let standard = try notice(instant("2026-11-01T06:30:00Z"), zone: "America/Toronto")
        for text in [daylight, standard] {
            XCTAssertTrue(text.contains("Nov 1, 2026"), text)
            XCTAssertTrue(text.contains("1:30"), text)
            XCTAssertTrue(text.contains("AM"), text)
        }
        XCTAssertTrue(daylight.contains("EDT"), daylight)
        XCTAssertTrue(standard.contains("EST"), standard)
        XCTAssertNotEqual(daylight, standard)
    }

    func testLocaleSelectsTwelveOrTwentyFourHourTime() throws {
        let date = try instant("2026-10-16T00:30:00Z")
        let american = try notice(date, zone: "America/Toronto", locale: "en_US")
        let british = try notice(date, zone: "America/Toronto", locale: "en_GB")
        XCTAssertTrue(american.contains("8:30"), american)
        XCTAssertTrue(american.contains("PM"), american)
        XCTAssertTrue(british.contains("20:30"), british)
        XCTAssertFalse(british.contains("PM"), british)
        XCTAssertTrue(british.contains("15 Oct 2026"), british)
    }

    func testUnrelatedStopsAndMissingCompletionKeepExistingMessages() throws {
        let date = try instant("2026-10-16T00:30:00Z")
        for reason in [SessionStopReason.manual, .lowBattery, .batteryUnavailable, .clockUnavailable, .assertionFailure, .systemSleep, .quit] {
            XCTAssertEqual(SessionNotice.message(for: reason, finishedAt: date), reason.message)
        }
        XCTAssertEqual(SessionNotice.message(for: nil, finishedAt: date), "")
        XCTAssertEqual(SessionNotice.message(for: .expired, finishedAt: nil), SessionStopReason.expired.message)
    }

    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func notice(_ date: Date, zone: String, locale: String = "en_US") throws -> String {
        SessionNotice.message(for: .expired, finishedAt: date,
                              locale: Locale(identifier: locale),
                              timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
    }
}
