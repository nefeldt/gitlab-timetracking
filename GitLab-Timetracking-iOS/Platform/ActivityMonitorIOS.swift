import Foundation
import UIKit

@MainActor
final class ActivityMonitorIOS: ActivityMonitoring {
    var onAway: ((Date) -> Void)?
    var onReturn: ((Date) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var isAway = false

    func start() {
        guard observers.isEmpty else { return }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.markAway() }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.markReturn() }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIScene.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.markAway() }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIScene.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.markReturn() }
            }
        )
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func markAway() {
        guard !isAway else { return }
        isAway = true
        onAway?(Date())
    }

    private func markReturn() {
        guard isAway else { return }
        isAway = false
        onReturn?(Date())
    }
}
