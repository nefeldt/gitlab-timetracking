import Foundation

/// Backs up pending (unbooked) history entries to iCloud KV store so they
/// survive a reinstall, device loss, or cross-device scenario.
/// The cloud copy is updated whenever the pending list changes and cleared
/// once all bookings have been confirmed by GitLab.
final class PendingBookingsCloudStore {
    private let cloudStore: NSUbiquitousKeyValueStore
    private static let key = "pending.bookings"

    init(cloudStore: NSUbiquitousKeyValueStore = .default) {
        self.cloudStore = cloudStore
    }

    func save(_ entries: [BookingHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        cloudStore.set(data, forKey: Self.key)
        cloudStore.synchronize()
    }

    func load() -> [BookingHistoryEntry] {
        guard let data = cloudStore.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([BookingHistoryEntry].self, from: data)) ?? []
    }

    func clear() {
        cloudStore.removeObject(forKey: Self.key)
        cloudStore.synchronize()
    }
}
