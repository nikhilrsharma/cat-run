import XCTest
@testable import KeepAwakeCore

final class DurationFormatTests: XCTestCase {
    func testMinuteRoundingAtCountdownBoundaries() {
        for (seconds, expected) in [(0.0, "00m"), (0.01, "01m"), (60, "01m"), (60.01, "02m"), (3599, "01h 00m"), (3600, "01h 00m"), (3600.01, "01h 01m"), (21600, "06h 00m")] {
            XCTAssertEqual(DurationFormat.string(seconds: seconds), expected)
        }
    }
    func testEverySelectableDurationUsesPaddedDigitsAndSingleUnits() {
        for minutes in stride(from: 15, through: 360, by: 15) {
            let text = DurationFormat.string(minutes: minutes)
            XCTAssertTrue(text.hasSuffix("m"))
            XCTAssertEqual(text.contains("h"), minutes >= 60)
            XCTAssertFalse(text.contains("hh"))
            XCTAssertFalse(text.contains("mm"))
            XCTAssertEqual(text.count, minutes < 60 ? 3 : 7)
        }
        XCTAssertEqual(DurationFormat.string(minutes: 3), "03m")
        XCTAssertEqual(DurationFormat.string(minutes: 63), "01h 03m")
        XCTAssertEqual(DurationFormat.string(minutes: 75), "01h 15m")
        XCTAssertEqual(DurationFormat.string(minutes: 345), "05h 45m")
    }
    func testInvalidClockValuesCannotOverflowFormatting() {
        for value in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(DurationFormat.string(seconds: value), "00m")
        }
        XCTAssertEqual(DurationFormat.string(seconds: Double.greatestFiniteMagnitude), "06h 00m")
        XCTAssertEqual(DurationFormat.string(minutes: Int.max), "06h 00m")
        XCTAssertEqual(DurationFormat.string(minutes: -15), "00m")
    }
}
