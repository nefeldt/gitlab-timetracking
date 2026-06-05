import Foundation

final class IssueCacheStore {
    private let key = "cached.assigned.issues"
    private let store = NSUbiquitousKeyValueStore.default

    func save(_ issues: [GitLabIssue]) {
        guard let data = try? JSONEncoder().encode(issues) else { return }
        store.set(data, forKey: key)
        store.synchronize()
    }

    func load() -> [GitLabIssue] {
        guard let data = store.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([GitLabIssue].self, from: data)) ?? []
    }

    func clear() {
        store.removeObject(forKey: key)
    }
}
