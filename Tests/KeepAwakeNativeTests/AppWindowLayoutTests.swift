import AppKit
import KeepAwakeCore
import XCTest
@testable import KeepAwake

/// Layout-only tests: no coordinator, power assertions, battery monitor, or login service.
final class AppWindowLayoutTests: XCTestCase {
    func testMainStatesFitWithoutScrollingOrOverlappingControls() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            for screen in screenFrames {
                for sizeChoice in [0.0, 0.5, 1.0] {
                    for state in mainStates {
                        controller.render(state)
                        resize(controller, screen: screen, fraction: sizeChoice)
                        try assertControlsFit(controller, context: "main \(screen.size), size \(sizeChoice), active \(state.active), notice \(state.notice)")
                    }
                }
            }
        }
    }

    func testPersistedSessionOutcomesFitAtBothSizeLimitsAcrossLocales() throws {
        let notices = try persistedSessionNotices()
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let label = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == "notice"
            })
            for screen in screenFrames {
                for sizeChoice in [0.0, 1.0] {
                    for (context, message) in notices {
                        var state = WindowState()
                        state.duration = 360
                        state.recent = [360, 345, 330]
                        state.battery = "Battery 90% · Plugged in"
                        state.notice = message
                        controller.render(state)
                        resize(controller, screen: screen, fraction: sizeChoice)
                        XCTAssertEqual(label.stringValue, message, "Stop explanation must not be truncated or substituted")
                        try assertControlsFit(controller, context: "\(context), screen \(screen.size), size \(sizeChoice)")
                    }
                }
            }
        }
    }

    func testSettingsFitAtBothWindowLimits() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            controller.showSettings(true)
            for screen in screenFrames {
                for sizeChoice in [0.0, 1.0] {
                    for state in settingsStates {
                        controller.render(state)
                        resize(controller, screen: screen, fraction: sizeChoice)
                        try assertControlsFit(controller, context: "settings \(screen.size), size \(sizeChoice), active \(state.active)")
                    }
                }
            }
        }
    }

    func testStartAndStopKeepExactlyTheSameFrame() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let screen = screenFrames[0]
            for sizeChoice in [0.0, 0.5, 1.0] {
                controller.render(mainStates[0])
                resize(controller, screen: screen, fraction: sizeChoice)
                let start = try button("Start", in: controller)
                let original = start.convert(start.bounds, to: controller.window!.contentView)
                for state in mainStates.dropFirst() {
                    controller.render(state)
                    controller.window?.contentView?.layoutSubtreeIfNeeded()
                    let action = try button(state.active ? "Stop" : "Start", in: controller)
                    let frame = action.convert(action.bounds, to: controller.window!.contentView)
                    XCTAssertEqual(frame, original, "Action moved between session states")
                }
            }
        }
    }

    func testWindowLimitsPreserveAspectAndCapGrowthAt25Percent() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            for screen in screenFrames {
                controller.applyBounds(visibleFrame: screen)
                let minimum = window.minSize
                XCTAssertGreaterThan(minimum.width, 0)
                XCTAssertGreaterThan(minimum.height, 0)
                let chrome = window.frameRect(forContentRect: NSRect(origin: .zero, size: AppWindow.minimumContentSize)).height - AppWindow.minimumContentSize.height
                let policy = WindowSizingPolicy(visibleSize: screen.size, chromeHeight: chrome)
                XCTAssertEqual(window.maxSize.width, policy.defaultFrameSize.width * 1.25, accuracy: 0.01)
                XCTAssertEqual(window.maxSize.height, policy.defaultFrameSize.height * 1.25, accuracy: 0.01)
                XCTAssertEqual(window.frame.width / window.frame.height, policy.frameAspectRatio, accuracy: 0.001)
                XCTAssertEqual(window.aspectRatio.width / window.aspectRatio.height, policy.frameAspectRatio, accuracy: 0.001)
                XCTAssertLessThanOrEqual(minimum.width, window.maxSize.width)
                XCTAssertLessThanOrEqual(minimum.height, window.maxSize.height)
                for state in mainStates + settingsStates {
                    controller.render(state)
                    controller.applyBounds(visibleFrame: screen)
                    XCTAssertEqual(window.minSize, minimum, "Minimum size changed with content")
                }
                window.setFrame(NSRect(x: screen.minX, y: screen.minY, width: 1, height: 1), display: false)
                controller.applyBounds(visibleFrame: screen)
                XCTAssertGreaterThanOrEqual(window.frame.width, minimum.width - 0.01)
                XCTAssertGreaterThanOrEqual(window.frame.height, minimum.height - 0.01)
                window.setFrame(NSRect(x: screen.minX, y: screen.minY, width: screen.width * 2, height: screen.height * 2), display: false)
                controller.applyBounds(visibleFrame: screen)
                XCTAssertLessThanOrEqual(window.frame.width, window.maxSize.width + 0.01)
                XCTAssertLessThanOrEqual(window.frame.height, window.maxSize.height + 0.01)
            }
        }
    }

    func testCheckboxDrawingSpaceAndLockedState() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            controller.render(mainStates[1])
            resize(controller, screen: screenFrames[0], fraction: 0)
            let mac = try button("Keep Mac awake", in: controller)
            let display = try button("Keep screen awake", in: controller)
            XCTAssertEqual(mac.state, .on)
            XCTAssertFalse(mac.isEnabled)
            XCTAssertTrue(display.isEnabled)
            for checkbox in [mac, display] {
                let titleWidth = (checkbox.title as NSString).size(withAttributes: [.font: checkbox.font!]).width
                XCTAssertGreaterThanOrEqual(checkbox.bounds.width, titleWidth + 28)
                XCTAssertGreaterThanOrEqual(checkbox.bounds.height, 20)
                XCTAssertEqual(checkbox.accessibilityRole(), .checkBox)
            }
            controller.render(mainStates[2])
            XCTAssertFalse(display.isEnabled)
            controller.showSettings(true)
            XCTAssertFalse(try button("Launch at login", in: controller).isEnabled)
            controller.render(settingsStates[0])
            XCTAssertTrue(try button("Launch at login", in: controller).isEnabled)
        }
    }

    func testExtremelySmallScreenPreservesUsableMinimumRatherThanOverlapping() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            controller.render(mainStates[3])
            let screen = NSRect(x: 0, y: 0, width: 480, height: 400)
            resize(controller, screen: screen, fraction: 0)
            let window = try XCTUnwrap(controller.window)
            // A display shorter than the usable minimum cannot fit the whole window.
            // Preserve legibility and keep the fixed aspect ratio in that exceptional case.
            XCTAssertGreaterThan(window.minSize.height, screen.height)
            XCTAssertGreaterThanOrEqual(window.maxSize.width, window.minSize.width)
            XCTAssertGreaterThanOrEqual(window.maxSize.height, window.minSize.height)
            XCTAssertLessThanOrEqual(window.frame.maxY, screen.maxY + 0.01, "Title bar must remain reachable")
            try assertControlsFit(controller, context: "extremely small screen fallback")
        }
    }

    func testDurationValueUsesTheSameTextSizeAsItsLabel() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            controller.render(mainStates[1])
            let root = try XCTUnwrap(controller.window?.contentView)
            let labels = descendants(root).compactMap { $0 as? NSTextField }
            let duration = try XCTUnwrap(labels.first { $0.identifier?.rawValue == "duration" })
            let time = try XCTUnwrap(labels.first { $0.identifier?.rawValue == "time" })
            XCTAssertEqual(time.font?.pointSize, 15)
            XCTAssertEqual(time.font?.pointSize, duration.font?.pointSize)
        }
    }

    func testMacCheckboxRemainsCheckedAndShowsItsLockInEveryMainState() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let lock = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "mac-lock" })
            let checkbox = try button("Keep Mac awake", in: controller)
            for state in mainStates {
                controller.render(state)
                resize(controller, screen: screenFrames[0], fraction: 0)
                XCTAssertEqual(checkbox.state, .on)
                XCTAssertFalse(checkbox.isEnabled)
                XCTAssertFalse(lock.isHiddenOrHasHiddenAncestor)
                let checkboxRect = checkbox.convert(checkbox.bounds, to: root)
                let lockRect = lock.convert(lock.bounds, to: root)
                XCTAssertGreaterThan(lockRect.width, 0)
                XCTAssertGreaterThan(lockRect.height, 0)
                XCTAssertGreaterThanOrEqual(lockRect.minX, checkboxRect.maxX)
                XCTAssertLessThanOrEqual(lockRect.minX - checkboxRect.maxX, 24)
                XCTAssertEqual(lockRect.midY, checkboxRect.midY, accuracy: 1)
            }
        }
    }

    func testDurationAndRecentButtonsUsePaddedHourMinuteValues() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let time = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == "time"
            })
            let examples = [(15, "15m"), (60, "01h 00m"), (75, "01h 15m"), (360, "06h 00m")]
            for (minutes, expected) in examples {
                var state = WindowState()
                state.duration = minutes; state.recent = [minutes]
                controller.render(state)
                resize(controller, screen: screenFrames[0], fraction: 0)
                XCTAssertEqual(time.stringValue, expected)
                _ = try button(expected, in: controller)
                state.active = true; state.remaining = Double(minutes * 60) - 1
                controller.render(state)
                XCTAssertEqual(time.stringValue, expected, "Countdown should round remaining seconds up to a minute")
                try assertControlsFit(controller, context: "duration notation \(expected)")
            }
            var lastMinutes = WindowState()
            lastMinutes.active = true; lastMinutes.remaining = 179
            controller.render(lastMinutes)
            XCTAssertEqual(time.stringValue, "03m")
            lastMinutes.remaining = 3779
            controller.render(lastMinutes)
            XCTAssertEqual(time.stringValue, "01h 03m")
        }
    }

    func testHeaderCatBottomAlignsWithVisibleWordmarkInk() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let brand = try XCTUnwrap(descendants(root).compactMap { $0 as? BrandWordmark }.first)
            let cat = try XCTUnwrap(descendants(root).compactMap { $0 as? NSImageView }.first {
                $0.identifier?.rawValue == "cat"
            })
            for screen in screenFrames {
                for sizeChoice in [0.0, 0.5, 1.0] {
                    resize(controller, screen: screen, fraction: sizeChoice)
                    let ink = brand.convert(brand.inkBounds, to: root)
                    let catRect = cat.convert(cat.bounds, to: root)
                    XCTAssertTrue(brand.bounds.insetBy(dx: -0.5, dy: -0.5).contains(brand.inkBounds))
                    XCTAssertTrue(root.bounds.contains(ink))
                    XCTAssertTrue(root.bounds.contains(catRect))
                    XCTAssertEqual(ink.maxY, catRect.maxY, accuracy: 0.5)
                    XCTAssertGreaterThan(catRect.minX, ink.maxX)
                    let image = try XCTUnwrap(cat.image)
                    XCTAssertEqual(cat.bounds.width / cat.bounds.height,
                                   image.size.width / image.size.height, accuracy: 0.001,
                                   "Cropped image must fill its frame for ink alignment")
                }
            }
        }
    }

    func testNavigationButtonSharesHeaderBottomAndCentersBothTitles() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let brand = try XCTUnwrap(descendants(root).compactMap { $0 as? BrandWordmark }.first)
            let cat = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "cat" })
            let navigation = try XCTUnwrap(descendants(root).compactMap { $0 as? FlatButton }.first {
                $0.identifier?.rawValue == "navigation"
            })
            var headerFrames: [String: NSRect] = [:]
            for showSettings in [false, true] {
                controller.showSettings(showSettings)
                XCTAssertEqual(navigation.title, showSettings ? "Back" : "Settings")
                for screen in screenFrames {
                    for fraction in [0.0, 0.5, 1.0] {
                        resize(controller, screen: screen, fraction: fraction)
                        let key = "\(screen.size)-\(fraction)"
                        if let previous = headerFrames[key] { XCTAssertEqual(navigation.frame, previous, "Back must not move the navigation button") }
                        headerFrames[key] = navigation.frame
                        let bottom = brand.convert(brand.inkBounds, to: root).maxY
                        XCTAssertEqual(navigation.convert(navigation.bounds, to: root).maxY, bottom, accuracy: 0.01)
                        XCTAssertEqual(navigation.visibleTitleBounds.midY, navigation.bounds.midY, accuracy: 0.01)
                        XCTAssertEqual(navigation.visibleTitleBounds.midX, navigation.bounds.midX, accuracy: 0.01)
                        XCTAssertEqual(cat.convert(cat.bounds, to: root).maxY, bottom, accuracy: 0.01)
                        XCTAssertTrue(navigation.bounds.contains(navigation.visibleTitleBounds))
                        try assertControlsFit(controller, context: "header alignment")
                    }
                }
            }
        }
    }

    func testDarkPaletteAndCenteredTitlesAcrossScreensAndWarningPanels() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            XCTAssertEqual(window.appearance?.name, .darkAqua)
            XCTAssertEqual(window.backgroundColor.usingColorSpace(.sRGB), AppPalette.background)
            let roots = [try XCTUnwrap(window.contentView), try XCTUnwrap(controller.makeWarningPanel("Test warning").contentView)]
            for root in roots {
                for label in descendants(root).compactMap({ $0 as? NSTextField }) {
                    XCTAssertEqual(label.textColor?.usingColorSpace(.sRGB), AppPalette.foreground)
                }
            }
            for settings in [false, true] {
                controller.showSettings(settings)
                for state in mainStates + settingsStates {
                    controller.render(state)
                    resize(controller, screen: screenFrames[0], fraction: 0)
                    for button in descendants(window.contentView!).compactMap({ $0 as? FlatButton }) where !button.isHiddenOrHasHiddenAncestor {
                        XCTAssertEqual(button.visibleTitleBounds.midX, button.bounds.midX, accuracy: 0.01, button.title)
                        XCTAssertEqual(button.visibleTitleBounds.midY, button.bounds.midY, accuracy: 0.01, button.title)
                        XCTAssertTrue(button.bounds.contains(button.visibleTitleBounds), button.title)
                    }
                }
            }
        }
    }

    func testLockHintFitsAboveIconAndDismissesWhenLeavingMainScreen() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let lock = try XCTUnwrap(descendants(root).compactMap { $0 as? LockHintView }.first)
            let hint = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "lock-hint" })
            XCTAssertEqual(lock.accessibilityHelp(), LockHintView.hintText)
            XCTAssertNil(lock.toolTip, "Custom hover bubble must not duplicate a native tooltip")
            XCTAssertTrue(hint.isHidden)
            for screen in screenFrames {
                for fraction in [0.0, 0.5, 1.0] {
                    resize(controller, screen: screen, fraction: fraction)
                    controller.setLockHintVisible(true)
                    root.layoutSubtreeIfNeeded()
                    XCTAssertFalse(hint.isHidden)
                    XCTAssertTrue(root.bounds.contains(hint.frame))
                    XCTAssertLessThan(hint.frame.maxY, lock.convert(lock.bounds, to: root).minY)
                    XCTAssertGreaterThanOrEqual(lock.bounds.width, 27)
                    let label = try XCTUnwrap(descendants(hint).compactMap { $0 as? NSTextField }.first)
                    XCTAssertEqual(label.stringValue, LockHintView.hintText)
                    XCTAssertGreaterThanOrEqual(label.bounds.width, label.intrinsicContentSize.width)
                    controller.setLockHintVisible(false)
                    XCTAssertTrue(hint.isHidden)
                }
            }
            controller.setLockHintVisible(true)
            controller.showSettings(true)
            XCTAssertTrue(hint.isHidden)
            controller.setLockHintVisible(true)
            XCTAssertTrue(hint.isHidden)
            controller.showSettings(false)
            controller.setLockHintVisible(true)
            controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
            XCTAssertTrue(hint.isHidden)
        }
    }

    func testZoomIsHiddenAndManualResizeMaintainsFullWindowProportions() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            resize(controller, screen: screenFrames[0], fraction: 0)
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            XCTAssertTrue(zoom.isHidden)
            XCTAssertFalse(zoom.isEnabled)
            XCTAssertFalse(controller.windowShouldZoom(window, toFrame: screenFrames[0]))
            XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone))
            let current = window.frame.size
            for proposed in [NSSize(width: current.width * 1.1, height: current.height),
                             NSSize(width: current.width, height: current.height * 1.1),
                             NSSize(width: current.width * 2, height: current.height * 2)] {
                let accepted = controller.windowWillResize(window, to: proposed)
                XCTAssertEqual(accepted.width / accepted.height, current.width / current.height, accuracy: 0.001)
                XCTAssertLessThanOrEqual(accepted.width, window.maxSize.width + 0.01)
                XCTAssertLessThanOrEqual(accepted.height, window.maxSize.height + 0.01)
            }
        }
    }

    func testDurationSliderTrackAndThumbStayCenteredBetweenButtons() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let slider = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSlider }.first {
                $0.identifier?.rawValue == "slider"
            })
            let cell = try XCTUnwrap(slider.cell as? SmoothSliderCell)
            let minus = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "minus" })
            let plus = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "plus" })
            XCTAssertEqual(slider.numberOfTickMarks, 24)
            XCTAssertTrue(slider.allowsTickMarkValuesOnly)
            for screen in screenFrames {
                for sizeChoice in [0.0, 0.5, 1.0] {
                    for minutes in stride(from: 15, through: 360, by: 15) {
                        var state = WindowState()
                        state.duration = minutes
                        controller.render(state)
                        resize(controller, screen: screen, fraction: sizeChoice)
                        let track = cell.barRect(flipped: slider.isFlipped)
                        let thumb = cell.knobRect(flipped: slider.isFlipped)
                        let context = "duration \(minutes), screen \(screen.size), size \(sizeChoice)"
                        XCTAssertEqual(track.height, 4, accuracy: 0.01, context)
                        XCTAssertEqual(thumb.width, 18, accuracy: 0.01, context)
                        XCTAssertEqual(thumb.height, 18, accuracy: 0.01, context)
                        XCTAssertTrue(slider.bounds.insetBy(dx: -0.01, dy: -0.01).contains(track), context)
                        XCTAssertTrue(slider.bounds.insetBy(dx: -0.01, dy: -0.01).contains(thumb), context)
                        let rowCenter = minus.convert(minus.bounds, to: root).midY
                        XCTAssertEqual(plus.convert(plus.bounds, to: root).midY, rowCenter, accuracy: 0.01, context)
                        XCTAssertEqual(slider.convert(track, to: root).midY, rowCenter, accuracy: 0.01, context)
                        XCTAssertEqual(slider.convert(thumb, to: root).midY, rowCenter, accuracy: 0.01, context)
                        XCTAssertEqual(slider.doubleValue, Double(minutes), accuracy: 0.01, context)
                    }
                }
            }
        }
    }

    func testBothBatteryWarningPanelLayoutsFit() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let messages = [
                ForecastWarning.estimatedBelowMinimum(projectedPercent: 14).message,
                ForecastWarning.estimatedBelowMinimum(projectedPercent: 0).message
            ]
            for message in messages {
                let panel = controller.makeWarningPanel(message)
                let root = try XCTUnwrap(panel.contentView)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.bounds.height, 260, accuracy: 0.01)
                try assertControlsFit(root, context: "warning: \(message)")
                let buttons = descendants(root).compactMap { $0 as? NSButton }
                XCTAssertEqual(Set(buttons.map(\.title)), Set(["Cancel", "Continue"]))
                for button in buttons {
                    XCTAssertEqual(button.frame.height, 40, accuracy: 0.01)
                }
            }
        }
    }

    func testExtensionLimitIsExplainedDisabledAndFitsAtBothWindowLimits() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let extend = try XCTUnwrap(descendants(root).compactMap { $0 as? FlatButton }.first {
                $0.identifier?.rawValue == "extend"
            })
            var requests = 0
            controller.onExtend = { requests += 1 }
            var state = WindowState()
            state.active = true; state.duration = 180; state.remaining = 14_160
            for screen in screenFrames {
                for fraction in [0.0, 1.0] {
                    state.canExtend = true
                    controller.render(state)
                    resize(controller, screen: screen, fraction: fraction)
                    let originalFrame = extend.frame
                    XCTAssertEqual(extend.title, "+15m")
                    XCTAssertTrue(extend.isEnabled)
                    let enabledBrightness = try titleBrightness(extend)
                    state.canExtend = false
                    controller.render(state)
                    XCTAssertEqual(extend.title, "06h limit")
                    XCTAssertEqual(extend.frame, originalFrame)
                    XCTAssertFalse(extend.isEnabled)
                    XCTAssertEqual(extend.toolTip, "Six-hour session limit reached, including time already elapsed.")
                    XCTAssertEqual(extend.accessibilityHelp(), extend.toolTip)
                    XCTAssertEqual(extend.accessibilityLabel(), "Six-hour session limit reached")
                    let disabledBrightness = try titleBrightness(extend)
                    XCTAssertLessThan(disabledBrightness, enabledBrightness * 0.45)
                    extend.performClick(nil)
                    extend.highlight(true)
                    XCTAssertEqual(try titleBrightness(extend), disabledBrightness, accuracy: 0.02)
                    extend.highlight(false)
                    try assertControlsFit(controller, context: "six-hour extension limit")
                }
            }
            XCTAssertEqual(requests, 0, "A capped session must never request an extension")
        }
    }

    func testActiveSliderShowsRemainingTimeBelowFifteenMinutesAndRestoresIdleTicks() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            let slider = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSlider }.first)
            let cell = try XCTUnwrap(slider.cell as? SmoothSliderCell)
            var state = WindowState()
            state.duration = 180; state.active = true
            for fraction in [0.0, 1.0] {
                resize(controller, screen: screenFrames[0], fraction: fraction)
                for remaining in [21_600.0, 14_160, 899, 59, 1, 0] {
                    state.remaining = remaining
                    controller.render(state)
                    XCTAssertFalse(slider.isEnabled)
                    XCTAssertEqual(slider.minValue, 0)
                    XCTAssertEqual(slider.maxValue, 360)
                    XCTAssertEqual(slider.numberOfTickMarks, 0)
                    XCTAssertFalse(slider.allowsTickMarkValuesOnly)
                    XCTAssertEqual(slider.doubleValue, remaining / 60, accuracy: 0.0001)
                    XCTAssertEqual(slider.accessibilityLabel(), "Remaining time in minutes")
                    let track = cell.barRect(flipped: slider.isFlipped)
                    let thumb = cell.knobRect(flipped: slider.isFlipped)
                    XCTAssertTrue(slider.bounds.contains(thumb), "Remaining-time thumb must not clip at either end")
                    XCTAssertEqual(thumb.midX, track.minX + CGFloat(remaining / 21_600) * track.width, accuracy: 0.01)
                }
            }
            state.active = false
            controller.render(state)
            XCTAssertTrue(slider.isEnabled)
            XCTAssertEqual(slider.minValue, 15)
            XCTAssertEqual(slider.numberOfTickMarks, 24)
            XCTAssertTrue(slider.allowsTickMarkValuesOnly)
            XCTAssertEqual(slider.doubleValue, 180)
            XCTAssertEqual(slider.accessibilityLabel(), "Duration in minutes")
        }
    }

    func testWarningRefreshKeepsButtonsAndUpdatesExtensionWordingWithoutAnAction() throws {
        try onMain {
            let controller = makeWindow()
            defer { controller.close() }
            let panel = controller.makeWarningPanel(ForecastWarning.estimatedBelowMinimum(projectedPercent: 14).message,
                                                    isExtension: true)
            let root = try XCTUnwrap(panel.contentView)
            let message = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == "warning-message"
            })
            let proceed = try XCTUnwrap(descendants(root).compactMap { $0 as? FlatButton }.first {
                $0.identifier?.rawValue == "warning-continue"
            })
            let cancel = try XCTUnwrap(descendants(root).compactMap { $0 as? FlatButton }.first { $0.title == "Cancel" })
            root.layoutSubtreeIfNeeded()
            let panelFrame = panel.frame
            let proceedFrame = proceed.convert(proceed.bounds, to: root)
            let cancelFrame = cancel.convert(cancel.bounds, to: root)
            var accepted = 0
            proceed.onClick = { accepted += 1 }
            let updates = [
                ForecastWarning.estimatedBelowMinimum(projectedPercent: 0).message,
                "Your Mac is now plugged in. Add 15 minutes? The timer still stops if actual charge falls below 15%.",
                "The battery forecast is currently unavailable. Add 15 minutes? The timer still stops if actual charge falls below 15%."
            ]
            for text in updates {
                panel.update(message: text, isExtension: true)
                XCTAssertEqual(message.stringValue, text)
                XCTAssertEqual(panel.frame, panelFrame, "Refreshing a warning must not reopen or resize it")
                XCTAssertEqual(proceed.convert(proceed.bounds, to: root), proceedFrame,
                               "A live forecast update must not move Continue under the pointer")
                XCTAssertEqual(cancel.convert(cancel.bounds, to: root), cancelFrame,
                               "A live forecast update must not move Cancel under the pointer")
                XCTAssertTrue(descendants(root).contains { $0 === proceed })
                XCTAssertTrue(descendants(root).contains { $0 === cancel })
                XCTAssertEqual(proceed.toolTip, "Add 15 minutes; automatic protection below 15% remains active.")
                XCTAssertEqual(cancel.keyEquivalent, "\r", "Return should never accidentally accept an extension")
                try assertControlsFit(root, context: "updated extension warning")
            }
            panel.update(message: updates[0], isExtension: false)
            XCTAssertEqual(proceed.convert(proceed.bounds, to: root), proceedFrame)
            XCTAssertEqual(cancel.convert(cancel.bounds, to: root), cancelFrame)
            XCTAssertEqual(proceed.toolTip, "Start with automatic protection below 15%.")
            XCTAssertEqual(accepted, 0, "A forecast or power update must not accept the warning")
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

    private var screenFrames: [NSRect] {
        [NSRect(x: 0, y: 25, width: 1440, height: 875),
         NSRect(x: -1024, y: 25, width: 1024, height: 700),
         NSRect(x: 0, y: 25, width: 800, height: 600)]
    }

    private func persistedSessionNotices() throws -> [(String, String)] {
        let reasons: [SessionStopReason] = [
            .manual, .expired, .lowBattery, .batteryUnavailable, .clockUnavailable,
            .assertionFailure, .systemSleep, .quit, .unresponsive, .sessionInactive,
            .shutdown, .interrupted, .storageFailure
        ]
        let locales = [
            ("en_US", "America/Toronto"), ("en_GB", "Europe/London"),
            ("de_DE", "Europe/Berlin"), ("fr_FR", "Asia/Kolkata"),
            ("en_NZ", "Pacific/Chatham")
        ]
        let end = Date(timeIntervalSince1970: 1_792_110_600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var notices: [(String, String)] = []
        for reason in reasons {
            var value: [String: Any] = [
                "version": 1, "id": UUID().uuidString,
                "startedAt": end.addingTimeInterval(-900).timeIntervalSince1970,
                "state": "finished", "reason": reason.rawValue
            ]
            if reason == .interrupted {
                let withoutEnd = try decoder.decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: value))
                notices.append(("\(reason.rawValue), unknown end", SessionNotice.message(for: withoutEnd)))
                continue
            }
            value["endedAt"] = end.timeIntervalSince1970
            let withEnd = try decoder.decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: value))
            for (locale, zone) in locales {
                let text = SessionNotice.message(for: withEnd, locale: Locale(identifier: locale),
                                                 timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
                notices.append(("\(reason.rawValue), \(locale), \(zone)", text))
            }
        }
        // A corrupt journal or failed disk write must also fit its actionable explanation.
        for message in ["Previous timer status unavailable. Start a new timer.",
                        "Session status could not be read. Try again.",
                        "Timer stopped; its status could not be saved.",
                        "Could not safely start the timer. Please try again.",
                        "Could not extend the timer. The original timer is still running."] {
            notices.append(("session storage or start failure", message))
        }
        return notices
    }

    private var mainStates: [WindowState] {
        var empty = WindowState()
        empty.battery = "Battery 100% · Plugged in"
        var recent = empty
        recent.duration = 360; recent.recent = [360, 345, 330]
        var active = recent
        active.active = true; active.remaining = 21600
        var stopped = recent
        stopped.notice = "Stopped: battery below 15%. Charge to at least 15% before starting again."
        stopped.battery = "Battery 14% · Plugged in"; stopped.canStart = false
        var missing = recent
        missing.notice = "The battery reading is unavailable. Try again when battery protection can be verified."
        missing.battery = "Battery reading unavailable"; missing.canStart = false
        let completion = Date(timeIntervalSince1970: 1_792_110_600)
        let completed = [
            ("en_US", "America/Toronto"),
            ("en_GB", "Europe/London"),
            ("de_DE", "Europe/Berlin"),
            ("fr_FR", "Asia/Kolkata"),
            ("en_NZ", "Pacific/Chatham")
        ].map { locale, zone in
            var state = recent
            state.notice = SessionNotice.message(for: .expired, finishedAt: completion,
                                                 locale: Locale(identifier: locale),
                                                 timeZone: TimeZone(identifier: zone)!)
            return state
        }
        return [empty, recent, active, stopped, missing] + completed
    }

    private var settingsStates: [WindowState] {
        var regular = WindowState()
        regular.battery = "Battery 64%"
        var approval = regular
        approval.loginEnabled = true; approval.loginNeedsApproval = true
        approval.loginNote = "Allow Cat Run in Login Items to finish enabling this setting."
        var failed = regular
        failed.loginNote = LoginStatusText.note(for: .enabled, failedRequest: false)
        var active = approval
        active.active = true; active.remaining = 3600
        return [regular, approval, failed, active]
    }

    private func makeWindow() -> AppWindow {
        _ = NSApplication.shared
        return AppWindow(persistWindowFrame: false)
    }

    private func resize(_ controller: AppWindow, screen: NSRect, fraction: Double) {
        guard let window = controller.window else { return }
        controller.applyBounds(visibleFrame: screen)
        let minimum = window.minSize, maximum = window.maxSize
        let size = NSSize(width: minimum.width + (maximum.width - minimum.width) * fraction,
                          height: minimum.height + (maximum.height - minimum.height) * fraction)
        window.setFrame(NSRect(origin: screen.origin, size: size), display: false)
        controller.applyBounds(visibleFrame: screen)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func button(_ title: String, in controller: AppWindow) throws -> NSButton {
        let root = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func assertControlsFit(_ controller: AppWindow, context: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try XCTUnwrap(controller.window?.contentView, file: file, line: line)
        try assertControlsFit(root, context: context, file: file, line: line)
    }

    private func assertControlsFit(_ root: NSView, context: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let views = descendants(root)
        XCTAssertFalse(views.contains { $0 is NSScrollView && !$0.isHiddenOrHasHiddenAncestor }, "Unexpected scrolling: \(context)", file: file, line: line)
        let controls = views.compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor }
        for control in controls {
            let name = control.identifier?.rawValue ?? String(describing: type(of: control))
            let rect = control.convert(control.bounds, to: root)
            XCTAssertGreaterThan(rect.width, 0, "Zero width \(name): \(context)", file: file, line: line)
            XCTAssertGreaterThan(rect.height, 0, "Zero height \(name): \(context)", file: file, line: line)
            XCTAssertTrue(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect), "Clipped \(name) \(rect): \(context)", file: file, line: line)
            if let text = control as? NSTextField, !text.stringValue.isEmpty, let cell = text.cell {
                let required = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: text.bounds.width, height: 10_000))
                XCTAssertLessThanOrEqual(required.height, text.bounds.height + 1, "Clipped text: \(text.stringValue): \(context)", file: file, line: line)
            }
            if let button = control as? FlatButton, let font = button.font {
                let textSize = (button.title as NSString).size(withAttributes: [.font: font])
                XCTAssertLessThanOrEqual(textSize.width, button.bounds.width - 4, "Clipped button title: \(button.title): \(context)", file: file, line: line)
                XCTAssertLessThanOrEqual(textSize.height, button.bounds.height - 2, "Clipped button title height: \(button.title): \(context)", file: file, line: line)
            }
        }
        for (index, control) in controls.enumerated() {
            let a = control.convert(control.bounds, to: root).insetBy(dx: 0.5, dy: 0.5)
            for other in controls.dropFirst(index + 1) {
                if control.isDescendant(of: other) || other.isDescendant(of: control) { continue }
                let b = other.convert(other.bounds, to: root).insetBy(dx: 0.5, dy: 0.5)
                XCTAssertFalse(a.intersects(b), "Overlapping controls \(control) / \(other): \(context)", file: file, line: line)
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }
}
