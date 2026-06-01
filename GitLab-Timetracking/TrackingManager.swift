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
        /// Timestamp of the most recent check-in. Tracking never pauses at a
        /// check-in, so this is used only to schedule the next nudge and to
        /// measure the in-progress interval that has not yet been folded into
        /// `accumulatedMinutes`.
        var lastCheckpointAt: Date
        var accumulatedMinutes: Int
        /// Away periods (sleep / lock / user-switch / downtime) awaiting or
        /// having received a user decision.
        var awayGaps: [AwayGap] = []
        /// Set while the machine is currently away; nil while actively tracking.
        var awaySince: Date?
    }

    /// Away periods shorter than this are treated as continuous work (a quick
    /// lock or screen blank), so the user is not pestered for trivial gaps.
    static let awayIgnoreThreshold: TimeInterval = 90

    // MARK: - Testable calculation helpers

    nonisolated static func minutesBetween(from: Date, to: Date) -> Int {
        max(1, Int(to.timeIntervalSince(from) / 60))
    }

    /// Folds one checkpoint interval into the running total. Unlike the old
    /// behavior this does **not** pause tracking — the session keeps running and
    /// the next check-in is rescheduled immediately by the caller.
    nonisolated static func applyCheckpoint(to session: Session, checkpointMinutes: Int, at now: Date) -> Session {
        var updated = session
        updated.accumulatedMinutes += checkpointMinutes
        updated.lastCheckpointAt = now
        return updated
    }

    /// The machine became unavailable. Fold the interval worked up to now into
    /// confirmed time and stop counting until the user returns.
    nonisolated static func beginAway(_ session: Session, at now: Date) -> Session {
        guard session.awaySince == nil else { return session }
        var updated = session
        updated.accumulatedMinutes += minutesBetween(from: session.lastCheckpointAt, to: now)
        updated.lastCheckpointAt = now
        updated.awaySince = now
        return updated
    }

    /// The machine became available again. A brief blip counts as continuous
    /// work; a longer absence becomes an undecided gap for the user to resolve.
    /// Tracking resumes either way.
    nonisolated static func endAway(_ session: Session, at now: Date, ignoreThreshold: TimeInterval = awayIgnoreThreshold) -> Session {
        guard let awaySince = session.awaySince else { return session }
        var updated = session
        updated.awaySince = nil
        updated.lastCheckpointAt = now

        if now.timeIntervalSince(awaySince) < ignoreThreshold {
            updated.accumulatedMinutes += minutesBetween(from: awaySince, to: now)
        } else {
            updated.awayGaps.append(AwayGap(start: awaySince, end: now))
        }
        return updated
    }

    /// Minutes from away periods the user chose to count as work.
    nonisolated static func countedGapMinutes(_ session: Session) -> Int {
        session.awayGaps
            .filter { $0.resolution == .counted }
            .reduce(0) { $0 + $1.minutes }
    }

    /// Minutes of the in-progress interval (zero while away).
    nonisolated static func openIntervalMinutes(_ session: Session, at now: Date) -> Int {
        session.awaySince == nil ? minutesBetween(from: session.lastCheckpointAt, to: now) : 0
    }

    /// Total bookable minutes as of `now`: confirmed time + the open interval +
    /// counted away periods. Undecided and discarded gaps are excluded.
    nonisolated static func bookableMinutes(_ session: Session, at now: Date) -> Int {
        session.accumulatedMinutes + openIntervalMinutes(session, at: now) + countedGapMinutes(session)
    }

    /// Whether a booking failure is worth retrying automatically. Network
    /// problems (offline, timeout, VPN dropped), 5xx, 429 and auth blips are
    /// transient; a 4xx like 403/404 is permanent and left for manual handling.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let apiError = error as? GitLabAPIError {
            switch apiError {
            case let .serverError(statusCode, _):
                return statusCode >= 500 || statusCode == 429 || statusCode == 408 || statusCode == 401
            case .notAuthenticated, .invalidResponse:
                return true
            case .missingConfiguration:
                return false
            }
        }
        return true
    }

    var checkpointMinutes: Int { settings.checkpointMinutes }

    private let authManager: GitLabAuthManager
    private let settings: AppSettings
    private let api = GitLabAPI()
    private let sessionStore = SessionStore()
    private let historyStore = BookingHistoryStore()
    private var checkpointTask: Task<Void, Never>?
    private let activityMonitor = ActivityMonitor()
    private let networkMonitor = NetworkMonitor()
    private var retrySweepTask: Task<Void, Never>?
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
            self?.acknowledgeCheckIn()
        }
        NotificationCoordinator.shared.onStop = { [weak self] in
            self?.stopTracking()
        }
        NotificationCoordinator.shared.onCountAway = { [weak self] id in
            self?.resolveAwayGap(id: id, as: .counted)
        }
        NotificationCoordinator.shared.onDiscardAway = { [weak self] id in
            self?.resolveAwayGap(id: id, as: .discarded)
        }

        activityMonitor.onAway = { [weak self] date in
            self?.handleAway(at: date)
        }
        activityMonitor.onReturn = { [weak self] date in
            self?.handleReturn(at: date)
        }
        activityMonitor.start()

        networkMonitor.onBecameReachable = { [weak self] in
            self?.ensureRetrySweep()
        }
        networkMonitor.start()

        // Resume retrying anything left pending from a previous session.
        if !pendingBookings.isEmpty {
            ensureRetrySweep()
        }

        Task {
            await restorePersistedSessionIfNeeded()
        }
    }

    // MARK: - Automatic booking retry

    /// Drives pending bookings to completion in the background using capped
    /// exponential backoff. Re-kicked immediately when the network returns.
    private func ensureRetrySweep() {
        guard retrySweepTask == nil else { return }
        guard !pendingBookings.isEmpty else { return }

        retrySweepTask = Task { [weak self] in
            var delay: Duration = .seconds(2)
            let maxDelay: Duration = .seconds(300)

            while !Task.isCancelled {
                guard let self, !self.pendingBookings.isEmpty else { break }

                if self.networkMonitor.isReachable {
                    await self.retryAllPendingBookings(automatic: true)
                    if self.pendingBookings.isEmpty { break }
                }

                try? await Task.sleep(for: delay)
                delay = min(delay * 2, maxDelay)
            }

            self?.retrySweepTask = nil
        }
    }

    // MARK: - Away handling

    private func handleAway(at date: Date) {
        guard let session = activeSession, session.awaySince == nil else { return }
        activeSession = Self.beginAway(session, at: date)
        // No point nudging while the machine is unavailable.
        checkpointTask?.cancel()
        checkpointTask = nil
        persistActiveSession()
    }

    private func handleReturn(at date: Date) {
        guard let session = activeSession, session.awaySince != nil else { return }
        let priorGapCount = session.awayGaps.count
        let updated = Self.endAway(session, at: date)
        activeSession = updated
        persistActiveSession()
        scheduleCheckpoint()

        if updated.awayGaps.count > priorGapCount, let gap = updated.awayGaps.last {
            infoMessage = "Back on \(updated.issue.references.short). Away \(DurationFormatter.format(minutes: gap.minutes)) — count it?"
            NotificationCoordinator.shared.sendAwayReconciliationNotification(for: updated.issue, gap: gap, soundName: settings.notificationSound)
        }

        // Connectivity may have changed while away — flush anything pending.
        ensureRetrySweep()
    }

    var unresolvedAwayGaps: [AwayGap] {
        activeSession?.awayGaps.filter { $0.resolution == .undecided } ?? []
    }

    /// Marks every still-undecided away period as counted. Used when switching
    /// issues with the "include away" option so that time is booked, not lost.
    func countAllUnresolvedAwayGaps() {
        guard var session = activeSession else { return }
        var resolvedIDs: [UUID] = []
        for index in session.awayGaps.indices where session.awayGaps[index].resolution == .undecided {
            session.awayGaps[index].resolution = .counted
            resolvedIDs.append(session.awayGaps[index].id)
        }
        activeSession = session
        persistActiveSession()
        NotificationCoordinator.shared.clearAwayReconciliationNotifications(gapIDs: resolvedIDs)
    }

    func resolveAwayGap(id: UUID, as resolution: AwayGap.Resolution) {
        guard var session = activeSession,
              let index = session.awayGaps.firstIndex(where: { $0.id == id }) else { return }
        session.awayGaps[index].resolution = resolution
        activeSession = session
        persistActiveSession()
        NotificationCoordinator.shared.clearAwayReconciliationNotifications(gapIDs: [id])
    }

    var isTracking: Bool {
        activeSession != nil
    }

    var activeIssue: GitLabIssue? {
        activeSession?.issue
    }

    func secondsSinceLastCheckpoint(for session: Session) -> Int {
        // Frozen while away — the away period is not counted as work.
        guard session.awaySince == nil else { return 0 }
        return Int(max(0, Date().timeIntervalSince(session.lastCheckpointAt)))
    }

    func defaultStopSeconds(for session: Session) -> Int {
        session.accumulatedMinutes * 60
            + secondsSinceLastCheckpoint(for: session)
            + Self.countedGapMinutes(session) * 60
    }

    /// Minutes that would be booked if the user stopped right now: confirmed
    /// time + the in-progress interval + away periods marked as counted.
    func plannedBookingMinutes(for session: Session) -> Int {
        Self.bookableMinutes(session, at: Date())
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
        NotificationCoordinator.shared.clearAwayReconciliationNotifications(gapIDs: session.awayGaps.map(\.id))
        let totalMinutes = Self.bookableMinutes(session, at: Date())
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

    /// The user acknowledged a check-in nudge ("keep going"). Tracking already
    /// continued uninterrupted, so this only clears the outstanding nudge.
    func acknowledgeCheckIn() {
        guard let session = activeSession else { return }
        NotificationCoordinator.shared.clearCheckpointNotification()
        infoMessage = "Still tracking \(session.issue.references.short)."
    }

    func stopTrackingWithoutBooking() {
        checkpointTask?.cancel()
        checkpointTask = nil
        NotificationCoordinator.shared.clearCheckpointNotification()

        let ref = activeSession?.issue.references.short ?? ""
        NotificationCoordinator.shared.clearAwayReconciliationNotifications(gapIDs: activeSession?.awayGaps.map(\.id) ?? [])
        activeSession = nil
        sessionStore.clear()
        infoMessage = "Discarded tracking for \(ref)."
    }

    func saveSettings() async {
        authManager.settings.save()
        await refreshIssues()
    }

    func clearIssues() {
        checkpointTask?.cancel()
        checkpointTask = nil
        NotificationCoordinator.shared.clearAwayReconciliationNotifications(gapIDs: activeSession?.awayGaps.map(\.id) ?? [])
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
        guard let session = activeSession else { return }

        checkpointTask = nil
        let updated = Self.applyCheckpoint(to: session, checkpointMinutes: checkpointMinutes, at: Date())
        activeSession = updated
        persistActiveSession()

        // Non-blocking: keep tracking and immediately schedule the next nudge.
        scheduleCheckpoint()

        infoMessage = "\(DurationFormatter.format(minutes: updated.accumulatedMinutes)) tracked on \(updated.issue.references.short)."
        NotificationCoordinator.shared.sendCheckpointNotification(for: updated.issue, checkpointMinutes: checkpointMinutes, soundName: settings.notificationSound)
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

            if Self.isTransient(error) {
                errorMessage = "Booking deferred — will retry automatically. \(message)"
                infoMessage = "Will retry \(DurationFormatter.format(minutes: minutes)) on \(issue.references.short) when reachable."
                ensureRetrySweep()
            } else {
                errorMessage = "Booking failed, saved as pending. \(message)"
                infoMessage = "Open Booking History to retry \(DurationFormatter.format(minutes: minutes)) on \(issue.references.short)."
            }
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
    func retryPendingBooking(id: UUID, automatic: Bool = false) async -> Bool {
        guard let entry = bookingHistory.first(where: { $0.id == id }),
              entry.status == .pending else {
            return false
        }

        guard let projectID = entry.projectID, let issueIID = entry.issueIID else {
            var updated = entry
            updated.lastError = "Missing issue reference — cannot retry. Discard and re-track."
            bookingHistory = historyStore.update(updated)
            if !automatic { errorMessage = updated.lastError }
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
            // Stay quiet during background sweeps; the sweep keeps retrying.
            if !automatic { errorMessage = "Retry failed: \(error.localizedDescription)" }
            return false
        }
    }

    func retryAllPendingBookings(automatic: Bool = false) async {
        let pendingIDs = pendingBookings.map(\.id)
        guard !pendingIDs.isEmpty else { return }

        var successes = 0
        var failures = 0
        for id in pendingIDs {
            if await retryPendingBooking(id: id, automatic: automatic) {
                successes += 1
            } else {
                failures += 1
            }
        }

        if automatic {
            // Only surface good news automatically; failures keep retrying silently.
            if successes > 0 {
                errorMessage = pendingBookings.isEmpty ? nil : errorMessage
                infoMessage = "Synced \(successes) pending booking\(successes == 1 ? "" : "s")."
            }
            return
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
            let remoteEntries = try await fetchRemoteBookingEntries(
                for: snapshotIssues,
                currentUserID: currentUserID,
                cutoff: cutoff,
                configuration: configuration
            )

            bookingHistory = historyStore.mergeRemote(remoteEntries)
            lastHistorySyncAt = Date()
            lastSyncedCutoff = narrowerCutoff(existing: lastSyncedCutoff, new: cutoff)
            hasSyncedHistoryAtLeastOnce = true
        } catch {
            historySyncError = error.localizedDescription
        }

        isSyncingHistory = false
    }

    /// Fetches each issue's time-spent notes with bounded concurrency instead of
    /// one round trip at a time, so a large sync isn't a long sequential chain.
    /// The fetch and note parsing run off the main actor inside the API actor.
    private func fetchRemoteBookingEntries(
        for issues: [GitLabIssue],
        currentUserID: Int,
        cutoff: Date?,
        configuration: AuthorizedGitLabConfiguration
    ) async throws -> [BookingHistoryEntry] {
        guard !issues.isEmpty else { return [] }
        let api = self.api
        let maxConcurrent = min(6, issues.count)

        return try await withThrowingTaskGroup(of: [BookingHistoryEntry].self) { group in
            func addTask(for issue: GitLabIssue) {
                group.addTask {
                    let notes = try await api.fetchIssueNotes(
                        projectID: issue.projectID,
                        issueIID: issue.iid,
                        configuration: configuration
                    )
                    return notes.compactMap { note -> BookingHistoryEntry? in
                        guard note.system, note.author.id == currentUserID else { return nil }
                        if let cutoff, note.createdAt < cutoff { return nil }
                        guard let minutes = GitLabTimeNoteParser.addedMinutes(from: note.body), minutes > 0 else { return nil }
                        return BookingHistoryEntry(
                            id: UUID(),
                            issueID: issue.id,
                            issueReference: issue.references.short,
                            issueTitle: issue.title,
                            issueWebURL: issue.webURL,
                            minutes: minutes,
                            bookedAt: note.createdAt,
                            gitLabEventID: note.id
                        )
                    }
                }
            }

            var nextIndex = 0
            while nextIndex < maxConcurrent {
                addTask(for: issues[nextIndex])
                nextIndex += 1
            }

            var entries: [BookingHistoryEntry] = []
            while let result = try await group.next() {
                entries.append(contentsOf: result)
                if nextIndex < issues.count {
                    addTask(for: issues[nextIndex])
                    nextIndex += 1
                }
            }
            return entries
        }
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

    private func restorePersistedSessionIfNeeded() async {
        guard let persisted = sessionStore.load() else {
            return
        }

        var session = Session(
            issue: persisted.issue,
            startedAt: persisted.startedAt,
            lastCheckpointAt: persisted.lastCheckpointAt,
            accumulatedMinutes: persisted.accumulatedMinutes,
            awayGaps: persisted.awayGaps,
            awaySince: persisted.awaySince
        )

        // The app was not running between the last persist and now. Treat that
        // downtime the same way as an away period: a brief relaunch counts as
        // continuous work, a longer absence becomes an undecided gap.
        let now = Date()
        if session.awaySince != nil {
            session = Self.endAway(session, at: now)
        } else if now.timeIntervalSince(session.lastCheckpointAt) >= Self.awayIgnoreThreshold {
            session.awayGaps.append(AwayGap(start: session.lastCheckpointAt, end: now))
            session.lastCheckpointAt = now
        }

        activeSession = session
        persistActiveSession()

        guard authManager.isAuthenticated else {
            infoMessage = "Restore paused. Connect your GitLab account to continue \(session.issue.references.short)."
            return
        }

        if let gap = unresolvedAwayGaps.last {
            infoMessage = "Restored \(session.issue.references.short). Away \(DurationFormatter.format(minutes: gap.minutes)) while closed — count it?"
            NotificationCoordinator.shared.sendAwayReconciliationNotification(for: session.issue, gap: gap, soundName: settings.notificationSound)
        } else {
            infoMessage = "Restored tracking for \(session.issue.references.short)."
        }

        let remaining = TimeInterval(checkpointMinutes * 60) - now.timeIntervalSince(session.lastCheckpointAt)
        scheduleCheckpoint(after: max(1, remaining))
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
                accumulatedMinutes: activeSession.accumulatedMinutes,
                awayGaps: activeSession.awayGaps,
                awaySince: activeSession.awaySince
            )
        )
    }
}
