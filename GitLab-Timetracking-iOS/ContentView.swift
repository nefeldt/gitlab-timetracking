import SwiftUI

struct ContentView: View {
    @Environment(TrackingManager.self) private var tracker
    @Environment(GitLabAuthManager.self) private var authManager
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            TrackingView()
                .tabItem { Label("Tracking", systemImage: "timer") }
            BookingHistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
            SettingsViewIOS()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
