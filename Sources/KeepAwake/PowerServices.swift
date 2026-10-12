import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import KeepAwakeCore

/// Reads only the Mac's internal battery. All calls and callbacks use the main thread.
final class BatteryMonitor {
    var onChange: ((BatteryReading) -> Void)?

    private enum HardwareKind { case unknown, portable, desktop }
    private var hardwareKind: HardwareKind = .unknown
    private var hasSeenInternalBattery = false
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var started = false

    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true

        // The context is unretained: stop/deinit invalidate the source before self disappears.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.publishReading()
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.publishReading()
        }
        publishReading()
    }

    func stop() {
        precondition(Thread.isMainThread)
        removeObservers()
    }

    /// A synchronous fresh snapshot; the caller decides how to apply it.
    @discardableResult
    func refresh() -> BatteryReading {
        precondition(Thread.isMainThread)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return unknownReading()
        }

        let providingPower = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let reportedAC = providingPower == kIOPSACPowerValue
        var internalSources: [[String: Any]] = []
        var hadUnreadableDescription = false
        for source in sourceList {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any] else {
                hadUnreadableDescription = true
                continue
            }
            // Accessories and UPS devices must not become the Mac's battery reading.
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                internalSources.append(description)
            }
        }

        if !internalSources.isEmpty {
            hasSeenInternalBattery = true
            hardwareKind = .portable
            // Present=false describes a missing battery slot, not a zero-percent battery.
            guard let battery = internalSources.first(where: {
                ($0[kIOPSIsPresentKey] as? NSNumber)?.boolValue != false
            }) else { return unknownReading(onAC: reportedAC) }

            let sourceState = battery[kIOPSPowerSourceStateKey] as? String
            let onAC = sourceState == kIOPSACPowerValue
                || (sourceState == nil && reportedAC)
            let current = (battery[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (battery[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent: Double?
            if let current, let maximum, current.isFinite, maximum.isFinite,
               current >= 0, maximum > 0, current <= maximum {
                percent = current / maximum * 100
            } else {
                percent = nil
            }

            // This per-source value excludes any UPS runtime. -1 means still calculating.
            let reportedMinutes = (battery[kIOPSTimeToEmptyKey] as? NSNumber)?.doubleValue
            let charging = (battery[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
            let minutesToEmpty: Double?
            if sourceState == kIOPSBatteryPowerValue, !charging,
               let reportedMinutes, reportedMinutes.isFinite, reportedMinutes > 0 {
                minutesToEmpty = reportedMinutes
            } else {
                minutesToEmpty = nil
            }
            return BatteryReading(hasBattery: true, percent: percent, onAC: onAC,
                                  minutesToEmpty: minutesToEmpty)
        }

        // IOPS can temporarily lose a battery during startup or wake. Once observed,
        // its absence must never silently disable the battery safety policy.
        if hasSeenInternalBattery || hadUnreadableDescription {
            return unknownReading(onAC: reportedAC)
        }
        if hardwareKind == .unknown {
            hardwareKind = readHardwareKind()
        }
        if hardwareKind == .desktop {
            return BatteryReading(hasBattery: false, percent: nil, onAC: true,
                                  minutesToEmpty: nil)
        }
        return unknownReading(onAC: reportedAC)
    }

    private func unknownReading(onAC: Bool = false) -> BatteryReading {
        BatteryReading(hasBattery: true, percent: nil, onAC: onAC, minutesToEmpty: nil)
    }

    private func publishReading() {
        precondition(Thread.isMainThread)
        guard started else { return }
        onChange?(refresh())
    }

    private func readHardwareKind() -> HardwareKind {
        // The public IOPM.h contract says an absent clamshell-state property means
        // this hardware has no clamshell. A failed registry read remains unknown.
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return .unknown }
        defer { IOObjectRelease(root) }
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(root, &unmanagedProperties, kCFAllocatorDefault, 0)
                == kIOReturnSuccess,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any]
        else { return .unknown }
        return properties[kAppleClamshellStateKey] == nil ? .desktop : .portable
    }

    private func removeObservers() {
        started = false
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
            self.runLoopSource = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    deinit { removeObservers() }
}

enum PowerServiceError: LocalizedError {
    case invalidDuration
    case noActiveSession
    case assertionFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "Choose a valid duration before starting."
        case .noActiveSession:
            return "Start a session before extending it."
        case .assertionFailed(let code):
            return "macOS could not keep this Mac awake (error \(String(format: "0x%08X", UInt32(bitPattern: code)))). Please try again."
        }
    }
}

/// Uses separate idle-system and idle-display assertions with OS-enforced expiry.
final class PowerAssertionManager {
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private var keepsScreenAwake = false

    func acquire(keepScreenAwake: Bool, timeout: TimeInterval) throws {
        precondition(Thread.isMainThread)
        guard timeout.isFinite, timeout > 0 else { throw PowerServiceError.invalidDuration }

        var newSystem: IOPMAssertionID?
        var newDisplay: IOPMAssertionID?
        do {
            newSystem = try createAssertion(type: kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                           name: "Cat Run — keep Mac awake", timeout: timeout)
            if keepScreenAwake {
                newDisplay = try createAssertion(type: kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                name: "Cat Run — keep screen on", timeout: timeout)
            }
        } catch {
            releaseAssertion(newDisplay)
            releaseAssertion(newSystem)
            throw error
        }

        // Commit only after both requests succeed; a failed replacement preserves
        // the previous requests and their original timeout.
        release()
        systemAssertion = newSystem
        displayAssertion = newDisplay
        keepsScreenAwake = keepScreenAwake
    }

    func updateTimeout(seconds: TimeInterval) throws {
        precondition(Thread.isMainThread)
        guard systemAssertion != nil else { throw PowerServiceError.noActiveSession }
        // Replacing the pair atomically avoids partially extending one assertion.
        try acquire(keepScreenAwake: keepsScreenAwake, timeout: seconds)
    }

    func release() {
        precondition(Thread.isMainThread)
        releaseAssertion(displayAssertion)
        releaseAssertion(systemAssertion)
        displayAssertion = nil
        systemAssertion = nil
        keepsScreenAwake = false
    }

    private func createAssertion(type: CFString, name: String,
                                 timeout: TimeInterval) throws -> IOPMAssertionID {
        var identifier = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithDescription(
            type, name as CFString,
            "A timed session explicitly started by the user." as CFString,
            nil, nil, timeout, kIOPMAssertionTimeoutActionRelease as CFString, &identifier
        )
        guard result == kIOReturnSuccess else {
            if identifier != kIOPMNullAssertionID { _ = IOPMAssertionRelease(identifier) }
            throw PowerServiceError.assertionFailed(result)
        }
        return identifier
    }

    private func releaseAssertion(_ identifier: IOPMAssertionID?) {
        guard let identifier else { return }
        // An OS timeout may already have released it; that is a harmless no-op.
        _ = IOPMAssertionRelease(identifier)
    }

    deinit {
        releaseAssertion(displayAssertion)
        releaseAssertion(systemAssertion)
    }
}
