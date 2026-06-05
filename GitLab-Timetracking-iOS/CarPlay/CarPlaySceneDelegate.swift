import Foundation
import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var observationTask: Task<Void, Never>?

    private var tracker: TrackingManager { AppModel.shared.trackingManager }

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
        startObserving()
        if tracker.issues.isEmpty {
            Task { await tracker.refreshIssues() }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Template construction

    private func makeRootTemplate() -> CPListTemplate {
        var sections: [CPListSection] = []

        // Current session section
        let statusItem: CPListItem
        if let session = tracker.activeSession {
            let minutes = TrackingManager.bookableMinutes(session, at: Date())
            let timeText = DurationFormatter.format(minutes: minutes)
            let item = CPListItem(
                text: session.issue.title,
                detailText: "\(session.issue.references.short) · \(timeText)"
            )
            item.handler = { [weak self] _, completion in
                self?.confirmStop(session: session)
                completion()
            }
            statusItem = item
        } else {
            statusItem = CPListItem(text: "Not tracking", detailText: "Select an issue below to start")
        }
        sections.append(CPListSection(items: [statusItem], header: "Current Session", sectionIndexTitle: nil))

        // Issues section: recent first, then rest up to 8 total
        let recentIDs = AppModel.shared.settings.recentIssueIDs
        let allIssues = tracker.issues
        let recentIssues = allIssues
            .filter { recentIDs.contains($0.id) }
            .sorted { (recentIDs.firstIndex(of: $0.id) ?? Int.max) < (recentIDs.firstIndex(of: $1.id) ?? Int.max) }
        let otherIssues = allIssues.filter { !recentIDs.contains($0.id) }
        let displayIssues = Array((recentIssues + otherIssues).prefix(8))

        if !displayIssues.isEmpty {
            let items = displayIssues.map { issue -> CPListItem in
                let isActive = tracker.activeSession?.issue.id == issue.id
                let detail = isActive ? "\(issue.references.short) · tracking" : issue.references.short
                let item = CPListItem(text: issue.title, detailText: detail)
                item.handler = { [weak self] _, completion in
                    if isActive {
                        self?.confirmStop(session: self!.tracker.activeSession!)
                    } else {
                        self?.confirmStart(issue: issue)
                    }
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Issues", sectionIndexTitle: nil))
        }

        let template = CPListTemplate(title: "GitLab Timetracking", sections: sections)
        return template
    }

    // MARK: - Actions

    private func confirmStop(session: TrackingManager.Session) {
        let minutes = TrackingManager.bookableMinutes(session, at: Date())
        let alert = CPAlertTemplate(
            titleVariants: ["Stop tracking?"],
            actions: [
                CPAlertAction(title: "Stop & Book \(DurationFormatter.format(minutes: minutes))", style: .destructive) { [weak self] _ in
                    self?.tracker.stopTracking()
                    self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                },
                CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                }
            ]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    private func confirmStart(issue: GitLabIssue) {
        let isTracking = tracker.activeSession != nil
        let title = isTracking ? "Switch to \(issue.references.short)?" : "Track \(issue.references.short)?"
        let confirmLabel = isTracking ? "Stop current & start" : "Start tracking"

        let alert = CPAlertTemplate(
            titleVariants: [title],
            actions: [
                CPAlertAction(title: confirmLabel, style: .default) { [weak self] _ in
                    if self?.tracker.activeSession != nil {
                        self?.tracker.stopTracking()
                    }
                    self?.tracker.startTracking(issue: issue)
                    self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                },
                CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                }
            ]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Reactive observation

    private func startObserving() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self?.tracker.activeSession
                        _ = self?.tracker.issues
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                self?.refreshRoot()
            }
        }
    }

    private func refreshRoot() {
        guard let controller = interfaceController else { return }
        controller.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
    }
}
