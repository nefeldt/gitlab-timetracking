//
//  SessionStore.swift
//  My GitLab Timetracking
//

import Foundation

struct PersistedSession: Codable {
    let issue: GitLabIssue
    let startedAt: Date
    let lastCheckpointAt: Date
    let accumulatedMinutes: Int

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
