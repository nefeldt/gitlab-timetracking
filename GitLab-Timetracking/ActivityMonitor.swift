//
//  ActivityMonitor.swift
//  My GitLab Timetracking
//

import Foundation
import AppKit

/// Reports when the machine becomes unavailable ("away") and available again
/// ("return") so tracking can record an uncertain gap rather than silently
/// counting — or silently dropping — that time.
///
/// Sources watched:
/// - system sleep / wake
/// - display sleep / wake
/// - screen lock / unlock
/// - fast user switching (session resign / become active)
///
/// Pure input-idle (no lock) is intentionally not watched yet; see the refactor
/// plan, §4.2.
@MainActor
final class ActivityMonitor {
    /// Called with the wall-clock time the machine became unavailable.
    var onAway: ((Date) -> Void)?
    /// Called with the wall-clock time the machine became available again.
    var onReturn: ((Date) -> Void)?

    private var isAway = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    private static let lockName = Notification.Name("com.apple.screenIsLocked")
    private static let unlockName = Notification.Name("com.apple.screenIsUnlocked")

    func start() {
        guard workspaceObservers.isEmpty, distributedObservers.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let awayNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let returnNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]

        for name in awayNames {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.markAway() }
                }
            )
        }
        for name in returnNames {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.markReturn() }
                }
            )
        }

        // Screen lock/unlock are only published on the distributed center.
        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.append(
            distributedCenter.addObserver(forName: Self.lockName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.markAway() }
            }
        )
        distributedObservers.append(
            distributedCenter.addObserver(forName: Self.unlockName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.markReturn() }
            }
        )
    }

    func stop() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let distributedCenter = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributedCenter.removeObserver(observer)
        }
        distributedObservers.removeAll()
    }

    // Several sources can fire for one physical event (lock then sleep, etc.).
    // Collapse them with a single away/return latch so the first away event
    // wins and the first return event clears it.
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
