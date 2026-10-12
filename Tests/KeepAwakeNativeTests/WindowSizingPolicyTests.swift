import AppKit
import XCTest
@testable import KeepAwake

final class WindowSizingPolicyTests: XCTestCase {
    func testReferenceDisplayKeepsCurrentDefaultAndLimitsGrowthToTwentyFivePercent() {
        let policy = WindowSizingPolicy(visibleSize: NSSize(width: 1_440, height: 875), chromeHeight: 28)
        assertSize(policy.defaultFrameSize, NSSize(width: 420, height: 428))
        assertSize(policy.minimumFrameSize, policy.defaultFrameSize)
        assertSize(policy.maximumFrameSize, NSSize(width: 525, height: 535))
        XCTAssertEqual(policy.frameAspectRatio, 420.0 / 428.0, accuracy: 0.000_001)
        XCTAssertTrue(policy.minimumFitsVisibleSize)
    }

    func testActualChromeHeightChangesFrameRatioWithoutReducingContentMinimum() {
        for chrome in [CGFloat(0), 22, 28, 32, 56] {
            let policy = WindowSizingPolicy(visibleSize: NSSize(width: 1_440, height: 875), chromeHeight: chrome)
            XCTAssertEqual(policy.minimumFrameSize.width, 420)
            XCTAssertEqual(policy.minimumFrameSize.height - chrome, 400)
            XCTAssertEqual(policy.frameAspectRatio, 420 / (400 + chrome), accuracy: 0.000_001)
            assertSameRatio(policy.defaultFrameSize, policy)
            assertSameRatio(policy.maximumFrameSize, policy)
        }
    }

    func testLargerDisplayDefaultGrowsModestlyAndStopsGrowingAtFifteenPercent() {
        let medium = WindowSizingPolicy(visibleSize: NSSize(width: 1_584, height: 962.5), chromeHeight: 28)
        assertSize(medium.defaultFrameSize, NSSize(width: 462, height: 470.8))
        let large = WindowSizingPolicy(visibleSize: NSSize(width: 2_560, height: 1_440), chromeHeight: 28)
        let enormous = WindowSizingPolicy(visibleSize: NSSize(width: 8_000, height: 6_000), chromeHeight: 28)
        assertSize(large.defaultFrameSize, NSSize(width: 483, height: 492.2))
        assertSize(large.defaultFrameSize, enormous.defaultFrameSize)
        assertSize(large.maximumFrameSize, NSSize(width: 603.75, height: 615.25))
    }

    func testSmallDisplaysKeepUsableMinimumAndCapMaximumToPhysicalSpace() {
        let policy = WindowSizingPolicy(visibleSize: NSSize(width: 800, height: 500), chromeHeight: 28)
        assertSize(policy.defaultFrameSize, NSSize(width: 420, height: 428))
        XCTAssertEqual(policy.maximumFrameSize.height, 500, accuracy: 0.000_001)
        assertSameRatio(policy.maximumFrameSize, policy)
        XCTAssertTrue(policy.minimumFitsVisibleSize)
        let narrow = WindowSizingPolicy(visibleSize: NSSize(width: 450, height: 900), chromeHeight: 28)
        XCTAssertEqual(narrow.maximumFrameSize.width, 450, accuracy: 0.000_001)
        assertSameRatio(narrow.maximumFrameSize, narrow)
        let impossible = WindowSizingPolicy(visibleSize: NSSize(width: 320, height: 300), chromeHeight: 28)
        XCTAssertFalse(impossible.minimumFitsVisibleSize)
        assertSize(impossible.defaultFrameSize, impossible.minimumFrameSize)
        assertSize(impossible.maximumFrameSize, impossible.minimumFrameSize)
        assertSize(impossible.constrain(NSSize(width: 200, height: 200)), impossible.minimumFrameSize)
    }

    func testWidthHeightAndCornerDragsStayProportionalInBothDirections() {
        let policy = WindowSizingPolicy(visibleSize: NSSize(width: 1_440, height: 875), chromeHeight: 28)
        let initial = policy.defaultFrameSize
        let expected = NSSize(width: 462, height: 470.8)
        assertSize(policy.constrain(NSSize(width: 462, height: initial.height), relativeTo: initial), expected)
        assertSize(policy.constrain(NSSize(width: initial.width, height: 470.8), relativeTo: initial), expected)
        assertSize(policy.constrain(expected, relativeTo: initial), expected)
        assertSize(policy.constrain(NSSize(width: 420, height: expected.height), relativeTo: expected), initial)
        assertSize(policy.constrain(NSSize(width: expected.width, height: 428), relativeTo: expected), initial)
        assertSize(policy.constrain(NSSize(width: 420 * 1.04, height: 428 * 1.10), relativeTo: initial), expected)
        assertSize(policy.constrain(NSSize(width: 420 * 1.10, height: 428 * 1.04), relativeTo: initial), expected)
    }

    func testResizeClampsBothAxesTogetherAndScreenMoveDoesNotResetUserChoice() {
        let large = WindowSizingPolicy(visibleSize: NSSize(width: 2_560, height: 1_440), chromeHeight: 28)
        assertSize(large.constrain(NSSize(width: 20_000, height: 20_000)), large.maximumFrameSize)
        assertSize(large.constrain(NSSize(width: 1, height: 1)), large.minimumFrameSize)
        let chosen = NSSize(width: 462, height: 470.8)
        let smaller = WindowSizingPolicy(visibleSize: NSSize(width: 800, height: 500), chromeHeight: 28)
        assertSize(smaller.constrain(chosen, relativeTo: chosen), chosen)
        assertSize(smaller.constrain(large.maximumFrameSize, relativeTo: large.maximumFrameSize), smaller.maximumFrameSize)
        assertSize(large.constrain(chosen, relativeTo: chosen), chosen)
    }

    func testMalformedInputsRemainFiniteAndWithinUsableBounds() {
        let policy = WindowSizingPolicy(visibleSize: NSSize(width: CGFloat.nan, height: -CGFloat.infinity), chromeHeight: CGFloat.infinity)
        assertSize(policy.defaultFrameSize, NSSize(width: 420, height: 428))
        for proposed in [NSSize(width: CGFloat.nan, height: CGFloat.infinity), NSSize(width: -CGFloat.infinity, height: -1), NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)] {
            let result = policy.constrain(proposed, relativeTo: NSSize(width: CGFloat.nan, height: 0))
            assertInBounds(result, policy)
        }
    }

    func testVariedScreenAndResizeInputsPreserveAllSizeInvariants() {
        for visible in [NSSize(width: 800, height: 500), NSSize(width: 1_280, height: 720), NSSize(width: 1_440, height: 875), NSSize(width: 1_728, height: 1_050), NSSize(width: 2_560, height: 1_440)] {
            let policy = WindowSizingPolicy(visibleSize: visible, chromeHeight: 28)
            assertInBounds(policy.defaultFrameSize, policy)
            XCTAssertLessThanOrEqual(policy.maximumFrameSize.width, policy.defaultFrameSize.width * 1.25 + 0.000_001)
            XCTAssertLessThanOrEqual(policy.maximumFrameSize.height, policy.defaultFrameSize.height * 1.25 + 0.000_001)
            XCTAssertLessThanOrEqual(policy.maximumFrameSize.width, visible.width + 0.000_001)
            XCTAssertLessThanOrEqual(policy.maximumFrameSize.height, visible.height + 0.000_001)
            for width in stride(from: CGFloat(100), through: 1_000, by: 73) {
                for height in stride(from: CGFloat(100), through: 1_000, by: 89) {
                    assertInBounds(policy.constrain(NSSize(width: width, height: height)), policy)
                }
            }
        }
    }

    private func assertInBounds(_ size: NSSize, _ policy: WindowSizingPolicy, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(size.width.isFinite && size.height.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(size.width, policy.minimumFrameSize.width - 0.000_001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(size.height, policy.minimumFrameSize.height - 0.000_001, file: file, line: line)
        XCTAssertLessThanOrEqual(size.width, policy.maximumFrameSize.width + 0.000_001, file: file, line: line)
        XCTAssertLessThanOrEqual(size.height, policy.maximumFrameSize.height + 0.000_001, file: file, line: line)
        assertSameRatio(size, policy, file: file, line: line)
    }

    private func assertSameRatio(_ size: NSSize, _ policy: WindowSizingPolicy, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(size.width / size.height, policy.frameAspectRatio, accuracy: 0.000_001, file: file, line: line)
    }

    private func assertSize(_ actual: NSSize, _ expected: NSSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000_001, file: file, line: line)
    }
}
