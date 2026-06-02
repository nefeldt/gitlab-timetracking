//
//  SessionStore.swift
//  My GitLab Timetracking
//

import Foundation

/// An "away" period (machine asleep, screen locked, fast-user-switched, or the
/// app not running) during an active session. Whether it counts as work is
/// ambiguous — stepping away for a break vs. rolling the laptop to a
/// colleague's desk — so the user decides. Gaps are never auto-discarded.
struct AwayGap: Codable, Identifiable, Hashable {
    enum Resolution: String, Codable {
        case undecided
        case counted
        case discarded
    }

    let id: UUID
    let start: Date
    var end: Date
    var resolution: Resolution
    /// When `.counted`, how many of the gap's minutes to credit as work.
    /// `nil` means credit the full span. Lets the user count only the part of
    /// an away period they actually worked (e.g. 23 min of a 90 min gap that
    /// also covered lunch).
    var countedMinutes: Int?

    init(id: UUID = UUID(), start: Date, end: Date, resolution: Resolution = .undecided, countedMinutes: Int? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.resolution = resolution
        self.countedMinutes = countedMinutes
    }

    /// Whole minutes spanned by the gap (shares the session min-1 clamp).
    var minutes: Int {
        max(1, Int(end.timeIntervalSince(start) / 60))
    }

    /// Minutes credited toward booked time given the current resolution.
    var creditedMinutes: Int {
        switch resolution {
        case .counted: return min(countedMinutes ?? minutes, minutes)
        case .undecided, .discarded: return 0
        }
    }
}

struct PersistedSession: Codable {
    let issue: GitLabIssue
    let startedAt: Date
    let lastCheckpointAt: Date
    let accumulatedMinutes: Int
    var awayGaps: [AwayGap]
    var awaySince: Date?

    init(
        issue: GitLabIssue,
        startedAt: Date,
        lastCheckpointAt: Date,
        accumulatedMinutes: Int,
        awayGaps: [AwayGap] = [],
        awaySince: Date? = nil
    ) {
        self.issue = issue
        self.startedAt = startedAt
        self.lastCheckpointAt = lastCheckpointAt
        self.accumulatedMinutes = accumulatedMinutes
        self.awayGaps = awayGaps
        self.awaySince = awaySince
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.issue = try container.decode(GitLabIssue.self, forKey: .issue)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.lastCheckpointAt = try container.decode(Date.self, forKey: .lastCheckpointAt)
        self.accumulatedMinutes = try container.decode(Int.self, forKey: .accumulatedMinutes)
        // Fields added with away detection; older payloads omit them.
        self.awayGaps = try container.decodeIfPresent([AwayGap].self, forKey: .awayGaps) ?? []
        self.awaySince = try container.decodeIfPresent(Date.self, forKey: .awaySince)
    }

    // `awaitingContinuation` was removed when check-ins stopped pausing
    // tracking. Older persisted payloads may still contain the key; Codable
    // ignores it on decode, so no explicit migration is required.
}

struct SessionStore {
    private let defaults: UserDefaults
    private let key = "tracking.activeSession"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedSession? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    func save(_ session: PersistedSession) {
        guard let data = try? JSONEncoder().encode(session) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
