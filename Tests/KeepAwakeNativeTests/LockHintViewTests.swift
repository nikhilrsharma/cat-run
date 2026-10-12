import AppKit
import XCTest
@testable import KeepAwake

final class LockHintViewTests: XCTestCase {
    func testNativeTooltipAndAccessibleImageExplainWhySettingIsLocked() {
        onMain {
            let view = LockHintView(frame: NSRect(x: 0, y: 0, width: 13, height: 15))
            XCTAssertEqual(view.toolTip, "Keeps your Mac awake whenever you start a timer.")
            XCTAssertEqual(view.accessibilityHelp(), LockHintView.hintText)
            XCTAssertTrue(view.isAccessibilityElement())
            XCTAssertEqual(view.accessibilityRole(), .image)
            XCTAssertEqual(view.accessibilityLabel(), "Locked setting")
            view.onHoverChange = { _ in }
            XCTAssertNil(view.toolTip, "Custom bubble replaces native tooltip instead of duplicating it")
            XCTAssertEqual(view.accessibilityHelp(), LockHintView.hintText)
            view.onHoverChange = nil
            XCTAssertEqual(view.toolTip, LockHintView.hintText)
        }
    }

    func testEntryAndExitPublishOnlyRealHoverChanges() throws {
        try onMain {
            let view = LockHintView(frame: NSRect(x: 0, y: 0, width: 13, height: 15))
            let entered = try event(.mouseEntered)
            let exited = try event(.mouseExited)
            var changes: [Bool] = []
            view.onHoverChange = { changes.append($0) }
            view.mouseEntered(with: entered)
            view.mouseEntered(with: entered)
            view.mouseExited(with: exited)
            view.mouseExited(with: exited)
            view.mouseEntered(with: entered)
            XCTAssertEqual(changes, [true, false, true])
        }
    }

    func testTrackingAreaFollowsVisibleRectWithoutAccumulatingAcrossLayout() throws {
        try onMain {
            let view = LockHintView(frame: NSRect(x: 0, y: 0, width: 13, height: 15))
            view.updateTrackingAreas()
            let first = try XCTUnwrap(view.trackingAreas.first { $0.owner as? LockHintView === view })
            XCTAssertEqual(view.trackingAreas.filter { $0.owner as? LockHintView === view }.count, 1)
            XCTAssertTrue(first.options.contains(.mouseEnteredAndExited))
            XCTAssertTrue(first.options.contains(.mouseMoved))
            XCTAssertTrue(first.options.contains(.enabledDuringMouseDrag))
            XCTAssertTrue(first.options.contains(.activeAlways))
            XCTAssertTrue(first.options.contains(.inVisibleRect))
            XCTAssertTrue(first.owner as? LockHintView === view)
            view.setFrameSize(NSSize(width: 24, height: 24))
            for _ in 0..<5 { view.updateTrackingAreas() }
            XCTAssertEqual(view.trackingAreas.filter { $0.owner as? LockHintView === view }.count, 1)
            XCTAssertFalse(view.trackingAreas.contains { $0 === first })
        }
    }

    func testMovementAndClickShowHelpWithoutAnEntryEvent() throws {
        try onMain {
            let view = LockHintView(frame: NSRect(x: 0, y: 0, width: 27, height: 27))
            let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let clicked = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            var changes: [Bool] = []
            view.onHoverChange = { changes.append($0) }
            view.mouseMoved(with: moved)
            view.mouseMoved(with: moved)
            view.resetHover()
            view.mouseDown(with: clicked)
            XCTAssertEqual(changes, [true, false, true])
            view.resetHover()
            view.isHidden = true
            view.mouseMoved(with: moved)
            view.mouseDown(with: clicked)
            XCTAssertEqual(changes, [true, false, true, false])
        }
    }

    func testHiddenDetachedAndExplicitlyDismissedHintsCanBeShownAgain() throws {
        try onMain {
            let view = LockHintView(frame: NSRect(x: 0, y: 0, width: 13, height: 15))
            let entered = try event(.mouseEntered)
            var changes: [Bool] = []
            view.onHoverChange = { changes.append($0) }
            view.mouseEntered(with: entered)
            view.viewDidHide()
            view.mouseEntered(with: entered)
            view.viewWillMove(toWindow: nil)
            view.mouseEntered(with: entered)
            view.setPointerInside(false)
            view.resetHover()
            view.mouseEntered(with: entered)
            XCTAssertEqual(changes, [true, false, true, false, true, false, true])
            view.isHidden = true
            view.mouseEntered(with: entered)
            XCTAssertEqual(changes.last, false)
        }
    }

    private func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }
}
