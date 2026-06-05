import SwiftUI

@main
struct GitLabTimetrackingApp: App {
    @State private var settings: AppSettings
    @State private var authManager: GitLabAuthManager
    @State private var projectManager: ProjectManager
    @State private var tracker: TrackingManager

    init() {
        let s = AppSettings()
        let a = GitLabAuthManager(settings: s)
        let pm = ProjectManager(authManager: a)
        let tm = TrackingManager(authManager: a)
        AppModel.configure(settings: s, authManager: a, projectManager: pm, trackingManager: tm)
        _settings = State(initialValue: s)
        _authManager = State(initialValue: a)
        _projectManager = State(initialValue: pm)
        _tracker = State(initialValue: tm)
        BackgroundTaskManager.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(authManager)
                .environment(projectManager)
                .environment(tracker)
                .task {
                    NotificationCoordinator.shared.configure()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    if !tracker.pendingBookings.isEmpty {
                        BackgroundTaskManager.schedule()
                    }
                }
        }
    }
}
