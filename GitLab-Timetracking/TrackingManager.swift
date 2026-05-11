//
//  TrackingManager.swift
//  My GitLab Timetracking
//

import Foundation

@MainActor
@Observable
final class TrackingManager {
    struct Session {
        var issue: GitLabIssue
        var startedAt: Date
        var lastCheckpointAt: Date
        var awaitingContinuation: Bool
        var accumulatedMinutes: Int
    }

    // MARK: - Testable calculation helpers

    nonisolated static func minutesBetween(from: Date, to: Date) -> Int {
        max(1, Int(to.timeIntervalSince(from) / 60))
    }

    nonisolated static func applyCheckpoint(to session: Session, checkpointMinutes: Int, at now: Date) -> Session {
        var updated = session
        updated.accumulatedMinutes += checkpointMinutes
        updated.lastCheckpointAt = now
        updated.awaitingContinuation = true
        return updated
    }

    var checkpointMinutes: Int { settings.checkpointMinutes }

    private let authManager: GitLabAuthManager
    private let settings: AppSettings
    private let api = GitLabAPI()
    private let sessionStore = SessionStore()
    private let historyStore = BookingHistoryStore()
    private var checkpointTask: Task<Void, Never>?
    private(set) var lastRefreshAt: Date?

    var issues: [GitLabIssue] = []
    var issueStatuses: [Int: GitLabIssueStatus] = [:]
    var issueParents: [Int: GitLabIssueParent] = [:]
    var activeSession: Session?
    var isLoading = false
    var errorMessage: String?
    var infoMessage = "Configure GitLab to start."
    var bookingHistory: [BookingHistoryEntry] = []
    var isSyncingHistory = false
    var historySyncError: String?
    private(set) var lastHistorySyncAt: Date?
    private(set) var lastSyncedCutoff: Date?
    private var hasSyncedHistoryAtLeastOnce = false
    private(set) var visibleUploadingIDs: Set<UUID> = []
    private var uploadingRevealTasks: [UUID: Task<Void, Never>] = [:]
    private static let uploadingRevealDelay: Duration = .seconds(1)

    init(authManager: GitLabAuthManager) {
        self.authManager = authManager
        self.settings = authManager.settings
        self.bookingHistory = historyStore.load()

        NotificationCoordinator.shared.onContinue = { [weak self] in
            self?.continueAfterCheckpoint()
        }
        NotificationCoordinator.shared.onStop = { [weak self] in
            self?.finishAwaitingSession()
        }
        NotificationCoordinator.shared.onStopAndBookAll = { [weak self] in
            self?.finishAwaitingSessionIncludingElapsed()
        }

        Task {
            await restorePersistedSessionIfNeeded()
        }
    }

    var isTracking: Bool {
        guard let activeSession else { return false }
        return !activeSession.awaitingContinuation
    }

    var activeIssue: GitLabIssue? {
        activeSession?.issue
    }

    func secondsSinceLastCheckpoint(for session: Session) -> Int {
        Int(max(0, Date().timeIntervalSince(session.lastCheckpointAt)))
    }

    func defaultStopSeconds(for session: Session) -> Int {
        if session.awaitingContinuation {
            return session.accumulatedMinutes * 60
        }
        return session.accumulatedMinutes * 60 + secondsSinceLastCheckpoint(for: session)
    }

    func plannedBookingMinutes(for session: Session, includingCurrentCycle: Bool) -> Int {
        if includingCurrentCycle {
            return session.accumulatedMinutes + Self.minutesBetween(from: session.lastCheckpointAt, to: Date())
        }
        return session.accumulatedMinutes
    }

    func displayedTotalTrackedSeconds(for issue: GitLabIssue) -> Int {
        let baseSeconds = issue.timeStats.totalTimeSpent
        guard let activeSession, activeSession.issue.id == issue.id else {
            return baseSeconds
        }

        return baseSeconds + defaultStopSeconds(for: activeSession)
    }

    func formattedDuration(seconds: Int) -> String {
        DurationFormatter.format(seconds: seconds)
    }

    func formattedDuration(minutes: Int) -> String {
        DurationFormatter.format(minutes: minutes)
    }

    var orderedIssues: [GitLabIssue] {
        let recentIDs = settings.recentIssueIDs
        let recentIssues = recentIDs.compactMap { id in
            issues.first(where: { $0.id == id })
        }

        let remainingIssues = issues.filter { issue in
            !recentIDs.contains(issue.id)
        }
        .sorted { left, right in
            left.updatedAt > right.updatedAt
        }

        return recentIssues + remainingIssues
    }

    func refreshIssues() async {
        guard authManager.settings.isConfigured else {
            issues = []
            issueStatuses = [:]
            issueParents = [:]
            errorMessage = nil
            infoMessage = "Configure your GitLab instance and OAuth application in Settings."
            return
        }

        guard authManager.isAuthenticated else {
            issues = []
            issueStatuses = [:]
            issueParents = [:]
            errorMessage = nil
            infoMessage = "Connect your GitLab account in Settings."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let configuration = try await authManager.currentAuthorization()
            let fetchedIssues = try await api.fetchAssignedIssues(configuration: configuration)
            issues = fetchedIssues
            lastRefreshAt = Date()
            infoMessage = fetchedIssues.isEmpty ? "No currently assigned open issues." : "Assigned issues updated."

            let ids = fetchedIssues.map(\.id)
            if let info = try? await api.fetchIssueWorkItemInfo(issueIDs: ids, configuration: configuration) {
                issueStatuses = info.compactMapValues(\.status)
                issueParents = info.compactMapValues(\.parent)
            } else {
                issueStatuses = [:]
                issueParents = [:]
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func startTracking(issue: GitLabIssue) {
        checkpointTask?.cancel()
        NotificationCoordinator.shared.clearCheckpointNotification()

        let now = Date()
        activeSession = Session(
            issue: issue,
            startedAt: now,
            lastCheckpointAt: now,
            awaitingContinuation: false,
            accumulatedMinutes: 0
        )
        errorMessage = nil
        infoMessage = ""
        settings.rememberUsedIssue(id: issue.id)
        scheduleCheckpoint()
        persistActiveSession()

        Task {
            await refreshActiveIssue()
        }
    }

    private func refreshActiveIssue() async {
        guard let session = activeSession else { return }
        do {
            let configuration = try await authManager.currentAuthorization()
            let fresh = try await api.fetchIssue(projectID: session.issue.projectID, iid: session.issue.iid, configuration: configuration)
            if activeSession?.issue.id == fresh.id {
                activeSession?.issue = fresh
            }
            if let index = issues.firstIndex(where: { $0.id == fresh.id }) {
                issues[index] = fresh
            }
        } catch {
            // Non-critical — keep tracking with stale data
        }
    }

    func stopTracking() {
        checkpointTask?.cancel()
        checkpointTask = nil
        NotificationCoordinator.shared.clearCheckpointNotification()

        guard let session = activeSession else { return }
        let partialMinutes = session.awaitingContinuation ? 0 : minutesSinceLastCheckpoint(session: session)
        let totalMinutes = session.accumulatedMinutes + partialMinutes
        activeSession = nil
        sessionStore.clear()

        guard totalMinutes > 0 else {
            infoMessage = "Stopped tracking \(session.issue.references.short)."
            return
        }

        Task {
            await book(issue: session.issue, minutes: totalMinutes, followUp: "Booked \(DurationFormatter.format(minutes: totalMinutes)) to \(session.issue.references.short).")
        }
    }

    func continueAfterCheckpoint() {
        guard var session = activeSession, session.awaitingContinuation else { return }

        NotificationCoordinator.shared.clearCheckpointNotification()
        session.awaitingContinuation = false
        session.lastCheckpointAt = Date()
        activeSession = session
        infoMessage = "Continuing \(session.issue.references.short)."
        scheduleCheckpoint()
        persistActiveSession()
    }

    func stopTrackingWithoutBooking() {
        checkpointTask?.cancel()
        checkpointTask = nil
        NotificationCoordinator.shared.clearCheckpointNotification()

        let ref = activeSession?.issue.references.short ?? ""
        activeSession = nil
        sessionStore.clear()
        infoMessage = "Discarded tracking for \(ref)."
    }

    func finishAwaitingSession() {
        checkpointTask?.cancel()
        checkpointTask = nil
        NotificationCoordinator.shared.clearCheckpointNotification()

        guard let session = activeSession else { return }
        let totalMinutes = session.accumulatedMinutes
        activeSession = nil
        sessionStore.clear()

        guard totalMinutes > 0 else {
            infoMessage = "Stopped tracking \(session.issue.references.short)."
            return
        }

        Task {
            await book(issue: session.issue, minutes: totalMinutes, followUp: "Booked \(DurationFormatter.format(minutes: totalMinutes)) to \(session.issue.references.short).")
        }
    }

    func finishAwaitingSessionIncludingElapsed() {
        checkpointTask?.cancel()
        checkpointTask = nil
        NotificationCoordinator.shared.clearCheckpointNotification()

        guard let session = activeSession else { return }
        let totalMinutes = session.accumulatedMinutes + minutesSinceLastCheckpoint(session: session)
        activeSession = nil
        sessionStore.clear()

        guard totalMinutes > 0 else {
            infoMessage = "Stopped tracking \(session.issue.references.short)."
            return
        }

        Task {
            await book(issue: session.issue, minutes: totalMinutes, followUp: "Booked \(DurationFormatter.format(minutes: totalMinutes)) to \(session.issue.references.short).")
        }
    }

    func saveSettings() async {
        authManager.settings.save()
        await refreshIssues()
    }

    func clearIssues() {
        checkpointTask?.cancel()
        checkpointTask = nil
        issues = []
        issueStatuses = [:]
        issueParents = [:]
        errorMessage = nil
        activeSession = nil
        sessionStore.clear()
        infoMessage = "Connect your GitLab account in Settings."
    }

    func closeIssue(_ issue: GitLabIssue) async {
        if activeIssue?.id == issue.id {
            stopTracking()
        }

        do {
            let configuration = try await authManager.currentAuthorization()
            try await api.closeIssue(issue: issue, configuration: configuration)
            errorMessage = nil
            infoMessage = "Closed \(issue.references.short)."
            await refreshIssues()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteIssue(_ issue: GitLabIssue) async {
        if activeIssue?.id == issue.id {
            stopTracking()
        }

        do {
            let configuration = try await authManager.currentAuthorization()
            try await api.deleteIssue(issue: issue, configuration: configuration)
            errorMessage = nil
            infoMessage = "Deleted \(issue.references.short)."
            await refreshIssues()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleCheckpoint(after interval: TimeInterval? = nil) {
        checkpointTask?.cancel()

        checkpointTask = Task { [weak self] in
            guard let self else { return }
            let seconds = interval ?? TimeInterval(checkpointMinutes * 60)

            do {
                try await Task.sleep(for: .seconds(max(seconds, 1)))
            } catch {
                return
            }

            await self.handleCheckpoint()
        }
    }

    private func handleCheckpoint() async {
        guard let session = activeSession, !session.awaitingContinuation else { return }

        checkpointTask = nil
        let updated = Self.applyCheckpoint(to: session, checkpointMinutes: checkpointMinutes, at: Date())
        activeSession = updated
        persistActiveSession()

        infoMessage = "\(DurationFormatter.format(minutes: updated.accumulatedMinutes)) accumulated on \(updated.issue.references.short)."
        NotificationCoordinator.shared.sendCheckpointNotification(for: updated.issue, checkpointMinutes: checkpointMinutes, soundName: settings.notificationSound)
        NotificationCoordinator.shared.beginCheckpointReminderLoop(for: updated.issue, checkpointMinutes: checkpointMinutes, soundName: settings.notificationSound)
    }

    private func book(issue: GitLabIssue, minutes: Int, followUp: String) async {
        let attemptedAt = Date()
        let uploading = BookingHistoryEntry(
            issueID: issue.id,
            issueReference: issue.references.short,
            issueTitle: issue.title,
            issueWebURL: issue.webURL,
            minutes: minutes,
            bookedAt: attemptedAt,
            status: .uploading,
            projectID: issue.projectID,
            issueIID: issue.iid
        )
        bookingHistory = historyStore.append(uploading)
        scheduleUploadingReveal(id: uploading.id)

        defer { cancelUploadingReveal(id: uploading.id) }

        do {
            let configuration = try await authManager.currentAuthorization()
            try await api.addSpentTime(issue: issue, duration: "\(minutes)m", configuration: configuration)
            errorMessage = nil
            infoMessage = followUp

            var updated = uploading
            updated.status = .booked
            bookingHistory = historyStore.update(updated)
        } catch {
            let message = error.localizedDescription
            var updated = uploading
            updated.status = .pending
            updated.lastError = message
            bookingHistory = historyStore.update(updated)
            errorMessage = "Booking failed, saved as pending. \(message)"
            infoMessage = "Open Booking History to retry \(DurationFormatter.format(minutes: minutes)) on \(issue.references.short)."
        }
    }

    private func scheduleUploadingReveal(id: UUID) {
        uploadingRevealTasks[id]?.cancel()
        uploadingRevealTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.uploadingRevealDelay)
            guard !Task.isCancelled, let self else { return }
            self.visibleUploadingIDs.insert(id)
            self.uploadingRevealTasks[id] = nil
        }
    }

    private func cancelUploadingReveal(id: UUID) {
        uploadingRevealTasks[id]?.cancel()
        uploadingRevealTasks[id] = nil
        visibleUploadingIDs.remove(id)
    }

    var pendingBookings: [BookingHistoryEntry] {
        bookingHistory.filter { $0.status == .pending }
    }

    @discardableResult
    func retryPendingBooking(id: UUID) async -> Bool {
        guard let entry = bookingHistory.first(where: { $0.id == id }),
              entry.status == .pending else {
            return false
        }

        guard let projectID = entry.projectID, let issueIID = entry.issueIID else {
            var updated = entry
            updated.lastError = "Missing issue reference — cannot retry. Discard and re-track."
            bookingHistory = historyStore.update(updated)
            errorMessage = updated.lastError
            return false
        }

        var inFlight = entry
        inFlight.status = .uploading
        bookingHistory = historyStore.update(inFlight)
        visibleUploadingIDs.insert(inFlight.id)
        defer { cancelUploadingReveal(id: inFlight.id) }

        do {
            let configuration = try await authManager.currentAuthorization()
            try await api.addSpentTime(projectID: projectID, issueIID: issueIID, duration: "\(entry.minutes)m", configuration: configuration)
            var updated = inFlight
            updated.status = .booked
            updated.lastError = nil
            updated.bookedAt = Date()
            bookingHistory = historyStore.update(updated)
            errorMessage = nil
            infoMessage = "Booked \(DurationFormatter.format(minutes: entry.minutes)) to \(entry.issueReference)."
            return true
        } catch {
            var updated = inFlight
            updated.status = .pending
            updated.lastError = error.localizedDescription
            bookingHistory = historyStore.update(updated)
            errorMessage = "Retry failed: \(error.localizedDescription)"
            return false
        }
    }

    func retryAllPendingBookings() async {
        let pendingIDs = pendingBookings.map(\.id)
        guard !pendingIDs.isEmpty else { return }

        var successes = 0
        var failures = 0
        for id in pendingIDs {
            if await retryPendingBooking(id: id) {
                successes += 1
            } else {
                failures += 1
            }
        }

        if failures == 0 {
            errorMessage = nil
            infoMessage = "Retried \(successes) pending booking\(successes == 1 ? "" : "s")."
        } else {
            infoMessage = "Retried \(successes), \(failures) still pending."
        }
    }

    func discardPendingBooking(id: UUID) {
        guard let entry = bookingHistory.first(where: { $0.id == id }),
              entry.status == .pending else { return }
        bookingHistory = historyStore.remove(id: id)
        if pendingBookings.isEmpty {
            errorMessage = nil
        }
    }

    func clearBookingHistory() {
        for task in uploadingRevealTasks.values {
            task.cancel()
        }
        uploadingRevealTasks.removeAll()
        visibleUploadingIDs.removeAll()
        historyStore.clear()
        bookingHistory = []
    }

    func syncHistoryFromGitLab(cutoff: Date? = nil, force: Bool = false) async {
        guard !isSyncingHistory else { return }

        if !force, isSyncCoveredBy(existingCutoff: lastSyncedCutoff, newCutoff: cutoff), hasSyncedHistoryAtLeastOnce {
            return
        }

        guard authManager.isAuthenticated, let currentUserID = authManager.currentUser?.id else {
            historySyncError = "Connect your GitLab account to sync history."
            return
        }

        isSyncingHistory = true
        historySyncError = nil

        do {
            let configuration = try await authManager.currentAuthorization()
            let closedIssues = try await api.fetchClosedAssignedIssues(updatedAfter: cutoff, configuration: configuration)

            var issuesByID: [Int: GitLabIssue] = [:]
            for issue in issues where cutoff.map({ issue.updatedAt >= $0 }) ?? true {
                issuesByID[issue.id] = issue
            }
            for issue in closedIssues {
                issuesByID[issue.id] = issue
            }
            let snapshotIssues = Array(issuesByID.values)
            var remoteEntries: [BookingHistoryEntry] = []

            for issue in snapshotIssues {
                let notes = try await api.fetchIssueNotes(projectID: issue.projectID, issueIID: issue.iid, configuration: configuration)
                for note in notes where note.system && note.author.id == currentUserID {
                    if let cutoff, note.createdAt < cutoff {
                        continue
                    }

                    guard let minutes = GitLabTimeNoteParser.addedMinutes(from: note.body), minutes > 0 else {
                        continue
                    }

                    remoteEntries.append(
                        BookingHistoryEntry(
                            id: UUID(),
                            issueID: issue.id,
                            issueReference: issue.references.short,
                            issueTitle: issue.title,
                            issueWebURL: issue.webURL,
                            minutes: minutes,
                            bookedAt: note.createdAt,
                            gitLabEventID: note.id
                        )
                    )
                }
            }

            bookingHistory = historyStore.mergeRemote(remoteEntries)
            lastHistorySyncAt = Date()
            lastSyncedCutoff = narrowerCutoff(existing: lastSyncedCutoff, new: cutoff)
            hasSyncedHistoryAtLeastOnce = true
        } catch {
            historySyncError = error.localizedDescription
        }

        isSyncingHistory = false
    }

    private func isSyncCoveredBy(existingCutoff: Date?, newCutoff: Date?) -> Bool {
        guard let existingCutoff else { return true }
        guard let newCutoff else { return false }
        return newCutoff >= existingCutoff
    }

    private func narrowerCutoff(existing: Date?, new: Date?) -> Date? {
        guard let existing else { return nil }
        guard let new else { return nil }
        return min(existing, new)
    }

    private func minutesSinceLastCheckpoint(session: Session) -> Int {
        Self.minutesBetween(from: session.lastCheckpointAt, to: Date())
    }

    private func restorePersistedSessionIfNeeded() async {
        guard let persisted = sessionStore.load() else {
            return
        }

        var session = Session(
            issue: persisted.issue,
            startedAt: persisted.startedAt,
            lastCheckpointAt: persisted.lastCheckpointAt,
            awaitingContinuation: persisted.awaitingContinuation,
            accumulatedMinutes: persisted.accumulatedMinutes
        )

        activeSession = session

        if session.awaitingContinuation {
            infoMessage = "\(DurationFormatter.format(minutes: session.accumulatedMinutes)) accumulated on \(session.issue.references.short)."
            NotificationCoordinator.shared.sendCheckpointNotification(for: session.issue, checkpointMinutes: checkpointMinutes, soundName: settings.notificationSound)
            NotificationCoordinator.shared.beginCheckpointReminderLoop(for: session.issue, checkpointMinutes: checkpointMinutes, soundName: settings.notificationSound)
            return
        }

        guard authManager.isAuthenticated else {
            infoMessage = "Restore paused. Connect your GitLab account to continue \(session.issue.references.short)."
            return
        }

        let elapsed = Date().timeIntervalSince(session.lastCheckpointAt)
        let checkpointInterval = TimeInterval(checkpointMinutes * 60)

        if elapsed >= checkpointInterval {
            let checkpointFiredAt = session.lastCheckpointAt.addingTimeInterval(checkpointInterval)
            let updated = Self.applyCheckpoint(to: session, checkpointMinutes: checkpointMinutes, at: checkpointFiredAt)
            activeSession = updated
            persistActiveSession()

            infoMessage = "\(DurationFormatter.format(minutes: updated.accumulatedMinutes)) accumulated on \(updated.issue.references.short)."
            NotificationCoordinator.shared.sendCheckpointNotification(for: updated.issue, checkpointMinutes: checkpointMinutes, soundName: settings.notificationSound)
            NotificationCoordinator.shared.beginCheckpointReminderLoop(for: updated.issue, checkpointMinutes: checkpointMinutes, soundName: settings.notificationSound)
            return
        }

        infoMessage = "Restored tracking for \(session.issue.references.short)."
        scheduleCheckpoint(after: checkpointInterval - elapsed)
    }

    private func persistActiveSession() {
        guard let activeSession else {
            sessionStore.clear()
            return
        }

        sessionStore.save(
            PersistedSession(
                issue: activeSession.issue,
                startedAt: activeSession.startedAt,
                lastCheckpointAt: activeSession.lastCheckpointAt,
                awaitingContinuation: activeSession.awaitingContinuation,
                accumulatedMinutes: activeSession.accumulatedMinutes
            )
        )
    }
}
