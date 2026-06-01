//
//  NetworkMonitor.swift
//  My GitLab Timetracking
//

import Foundation
import Network

/// Tracks network reachability so pending time bookings can be retried
/// automatically when connectivity (e.g. company VPN) comes back, instead of
/// waiting for the user to retry by hand.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "GitLabTimetracking.NetworkMonitor")

    private(set) var isReachable = true
    /// Called on the rising edge (unreachable → reachable).
    var onBecameReachable: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasReachable = self.isReachable
                self.isReachable = reachable
                if reachable && !wasReachable {
                    self.onBecameReachable?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
