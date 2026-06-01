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

    // MARK: - Away detection (begin/end)

    @Test func away_freezesTimeAndExcludesGapUntilCounted() {
        // Work 20 min, away from T=20 to T=80 (1h lock), then work to T=90.
        let start = Date(timeIntervalSince1970: 0)
        let awayStart = start.addingTimeInterval(20 * 60)
        let returnTime = start.addingTimeInterval(80 * 60)
        let stopTime = start.addingTimeInterval(90 * 60)

        var session = makeSession(startedAt: start)
        session = TrackingManager.beginAway(session, at: awayStart)

        // The 20 minutes worked before leaving are confirmed; the clock is frozen.
        #expect(session.accumulatedMinutes == 20)
        #expect(TrackingManager.openIntervalMinutes(session, at: returnTime) == 0)

        session = TrackingManager.endAway(session, at: returnTime)
        #expect(session.awayGaps.count == 1)
        #expect(session.awayGaps[0].resolution == .undecided)
        #expect(session.awayGaps[0].minutes == 60)

        // Undecided gap is excluded: 20 confirmed + 10 worked after return = 30.
        #expect(TrackingManager.bookableMinutes(session, at: stopTime) == 30)

        // After counting the gap, the hour is included: 30 + 60 = 90.
        session.awayGaps[0].resolution = .counted
        #expect(TrackingManager.bookableMinutes(session, at: stopTime) == 90)
    }

    @Test func away_briefBlipCountsAsContinuousWork() {
        // A 30-second lock (below the ignore threshold) is treated as work and
        // produces no gap to reconcile.
        let start = Date(timeIntervalSince1970: 0)
        let awayStart = start.addingTimeInterval(20 * 60)
        let returnTime = awayStart.addingTimeInterval(30)
        let stopTime = start.addingTimeInterval(40 * 60)

        var session = makeSession(startedAt: start)
        session = TrackingManager.beginAway(session, at: awayStart)
        session = TrackingManager.endAway(session, at: returnTime)

        #expect(session.awayGaps.isEmpty)
        // 20 worked + 20 after the blip = 40, nothing excluded.
        #expect(TrackingManager.bookableMinutes(session, at: stopTime) == 40)
    }

    @Test func away_multipleGapsResolveIndependently() {
        let start = Date(timeIntervalSince1970: 0)
        var session = makeSession(startedAt: start)

        // Gap A: T=10..T=40 (30 min)
        session = TrackingManager.beginAway(session, at: start.addingTimeInterval(10 * 60))
        session = TrackingManager.endAway(session, at: start.addingTimeInterval(40 * 60))
        // Gap B: T=50..T=110 (60 min)
        session = TrackingManager.beginAway(session, at: start.addingTimeInterval(50 * 60))
        session = TrackingManager.endAway(session, at: start.addingTimeInterval(110 * 60))

        #expect(session.awayGaps.count == 2)

        // Count only the first gap.
        session.awayGaps[0].resolution = .counted
        session.awayGaps[1].resolution = .discarded
        #expect(TrackingManager.countedGapMinutes(session) == 30)
    }

    @Test func away_doubleBeginIsIgnored() {
        let start = Date(timeIntervalSince1970: 0)
        var session = makeSession(startedAt: start)
        session = TrackingManager.beginAway(session, at: start.addingTimeInterval(10 * 60))
        let firstAwaySince = session.awaySince
        // A second away event before returning must not move the boundary.
        session = TrackingManager.beginAway(session, at: start.addingTimeInterval(15 * 60))
        #expect(session.awaySince == firstAwaySince)
    }

    // MARK: - Restore from persistence (downtime treated as an away gap)

    @Test func restore_downtimeBecomesUndecidedGap() {
        // App persisted at T=0, relaunched at T=90. The whole downtime is an
        // undecided gap; nothing is silently counted.
        let start = Date(timeIntervalSince1970: 0)
        let restoreTime = start.addingTimeInterval(90 * 60)

        var session = makeSession(startedAt: start, lastCheckpointAt: start, accumulatedMinutes: 0)
        // Mirrors restore: lastCheckpointAt..now becomes a gap when long.
        session.awayGaps.append(AwayGap(start: session.lastCheckpointAt, end: restoreTime))
        session.lastCheckpointAt = restoreTime

        #expect(TrackingManager.bookableMinutes(session, at: restoreTime) == 1) // only the min-1 open interval
        session.awayGaps[0].resolution = .counted
        #expect(TrackingManager.bookableMinutes(session, at: restoreTime) == 91)
    }

    @Test func restore_midAwayClosesGapOnReturn() {
        // Persisted while away (awaySince set); restore closes it at now.
        let start = Date(timeIntervalSince1970: 0)
        let awayStart = start.addingTimeInterval(20 * 60)
        let restoreTime = start.addingTimeInterval(80 * 60)

        var session = makeSession(startedAt: start)
        session = TrackingManager.beginAway(session, at: awayStart)
        // Restore path: endAway at relaunch time.
        session = TrackingManager.endAway(session, at: restoreTime)

        #expect(session.awaySince == nil)
        #expect(session.awayGaps.count == 1)
        #expect(session.awayGaps[0].minutes == 60)
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

    // MARK: - Transient vs permanent booking failures

    @Test func isTransient_networkAndServerErrorsRetry() {
        #expect(TrackingManager.isTransient(URLError(.notConnectedToInternet)))
        #expect(TrackingManager.isTransient(URLError(.timedOut)))
        #expect(TrackingManager.isTransient(GitLabAPIError.serverError(statusCode: 500, message: "x")))
        #expect(TrackingManager.isTransient(GitLabAPIError.serverError(statusCode: 429, message: "x")))
        #expect(TrackingManager.isTransient(GitLabAPIError.serverError(statusCode: 401, message: "x")))
        #expect(TrackingManager.isTransient(GitLabAPIError.notAuthenticated))
    }

    @Test func isTransient_clientErrorsDoNotRetry() {
        #expect(!TrackingManager.isTransient(GitLabAPIError.serverError(statusCode: 404, message: "x")))
        #expect(!TrackingManager.isTransient(GitLabAPIError.serverError(statusCode: 403, message: "x")))
        #expect(!TrackingManager.isTransient(GitLabAPIError.missingConfiguration))
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
