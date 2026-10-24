import Foundation
import KeepAwakeCore

/// Routes real start/extension requests through both fresh battery readers.
/// The interface supplies effects only after this flow has reconciled safety.
final class SessionRequestFlow {
    struct Request {
        let durationMinutes: Int
        let isExtension: Bool
        var confirmed = false
    }
    struct Warning {
        let id = UUID()
        let sessionID: UUID?
        let request: Request
    }
    struct Evaluation {
        let reading: BatteryReading?
        let preparation: SessionPreparation?
    }

    private let safety: SessionSafetyGuard
    private let readBattery: () -> BatteryReading
    private let now: () -> TimeInterval
    private(set) var warning: Warning?

    init(safety: SessionSafetyGuard, readBattery: @escaping () -> BatteryReading,
         now: @escaping () -> TimeInterval) {
        self.safety = safety; self.readBattery = readBattery; self.now = now
    }

    func prepare(_ request: Request, model: SessionModel, sessionID: UUID?) -> Evaluation {
        guard warning == nil, request.isExtension == model.active else {
            return Evaluation(reading: nil, preparation: nil)
        }
        safety.checkNow()
        let state = safety.stateSnapshot()
        guard state.terminalEvents.isEmpty, state.token == sessionID else {
            return Evaluation(reading: nil, preparation: nil)
        }
        let reading = readBattery()
        safety.observeBattery(reading, token: sessionID)
        let refreshed = safety.stateSnapshot()
        guard refreshed.terminalEvents.isEmpty, refreshed.token == sessionID else {
            return Evaluation(reading: reading, preparation: nil)
        }
        let result = request.isExtension
            ? model.prepareExtension(battery: reading, now: now(), confirmRisk: request.confirmed)
            : model.prepareStart(durationMinutes: request.durationMinutes, battery: reading,
                                 now: now(), confirmRisk: request.confirmed)
        return Evaluation(reading: reading, preparation: result)
    }

    func beginWarning(for request: Request, sessionID: UUID?) -> Warning {
        let pending = Warning(sessionID: sessionID, request: request)
        warning = pending
        return pending
    }

    /// A completion is usable once, and only for its original session.
    func resolveWarning(id: UUID, accepted: Bool, sessionID: UUID?) -> Request? {
        guard let pending = warning, pending.id == id else { return nil }
        warning = nil
        guard accepted, pending.sessionID == sessionID else { return nil }
        var request = pending.request
        request.confirmed = true
        return request
    }

    func cancelWarning() { warning = nil }

    func warningMessage(model: SessionModel, reading: BatteryReading) -> String? {
        guard let pending = warning else { return nil }
        let seconds = pending.request.isExtension
            ? model.remaining(at: now()) + 900 : TimeInterval(pending.request.durationMinutes * 60)
        let action = pending.request.isExtension ? "add 15m" : "start the timer"
        if case .estimatedBelowMinimum(let percent)? = SessionModel.forecastWarning(battery: reading, seconds: seconds) {
            let subject = pending.request.isExtension ? "Adding 15m" : "This timer"
            return "\(subject) may leave approximately \(Int(floor(percent)))% battery. The timer stops below 15%, even while plugged in."
        }
        if reading.onAC || !reading.hasBattery {
            return "Connected to power. Continue to \(action). The timer still stops if battery charge falls below 15%."
        }
        if reading.validMinutesToEmpty == nil {
            return "Battery estimate unavailable. Continue to \(action) with automatic protection below 15%."
        }
        return "The latest estimate no longer falls below 15%. Continue to \(action). Automatic battery protection remains on."
    }
}
