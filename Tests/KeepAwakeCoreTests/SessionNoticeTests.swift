import Foundation
import XCTest
@testable import KeepAwakeCore

final class SessionNoticeTests: XCTestCase {
    func testCompletionUsesRequestedLocalTimezoneAndCalendarDate() throws {
        let date = try instant("2026-10-16T00:30:00Z")
        let toronto = try notice(date, zone: "America/Toronto")
        let kolkata = try notice(date, zone: "Asia/Kolkata")
        XCTAssertTrue(toronto.hasPrefix("Timer stopped · Time elapsed\n"))
        XCTAssertTrue(toronto.contains("Oct 15, 2026"), toronto)
        XCTAssertTrue(toronto.contains("8:30"), toronto)
        XCTAssertTrue(toronto.contains("PM"), toronto)
        XCTAssertTrue(toronto.contains("EDT"), toronto)
        XCTAssertTrue(kolkata.contains("Oct 16, 2026"), kolkata)
        XCTAssertTrue(kolkata.contains("6:00"), kolkata)
        XCTAssertTrue(kolkata.contains("AM"), kolkata)
        XCTAssertNotEqual(toronto, kolkata)
        XCTAssertEqual(toronto.components(separatedBy: "\n").count, 2)
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

    func testEveryKnownReasonUsesTheSuppliedStopInstant() throws {
        let date = try instant("2026-10-16T00:30:00Z")
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        for reason in allReasons where reason != .interrupted {
            let text = SessionNotice.message(for: reason, finishedAt: date,
                                             locale: Locale(identifier: "en_GB"), timeZone: zone)
            let lines = text.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 2, text)
            XCTAssertEqual(lines.first, "Timer stopped · \(reason.shortLabel)")
            XCTAssertTrue(lines.last?.contains("15 Oct 2026") == true, text)
            XCTAssertTrue(lines.last?.contains("20:30") == true, text)
        }
        XCTAssertEqual(SessionNotice.message(for: nil, finishedAt: date), "")
    }

    func testMissingStopInstantDoesNotInventOne() {
        for reason in allReasons {
            XCTAssertEqual(SessionNotice.message(for: reason, finishedAt: nil), reason.message)
        }
    }

    func testUnexpectedInterruptionIgnoresAnUntrustedSuppliedStopInstant() throws {
        let text = SessionNotice.message(for: .interrupted,
                                         finishedAt: try instant("2026-10-16T00:30:00Z"))
        XCTAssertEqual(text, "Timer stopped · Unexpected interruption\nCause and stop time unknown.")
        XCTAssertFalse(text.contains("2026"))
        XCTAssertFalse(text.lowercased().contains("crash"))
    }

    func testReasonsHaveDistinctConciseLabelsAndAccurateAuditDescriptions() {
        XCTAssertEqual(Set(allReasons.map(\.shortLabel)).count, allReasons.count)
        for reason in allReasons {
            XCTAssertFalse(reason.shortLabel.contains("\n"))
            XCTAssertFalse(reason.auditDescription.isEmpty)
            XCTAssertTrue(reason.message.hasPrefix("Timer stopped · "))
        }
        XCTAssertEqual(SessionStopReason.manual.shortLabel, "Stopped by you")
        XCTAssertEqual(SessionStopReason.expired.shortLabel, "Time elapsed")
        XCTAssertEqual(SessionStopReason.lowBattery.shortLabel, "Battery below 15%")
        XCTAssertEqual(SessionStopReason.shutdown.shortLabel, "Logout, restart or shutdown")
        XCTAssertTrue(SessionStopReason.shutdown.auditDescription.contains("macOS did not identify which"))
        XCTAssertEqual(SessionStopReason.interrupted.auditDescription,
                       "Unexpected timer interruption detected. Cause and stop time unknown.")
    }

    func testPersistedCompletionDisplaysItsRecordedEndInCurrentLocalTimezone() throws {
        let record = try makeRecord(reason: .expired, endedAt: instant("2026-10-16T00:30:00Z"))
        let toronto = SessionNotice.message(for: record, locale: Locale(identifier: "en_US"),
                                            timeZone: try XCTUnwrap(TimeZone(identifier: "America/Toronto")))
        let kolkata = SessionNotice.message(for: record, locale: Locale(identifier: "en_US"),
                                            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata")))
        XCTAssertTrue(toronto.hasPrefix("Timer stopped · Time elapsed\n"), toronto)
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
            XCTAssertEqual(text, "Timer stopped · Unexpected interruption\nCause and stop time unknown.")
            XCTAssertFalse(text.contains("finished"))
            XCTAssertFalse(text.contains("2026"), "A start time must not be presented as the unknown stop time")
        }
    }

    func testLifecycleAndSafetyOutcomesDescribeTheActualStopAndIncludeKnownDate() throws {
        let examples: [(SessionStopReason, String)] = [
            (.systemSleep, "Timer stopped · Mac went to sleep"),
            (.shutdown, "Timer stopped · Logout, restart or shutdown"),
            (.quit, "Timer stopped · Cat Run quit"),
            (.sessionInactive, "Timer stopped · User switched"),
            (.unresponsive, "Timer stopped · App stopped responding"),
            (.storageFailure, "Timer stopped · Session could not be saved"),
            (.lowBattery, "Timer stopped · Battery below 15%"),
            (.batteryUnavailable, "Timer stopped · Battery reading unavailable")
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

    func testMissedSleepShowsDetectionTimeWithoutClaimingItWasTheStopTime() throws {
        let detected = try instant("2026-10-16T00:30:00Z")
        let record = try makeRecord(reason: .systemSleep, endedAt: nil, detectedAt: detected)
        let text = SessionNotice.message(for: record, locale: Locale(identifier: "en_GB"),
                                         timeZone: try XCTUnwrap(TimeZone(identifier: "America/Toronto")))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first, "Timer stopped · Mac went to sleep")
        XCTAssertTrue(lines.last?.hasPrefix("Detected: ") == true, text)
        XCTAssertTrue(lines.last?.contains("15 Oct 2026") == true, text)
        XCTAssertTrue(lines.last?.contains("20:30") == true, text)
    }

    func testInterruptionDetectionTimestampIsNotShownAsAStopTimestamp() throws {
        let record = try makeRecord(reason: .interrupted, endedAt: nil,
                                    detectedAt: instant("2026-10-16T00:30:00Z"))
        XCTAssertEqual(SessionNotice.message(for: record),
                       "Timer stopped · Unexpected interruption\nCause and stop time unknown.")
    }

    func testPersistedStopDisambiguatesRepeatedDaylightSavingHour() throws {
        let daylight = try makeRecord(reason: .systemSleep, endedAt: instant("2026-11-01T05:30:00Z"))
        let standard = try makeRecord(reason: .systemSleep, endedAt: instant("2026-11-01T06:30:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let first = SessionNotice.message(for: daylight, locale: Locale(identifier: "en_US"), timeZone: zone)
        let second = SessionNotice.message(for: standard, locale: Locale(identifier: "en_US"), timeZone: zone)
        for text in [first, second] {
            XCTAssertTrue(text.hasPrefix("Timer stopped · Mac went to sleep\n"), text)
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
        XCTAssertTrue(text.hasPrefix("Timer stopped · Reason unavailable\n"), text)
        XCTAssertFalse(text.contains("finished"), "An unrecognized reason must never imply successful completion")
    }

    private var allReasons: [SessionStopReason] {
        [.manual, .expired, .lowBattery, .batteryUnavailable, .clockUnavailable,
         .assertionFailure, .systemSleep, .quit, .unresponsive, .sessionInactive,
         .shutdown, .interrupted, .storageFailure]
    }

    private func makeRecord(reason: SessionStopReason?, endedAt: Date?, detectedAt: Date? = nil) throws -> SessionRecord {
        var value: [String: Any] = [
            "version": 1, "id": UUID().uuidString,
            "startedAt": try instant("2026-10-15T23:30:00Z").timeIntervalSince1970,
            "state": reason == nil ? "active" : "finished"
        ]
        if let reason { value["reason"] = reason.rawValue }
        if let endedAt { value["endedAt"] = endedAt.timeIntervalSince1970 }
        if let detectedAt { value["detectedAt"] = detectedAt.timeIntervalSince1970; value["version"] = 2 }
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
