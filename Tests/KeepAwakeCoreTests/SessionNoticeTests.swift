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
        for reason in allReasons where reason != .expired {
            XCTAssertEqual(SessionNotice.message(for: reason, finishedAt: date), reason.message)
        }
        XCTAssertEqual(SessionNotice.message(for: nil, finishedAt: date), "")
        XCTAssertEqual(SessionNotice.message(for: .expired, finishedAt: nil), SessionStopReason.expired.message)
    }

    func testPersistedCompletionDisplaysItsRecordedEndInCurrentLocalTimezone() throws {
        let record = try makeRecord(reason: .expired, endedAt: instant("2026-10-16T00:30:00Z"))
        let toronto = SessionNotice.message(for: record, locale: Locale(identifier: "en_US"),
                                            timeZone: try XCTUnwrap(TimeZone(identifier: "America/Toronto")))
        let kolkata = SessionNotice.message(for: record, locale: Locale(identifier: "en_US"),
                                            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata")))
        XCTAssertTrue(toronto.hasPrefix("Timer finished at "), toronto)
        XCTAssertTrue(toronto.contains("Oct 15, 2026"), toronto)
        XCTAssertTrue(toronto.contains("8:30"), toronto)
        XCTAssertTrue(toronto.contains("PM"), toronto)
        XCTAssertTrue(toronto.contains("EDT"), toronto)
        XCTAssertTrue(kolkata.contains("Oct 16, 2026"), kolkata)
        XCTAssertTrue(kolkata.contains("6:00"), kolkata)
        XCTAssertTrue(kolkata.contains("AM"), kolkata)
        XCTAssertNotEqual(toronto, kolkata)
    }

    func testInterruptionWithoutKnownStopTimeNeverLooksLikeSuccessfulCompletion() throws {
        let record = try makeRecord(reason: .interrupted, endedAt: nil)
        for zone in ["America/Toronto", "Asia/Kolkata", "Pacific/Chatham"] {
            let text = SessionNotice.message(for: record, locale: Locale(identifier: "en_US"),
                                             timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
            XCTAssertEqual(text, "Previous timer interrupted. Stop time unknown.")
            XCTAssertFalse(text.contains("finished"))
            XCTAssertFalse(text.contains("2026"), "A start time must not be presented as the unknown stop time")
        }
    }

    func testLifecycleAndSafetyOutcomesDescribeTheActualStopAndIncludeKnownDate() throws {
        let examples: [(SessionStopReason, String)] = [
            (.systemSleep, "Stopped for sleep."),
            (.shutdown, "Stopped for logout or shutdown."),
            (.quit, "Stopped when Cat Run quit."),
            (.sessionInactive, "Stopped for user switch."),
            (.unresponsive, "Stopped: app was unresponsive."),
            (.storageFailure, "Stopped: session could not be saved."),
            (.lowBattery, "Stopped: battery below 15%."),
            (.batteryUnavailable, "Stopped: battery reading unavailable.")
        ]
        let end = try instant("2026-10-16T00:30:00Z")
        for (reason, title) in examples {
            let text = SessionNotice.message(for: try makeRecord(reason: reason, endedAt: end),
                                             locale: Locale(identifier: "en_GB"),
                                             timeZone: try XCTUnwrap(TimeZone(identifier: "America/Toronto")))
            let lines = text.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 2, text)
            XCTAssertEqual(lines.first, title)
            XCTAssertTrue(lines.last?.contains("15 Oct 2026") == true, text)
            XCTAssertTrue(lines.last?.contains("20:30") == true, text)
            XCTAssertFalse(text.contains("Timer finished"), "An interrupted session must not be labelled completed")
        }
    }

    func testMissingEndTimeForKnownOutcomeIsRejectedBeforeFormatting() throws {
        for reason in allReasons where reason != .interrupted {
            XCTAssertThrowsError(try makeRecord(reason: reason, endedAt: nil),
                                 "Damaged \(reason) record must not become a misleading notice") {
                XCTAssertEqual($0 as? SessionJournalError, .invalidRecord)
            }
        }
    }

    func testPersistedStopDisambiguatesRepeatedDaylightSavingHour() throws {
        let daylight = try makeRecord(reason: .systemSleep, endedAt: instant("2026-11-01T05:30:00Z"))
        let standard = try makeRecord(reason: .systemSleep, endedAt: instant("2026-11-01T06:30:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let first = SessionNotice.message(for: daylight, locale: Locale(identifier: "en_US"), timeZone: zone)
        let second = SessionNotice.message(for: standard, locale: Locale(identifier: "en_US"), timeZone: zone)
        for text in [first, second] {
            XCTAssertTrue(text.hasPrefix("Stopped for sleep.\n"), text)
            XCTAssertTrue(text.contains("Nov 1, 2026"), text)
            XCTAssertTrue(text.contains("1:30"), text)
        }
        XCTAssertTrue(first.contains("EDT"), first)
        XCTAssertTrue(second.contains("EST"), second)
        XCTAssertNotEqual(first, second)
    }

    func testMissingAndStillActiveRecordsHaveNoTerminalNotice() throws {
        XCTAssertEqual(SessionNotice.message(for: nil as SessionRecord?), "")
        XCTAssertEqual(SessionNotice.message(for: try makeRecord(reason: nil, endedAt: nil)), "")
    }

    func testUnknownFutureStopReasonHasAnHonestFallbackAfterDowngrade() throws {
        let value: [String: Any] = [
            "version": 1, "id": UUID().uuidString,
            "startedAt": try instant("2026-10-15T23:30:00Z").timeIntervalSince1970,
            "state": "finished", "reason": "futureSafetyCondition",
            "endedAt": try instant("2026-10-16T00:30:00Z").timeIntervalSince1970
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: value))
        let text = SessionNotice.message(for: record)
        XCTAssertEqual(text, "Previous timer status unavailable.")
        XCTAssertFalse(text.contains("finished"), "An unrecognized reason must never imply successful completion")
    }

    private var allReasons: [SessionStopReason] {
        [.manual, .expired, .lowBattery, .batteryUnavailable, .clockUnavailable,
         .assertionFailure, .systemSleep, .quit, .unresponsive, .sessionInactive,
         .shutdown, .interrupted, .storageFailure]
    }

    private func makeRecord(reason: SessionStopReason?, endedAt: Date?) throws -> SessionRecord {
        var value: [String: Any] = [
            "version": 1, "id": UUID().uuidString,
            "startedAt": try instant("2026-10-15T23:30:00Z").timeIntervalSince1970,
            "state": reason == nil ? "active" : "finished"
        ]
        if let reason { value["reason"] = reason.rawValue }
        if let endedAt { value["endedAt"] = endedAt.timeIntervalSince1970 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: value))
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
