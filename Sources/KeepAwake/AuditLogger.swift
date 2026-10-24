import Foundation
import KeepAwakeCore

protocol AuditLogPersisting: AnyObject {
    func append(_ event: AuditEvent) throws
    func snapshot() -> AuditLogSnapshot
}
extension EncryptedAuditLog: AuditLogPersisting {}

/// Encryption and disk work stay off AppKit and the power-safety queue.
final class AuditLogger {
    private let queue = DispatchQueue(label: "org.catrun.activity-log", qos: .utility)
    private let store: AuditLogPersisting
    private let runID = UUID()
    private let now: () -> Date
    private let automaticallyPrune: Bool
    private var callback: ((AuditLogSnapshot) -> Void)?
    private var maintenance: DispatchSourceTimer?
    private var recordingError: AuditLogError?
    private var started = false
    private var runOpeningRecorded = false
    private var closing = false
    var onMaintenance: (() -> Void)?

    init(store: AuditLogPersisting, now: @escaping () -> Date = Date.init, automaticallyPrune: Bool = true) {
        self.store = store; self.now = now; self.automaticallyPrune = automaticallyPrune
    }

    func start(previousOutcome: SessionRecord?, onChange: @escaping (AuditLogSnapshot) -> Void) {
        queue.async {
            self.callback = onChange
            let snapshot = self.store.snapshot()
            self.recordingError = snapshot.error
            if snapshot.error == nil {
                if let opened = snapshot.events.first(where: { $0.kind == .applicationOpened }),
                   !snapshot.events.contains(where: {
                       ($0.kind == .applicationClosed || $0.kind == .applicationInterrupted) && $0.sessionID == opened.sessionID
                   }) {
                    self.append(AuditEvent(date: self.now(), message: "Previous app exit was not recorded. Cause and exit time unknown.",
                                           sessionID: opened.sessionID, kind: .applicationInterrupted))
                }
                if let record = previousOutcome, record.state == .finished,
                   !snapshot.events.contains(where: { $0.kind == .timerStopped && $0.sessionID == record.id }) {
                    let reason = record.reason.flatMap(SessionStopReason.init(rawValue:))
                    let text: String
                    if reason == .interrupted {
                        text = "Previous timer interrupted. Detected on reopening; cause and stop time unknown."
                    } else if record.endedAt == nil {
                        text = "Previous timer: \(reason?.shortLabel ?? "reason unavailable"). Detected later; stop time unknown."
                    } else {
                        text = "Previous timer: \(reason?.shortLabel ?? "reason unavailable")."
                    }
                    self.append(AuditEvent(date: record.endedAt ?? record.detectedAt ?? self.now(), message: text,
                                           sessionID: record.id, kind: .timerStopped))
                }
                self.append(AuditEvent(date: self.now(), message: "Cat Run opened.", sessionID: self.runID, kind: .applicationOpened))
            }
            self.started = true
            self.publish()
            if self.automaticallyPrune {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 3_600, repeating: 3_600, leeway: .seconds(60))
                timer.setEventHandler { [weak self] in self?.onMaintenance?(); self?.publish() }
                self.maintenance = timer; timer.resume()
            }
        }
    }

    func record(_ message: String, kind: AuditEventKind = .activity, sessionID: UUID? = nil, at date: Date? = nil) {
        let event = AuditEvent(date: date ?? now(), message: message, sessionID: sessionID, kind: kind)
        queue.async { self.append(event); self.publish() }
    }

    func recordStop(_ event: SessionSafetyGuard.StopEvent) {
        let message = event.timeIsDetection
            ? "Timer stopped · \(event.reason.shortLabel). Detected after sleep; stop time unknown."
            : event.reason.auditDescription
        record(message, kind: .timerStopped, sessionID: event.token, at: event.date)
    }

    func refresh() { queue.async { self.publish() } }

    /// Copy waits behind earlier log writes and reapplies retention/verification.
    /// It never blocks AppKit or the timer-safety queue on disk or Keychain work.
    func snapshotForCopy(_ completion: @escaping (AuditLogSnapshot) -> Void) {
        queue.async {
            let snapshot = self.currentSnapshot()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// Called only after power assertions have been released. A slow disk cannot block quit indefinitely.
    @discardableResult
    func finish(timeout: TimeInterval = 1) -> Bool {
        let event = AuditEvent(date: now(), message: "Cat Run quit.", sessionID: runID, kind: .applicationClosed)
        queue.async { self.closing = true; self.append(event); self.publish() }
        return flush(timeout: timeout)
    }

    @discardableResult
    func flush(timeout: TimeInterval = 1) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func append(_ event: AuditEvent) {
        do {
            if recordingError != nil {
                try store.append(AuditEvent(date: now(), message: "Activity logging resumed; some events may be missing."))
            }
            if started && !runOpeningRecorded && event.kind != .applicationOpened {
                try store.append(AuditEvent(date: now(), message: "Cat Run session is active; logging resumed.", sessionID: runID, kind: .applicationOpened))
                runOpeningRecorded = true
            }
            try store.append(event)
            if event.kind == .applicationOpened && event.sessionID == runID { runOpeningRecorded = true }
            recordingError = nil
        } catch {
            recordingError = error as? AuditLogError ?? .storageUnavailable
        }
    }

    private func currentSnapshot() -> AuditLogSnapshot {
        var saved = store.snapshot()
        // Renew a retained run marker after pruning, including idle runs lasting
        // longer than seven days. This is observation time, never a new launch.
        if started && !closing && saved.error == nil,
           !saved.events.contains(where: { $0.kind == .applicationOpened && $0.sessionID == runID }) {
            append(AuditEvent(date: now(), message: runOpeningRecorded
                ? "Cat Run is still open."
                : "Cat Run session is active; logging resumed.", sessionID: runID, kind: .applicationOpened))
            saved = store.snapshot()
        }
        return AuditLogSnapshot(events: saved.events, error: saved.error ?? recordingError)
    }

    private func publish() {
        let snapshot = currentSnapshot()
        if let callback { DispatchQueue.main.async { callback(snapshot) } }
    }

    deinit { maintenance?.setEventHandler {}; maintenance?.cancel() }
}
