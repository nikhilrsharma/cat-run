import Foundation
import XCTest
@testable import KeepAwake

/// Pure election tests: never launch, activate, or terminate an application.
final class SingleInstanceTests: XCTestCase {
    private typealias Candidate = SingleInstance.Candidate

    func testRunningAppWinsOverNewLaunchEvenAfterPIDRollover() {
        let running = candidate(pid: 500, finished: true, time: 100)
        let starting = candidate(pid: 100, finished: false, time: 200)

        XCTAssertEqual(winner([starting, running]), 500)
        XCTAssertEqual(winner([running, starting]), 500)
    }

    func testConcurrentStartupsChooseTheSameWinnerRegardlessOfSnapshotOrder() {
        let first = candidate(pid: 100, finished: false, time: nil)
        let second = candidate(pid: 200, finished: false, time: 100)

        // Launch dates may not yet be populated, so incomplete launches use PID order.
        XCTAssertEqual(winner([first, second]), 100)
        XCTAssertEqual(winner([second, first]), 100)
    }

    func testExistingDuplicatesChooseTheOldestKnownLaunch() {
        let oldest = candidate(pid: 500, finished: true, time: 100)
        let newer = candidate(pid: 75, finished: true, time: 200)
        let unknownDate = candidate(pid: 50, finished: true, time: nil)

        for ordering in permutations([oldest, newer, unknownDate]) {
            XCTAssertEqual(winner(ordering), 500)
        }
    }

    func testMissingOrEqualLaunchDatesUseStablePIDTieBreak() {
        XCTAssertEqual(winner([
            candidate(pid: 200, finished: true, time: nil),
            candidate(pid: 100, finished: true, time: nil)
        ]), 100)
        XCTAssertEqual(winner([
            candidate(pid: 200, finished: true, time: 100),
            candidate(pid: 100, finished: true, time: 100)
        ]), 100)
    }

    func testEmptyAndSingleInstanceSnapshots() {
        XCTAssertNil(winner([]))
        XCTAssertEqual(winner([candidate(pid: 100, finished: false, time: nil)]), 100)
    }

    private func candidate(pid: Int32, finished: Bool, time: TimeInterval?) -> Candidate {
        Candidate(processIdentifier: pid, finishedLaunching: finished,
                  launchDate: time.map(Date.init(timeIntervalSince1970:)))
    }

    private func winner(_ candidates: [Candidate]) -> Int32? {
        SingleInstance.preferredProcessIdentifier(in: candidates)
    }

    private func permutations(_ candidates: [Candidate]) -> [[Candidate]] {
        guard !candidates.isEmpty else { return [[]] }
        return candidates.indices.flatMap { index in
            var remaining = candidates
            let first = remaining.remove(at: index)
            return permutations(remaining).map { [first] + $0 }
        }
    }
}
