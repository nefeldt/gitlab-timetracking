//
//  TrackingCalculationTests.swift
//  GitLab Timetracking Tests
//

import Foundation
import Testing
@testable import GitLab_Timetracking

@MainActor
struct TrackingCalculationTests {

    // MARK: - Helpers

    private func makeIssue() -> GitLabIssue {
        GitLabIssue(
            id: 1,
            iid: 42,
            projectID: 10,
            title: "Test Issue",
            webURL: URL(string: "https://gitlab.example.com/test/project/-/issues/42")!,
            updatedAt: Date(),
            references: GitLabIssue.References(short: "#42"),
            timeStats: GitLabIssue.TimeStats(totalTimeSpent: 0)
        )
    }

    private func makeSession(
        startedAt: Date = Date(timeIntervalSince1970: 0),
        lastCheckpointAt: Date? = nil,
        accumulatedMinutes: Int = 0
    ) -> TrackingManager.Session {
        TrackingManager.Session(
            issue: makeIssue(),
            startedAt: startedAt,
            lastCheckpointAt: lastCheckpointAt ?? startedAt,
            accumulatedMinutes: accumulatedMinutes
        )
    }

    /// The single booking formula used everywhere now that tracking never
    /// pauses: everything since the session started is counted.
    private func plannedMinutes(_ session: TrackingManager.Session, at now: Date) -> Int {
        session.accumulatedMinutes
            + TrackingManager.minutesBetween(from: session.lastCheckpointAt, to: now)
    }

    // MARK: - minutesBetween

    @Test func minutesBetween_35minutes() {
        let from = Date(timeIntervalSince1970: 0)
        let to = from.addingTimeInterval(35 * 60)
        #expect(TrackingManager.minutesBetween(from: from, to: to) == 35)
    }

    @Test func minutesBetween_minimumIsOne() {
        let from = Date(timeIntervalSince1970: 0)
        let to = from.addingTimeInterval(10) // 10 seconds
        #expect(TrackingManager.minutesBetween(from: from, to: to) == 1)
    }

    @Test func minutesBetween_exactlyOneMinute() {
        let from = Date(timeIntervalSince1970: 0)
        let to = from.addingTimeInterval(60)
        #expect(TrackingManager.minutesBetween(from: from, to: to) == 1)
    }

    @Test func minutesBetween_truncatesPartialMinutes() {
        let from = Date(timeIntervalSince1970: 0)
        let to = from.addingTimeInterval(20 * 60 + 45) // 20 min 45 sec
        #expect(TrackingManager.minutesBetween(from: from, to: to) == 20)
    }

    // MARK: - applyCheckpoint (now non-blocking)

    @Test func applyCheckpoint_accumulatesAndAdvancesCheckpoint() {
        let start = Date(timeIntervalSince1970: 0)
        let checkpointTime = start.addingTimeInterval(20 * 60)

        let session = makeSession(startedAt: start)
        let updated = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpointTime)

        #expect(updated.accumulatedMinutes == 20)
        #expect(updated.lastCheckpointAt == checkpointTime)
        #expect(updated.startedAt == start) // unchanged
    }

    @Test func applyCheckpoint_accumulatesOnTopOfExisting() {
        let start = Date(timeIntervalSince1970: 0)
        let session = makeSession(startedAt: start, accumulatedMinutes: 40)
        let checkpointTime = start.addingTimeInterval(60 * 60)

        let updated = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpointTime)
        #expect(updated.accumulatedMinutes == 60)
    }

    // MARK: - Single stop path

    @Test func stopBeforeCheckpoint_booksElapsedTime() {
        let start = Date(timeIntervalSince1970: 0)
        let stopTime = start.addingTimeInterval(15 * 60)

        let session = makeSession(startedAt: start)
        #expect(plannedMinutes(session, at: stopTime) == 15)
    }

    @Test func stopAfterCheckpoint_booksFullElapsedTime() {
        // Checkpoint fired at T=20, user keeps working, stops at T=35.
        // Tracking never paused, so all 35 minutes are booked.
        let start = Date(timeIntervalSince1970: 0)
        let checkpointTime = start.addingTimeInterval(20 * 60)
        let stopTime = start.addingTimeInterval(35 * 60)

        var session = makeSession(startedAt: start)
        session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpointTime)

        #expect(session.accumulatedMinutes == 20)
        #expect(plannedMinutes(session, at: stopTime) == 35)
    }

    // MARK: - The data-loss bug is fixed: missing a check-in never loses time

    @Test func missingCheckInDoesNotLoseTime() {
        // Checkpoint fires at T=20. The user does not react for 10 minutes but
        // keeps working, then stops at T=40. The old "Continue" flow discarded
        // the T=20..T=30 gap; the new flow counts every minute.
        let start = Date(timeIntervalSince1970: 0)
        let checkpointTime = start.addingTimeInterval(20 * 60)
        let stopTime = start.addingTimeInterval(40 * 60)

        var session = makeSession(startedAt: start)
        session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpointTime)

        // 20 accumulated + 20 partial (T=20..T=40) = 40, nothing lost.
        #expect(plannedMinutes(session, at: stopTime) == 40)
    }

    // MARK: - Multiple checkpoints

    @Test func multipleCheckpoints_thenStop() {
        let start = Date(timeIntervalSince1970: 0)
        let checkpoint1 = start.addingTimeInterval(20 * 60)
        let checkpoint2 = start.addingTimeInterval(40 * 60)
        let stopTime = start.addingTimeInterval(50 * 60)

        var session = makeSession(startedAt: start)
        session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpoint1)
        session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpoint2)

        #expect(session.accumulatedMinutes == 40)
        // 40 accumulated + 10 partial (T=40..T=50) = 50
        #expect(plannedMinutes(session, at: stopTime) == 50)
    }

    // MARK: - Restore from persistence

    @Test func restore_checkpointDueDuringDowntime_foldsOneInterval() {
        // App persisted with lastCheckpointAt = T=0, restarts at T=35,
        // checkpoint interval = 20 min. Restore folds exactly one interval.
        let start = Date(timeIntervalSince1970: 0)
        let checkpointInterval: TimeInterval = 20 * 60

        var session = makeSession(startedAt: start, lastCheckpointAt: start)
        let checkpointFiredAt = session.lastCheckpointAt.addingTimeInterval(checkpointInterval)
        session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpointFiredAt)

        #expect(session.accumulatedMinutes == 20)
        #expect(session.lastCheckpointAt == start.addingTimeInterval(20 * 60))

        // Stopping at T=35 books 20 + 15 = 35.
        let returnTime = start.addingTimeInterval(35 * 60)
        #expect(plannedMinutes(session, at: returnTime) == 35)
    }

    @Test func restore_multipleMissedCheckpoints_onlyFoldsOneInterval() {
        // checkpoint=20, app down for 90 min → restore folds one 20-min
        // interval; the remaining 70 min remains the in-progress partial.
        // (Precise downtime classification is handled by away detection.)
        let start = Date(timeIntervalSince1970: 0)
        let checkpointInterval: TimeInterval = 20 * 60
        let restoreTime = start.addingTimeInterval(90 * 60)

        var session = makeSession(startedAt: start, lastCheckpointAt: start)
        let checkpointFiredAt = session.lastCheckpointAt.addingTimeInterval(checkpointInterval)
        session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpointFiredAt)

        #expect(session.accumulatedMinutes == 20)
        #expect(plannedMinutes(session, at: restoreTime) == 90)
    }

    // MARK: - Edge cases

    @Test func immediateStop_booksMinimumOneMinute() {
        let start = Date(timeIntervalSince1970: 0)
        let stopTime = start.addingTimeInterval(5) // 5 seconds
        let session = makeSession(startedAt: start)
        #expect(plannedMinutes(session, at: stopTime) == 1)
    }

    @Test func immediateStop_zeroSeconds_stillBooksOne() {
        let start = Date(timeIntervalSince1970: 0)
        let session = makeSession(startedAt: start)
        #expect(plannedMinutes(session, at: start) == 1)
    }

    @Test func minutesBetween_clockBackwards_clampsToOne() {
        // System clock adjusted backwards during tracking
        let from = Date(timeIntervalSince1970: 1000)
        let to = Date(timeIntervalSince1970: 500)
        #expect(TrackingManager.minutesBetween(from: from, to: to) == 1)
    }

    @Test func stopImmediatelyAfterCheckpoint_addsMinimumOneMinute() {
        // Checkpoint fires, user immediately stops a few seconds later.
        let start = Date(timeIntervalSince1970: 0)
        let checkpointTime = start.addingTimeInterval(20 * 60)
        let immediateStop = checkpointTime.addingTimeInterval(3)

        var session = makeSession(startedAt: start)
        session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: checkpointTime)

        // 20 + 1 (minimum partial) = 21
        #expect(plannedMinutes(session, at: immediateStop) == 21)
    }

    @Test func longSession_manyCheckpoints_thenStop() {
        // 8-hour session with 20-min checkpoints = 24 checkpoints
        let start = Date(timeIntervalSince1970: 0)
        var session = makeSession(startedAt: start)

        for i in 1...24 {
            let cpTime = start.addingTimeInterval(TimeInterval(i * 20) * 60)
            session = TrackingManager.applyCheckpoint(to: session, checkpointMinutes: 20, at: cpTime)
        }

        #expect(session.accumulatedMinutes == 480) // 24 * 20 = 480 min = 8h

        // Stop 10 minutes into the 25th interval
        let stopTime = start.addingTimeInterval((480 + 10) * 60)
        #expect(plannedMinutes(session, at: stopTime) == 490)
    }
}
