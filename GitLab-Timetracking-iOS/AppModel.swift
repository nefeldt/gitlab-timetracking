import Foundation

/// Singleton shared between the SwiftUI app and the CarPlay scene delegate,
/// which is instantiated independently by UIKit's scene machinery.
@MainActor
final class AppModel {
    static private(set) var shared: AppModel = AppModel()

    let settings: AppSettings
    let authManager: GitLabAuthManager
    let projectManager: ProjectManager
    let trackingManager: TrackingManager

    private init() {
        let s = AppSettings()
        let a = GitLabAuthManager(settings: s)
        settings = s
        authManager = a
        projectManager = ProjectManager(authManager: a)
        trackingManager = TrackingManager(authManager: a)
    }

    /// Called from the App init so the SwiftUI-owned instances are also
    /// the ones CarPlay uses (avoids two separate stacks).
    static func configure(
        settings: AppSettings,
        authManager: GitLabAuthManager,
        projectManager: ProjectManager,
        trackingManager: TrackingManager
    ) {
        shared = AppModel(
            settings: settings,
            authManager: authManager,
            projectManager: projectManager,
            trackingManager: trackingManager
        )
    }

    private init(
        settings: AppSettings,
        authManager: GitLabAuthManager,
        projectManager: ProjectManager,
        trackingManager: TrackingManager
    ) {
        self.settings = settings
        self.authManager = authManager
        self.projectManager = projectManager
        self.trackingManager = trackingManager
    }
}
