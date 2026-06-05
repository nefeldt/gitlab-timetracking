import Foundation
import BackgroundTasks

/// Schedules and handles a BGAppRefreshTask that retries pending bookings
/// while the app is in the background, up to every 5 minutes.
@MainActor
final class BackgroundTaskManager {
    static let taskID = "feldt.systems.gitlab-timetracking.ios.booking-retry"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                await Self.handleRetry(task: task as! BGAppRefreshTask)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRetry(task: BGAppRefreshTask) async {
        schedule()

        let tracker = AppModel.shared.trackingManager
        task.expirationHandler = { task.setTaskCompleted(success: false) }

        if !tracker.pendingBookings.isEmpty {
            await tracker.retryAllPendingBookings(automatic: true)
        }

        task.setTaskCompleted(success: true)
    }
}
