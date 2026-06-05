//
//  NotificationCoordinator.swift
//  My GitLab Timetracking
//

import Foundation
import UserNotifications
import os.log
#if os(macOS)
import AppKit
#endif

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    static let continueActionID = "CONTINUE_TRACKING"
    static let stopActionID = "STOP_TRACKING"
    static let categoryID = "TRACKING_CHECKPOINT"
    static let notificationID = "TRACKING_CHECKPOINT_ACTIVE"

    static let countAwayActionID = "COUNT_AWAY"
    static let discardAwayActionID = "DISCARD_AWAY"
    static let awayCategoryID = "AWAY_RECONCILIATION"
    static let gapIDKey = "gapID"

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitLabTimetracking", category: "Notifications")

    /// Invoked when the user acknowledges the check-in ("keep going"). Tracking
    /// is never paused, so this only dismisses the outstanding nudge.
    var onContinue: (() -> Void)?
    var onStop: (() -> Void)?
    /// Invoked with the away-gap id when the user resolves a reconciliation prompt.
    var onCountAway: ((UUID) -> Void)?
    var onDiscardAway: ((UUID) -> Void)?
    private var reminderTask: Task<Void, Never>?
#if os(macOS)
    private var alertSound: NSSound?
#endif

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

        let countAwayAction = UNNotificationAction(
            identifier: Self.countAwayActionID,
            title: "Count as Work",
            options: []
        )
        let discardAwayAction = UNNotificationAction(
            identifier: Self.discardAwayActionID,
            title: "Don't Count",
            options: [.destructive]
        )
        let awayCategory = UNNotificationCategory(
            identifier: Self.awayCategoryID,
            actions: [countAwayAction, discardAwayAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([category, awayCategory])
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
#if os(macOS)
        NSApp.requestUserAttention(.criticalRequest)
#endif
        playReminderSound(named: soundName)
    }

    /// Asks the user whether an away period should count as work. The gap stays
    /// resolvable in the app even if this notification is missed.
    func sendAwayReconciliationNotification(for issue: GitLabIssue, gap: AwayGap, soundName: String) {
        let content = UNMutableNotificationContent()
        content.title = issue.references.short
        content.subtitle = issue.title
        content.body = "You were away \(DurationFormatter.format(minutes: gap.minutes)). Count that time as work?"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.awayCategoryID
        content.userInfo = [Self.gapIDKey: gap.id.uuidString]

        let request = UNNotificationRequest(
            identifier: Self.awayNotificationID(for: gap.id),
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
#if os(macOS)
        NSApp.requestUserAttention(.informationalRequest)
#endif
        playReminderSound(named: soundName)
    }

    private static func awayNotificationID(for gapID: UUID) -> String {
        "AWAY_\(gapID.uuidString)"
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

    /// Removes the reconciliation prompts for the given away gaps so they don't
    /// linger after the gaps are resolved or the session ends.
    func clearAwayReconciliationNotifications(gapIDs: [UUID]) {
        guard !gapIDs.isEmpty else { return }
        let identifiers = gapIDs.map(Self.awayNotificationID(for:))
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
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
            let content = response.notification.request.content
            let action = response.actionIdentifier

            if content.categoryIdentifier == Self.awayCategoryID {
                guard let idString = content.userInfo[Self.gapIDKey] as? String,
                      let gapID = UUID(uuidString: idString) else { return }
                switch action {
                case Self.countAwayActionID:
                    onCountAway?(gapID)
                case Self.discardAwayActionID:
                    onDiscardAway?(gapID)
                default:
                    break // default tap opens the app; resolve via the in-app banner
                }
                return
            }

            switch action {
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
#if os(macOS)
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
#endif
    }
}
