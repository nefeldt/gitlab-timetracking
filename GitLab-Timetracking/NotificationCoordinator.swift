//
//  NotificationCoordinator.swift
//  My GitLab Timetracking
//

import Foundation
import UserNotifications
import AppKit
import os.log

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    static let continueActionID = "CONTINUE_TRACKING"
    static let stopActionID = "STOP_TRACKING"
    static let categoryID = "TRACKING_CHECKPOINT"
    static let notificationID = "TRACKING_CHECKPOINT_ACTIVE"

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitLabTimetracking", category: "Notifications")

    /// Invoked when the user acknowledges the check-in ("keep going"). Tracking
    /// is never paused, so this only dismisses the outstanding nudge.
    var onContinue: (() -> Void)?
    var onStop: (() -> Void)?
    private var reminderTask: Task<Void, Never>?
    private var alertSound: NSSound?

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let continueAction = UNNotificationAction(
            identifier: Self.continueActionID,
            title: "Keep Tracking",
            options: []
        )
        let stopAction = UNNotificationAction(
            identifier: Self.stopActionID,
            title: "Stop & Book",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [continueAction, stopAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Self.log.error("Notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                Self.log.warning("Notification authorization denied by user")
            }
        }
    }

    func sendCheckpointNotification(for issue: GitLabIssue, checkpointMinutes: Int, soundName: String) {
        let content = UNMutableNotificationContent()
        content.title = issue.references.short
        content.subtitle = issue.title
        content.body = "Still tracking — \(checkpointMinutes) more minutes counted. Keep going or stop to book."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.categoryID

        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
        NSApp.requestUserAttention(.criticalRequest)
        playReminderSound(named: soundName)
    }

    func beginCheckpointReminderLoop(for issue: GitLabIssue, checkpointMinutes: Int, soundName: String, interval: TimeInterval = 180) {
        reminderTask?.cancel()
        reminderTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }

                if Task.isCancelled { return }
                self.sendCheckpointNotification(for: issue, checkpointMinutes: checkpointMinutes, soundName: soundName)
            }
        }
    }

    func clearCheckpointNotification() {
        reminderTask?.cancel()
        reminderTask = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            switch response.actionIdentifier {
            case Self.continueActionID, UNNotificationDefaultActionIdentifier:
                onContinue?()
            case Self.stopActionID:
                onStop?()
            default:
                break
            }
        }
    }

    private func playReminderSound(named soundName: String) {
        if let sound = NSSound(named: NSSound.Name(soundName)) {
            alertSound = sound
            sound.volume = 1.0
            sound.play()
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                sound.play()
            }
            return
        }

        NSSound.beep()
    }
}
