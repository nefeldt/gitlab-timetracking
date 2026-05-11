//
//  SettingsView.swift
//  My GitLab Timetracking
//

import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var authManager: GitLabAuthManager
    var projectManager: ProjectManager
    var tracker: TrackingManager

    @State private var isRefreshing = false
    @State private var pendingGroupPath = ""
    @State private var useCustomInterval = false

    private var availableGroupPaths: [String] {
        let projectGroups: [String] = projectManager.projects.compactMap { project in
            let components = project.pathWithNamespace.split(separator: "/").dropLast()
            guard !components.isEmpty else { return nil }
            return components.joined(separator: "/")
        }

        let mergedGroups = Set(projectGroups).union(settings.gitLabGroupPaths)
        return mergedGroups.sorted()
    }

    private var selectableGroupPaths: [String] {
        availableGroupPaths.filter { !settings.gitLabGroupPaths.contains($0) }
    }

    var body: some View {
        Form {
            Section("GitLab") {
                TextField("https://gitlab.example.com", text: $settings.gitLabBaseURL)
                    .textFieldStyle(.roundedBorder)

                TextField("OAuth application ID", text: $settings.oauthClientID)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Add Group", selection: $pendingGroupPath) {
                            Text("Select a group")
                                .tag("")

                            ForEach(selectableGroupPaths, id: \.self) { groupPath in
                                Text(groupPath)
                                    .tag(groupPath)
                            }
                        }

                        Button("Add") {
                            guard !pendingGroupPath.isEmpty else { return }
                            settings.addSelectedGroup(path: pendingGroupPath)
                            pendingGroupPath = ""
                        }
                        .disabled(pendingGroupPath.isEmpty)
                    }

                    if settings.gitLabGroupPaths.isEmpty {
                        Text("All visible projects are currently included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(settings.gitLabGroupPaths, id: \.self) { groupPath in
                                HStack {
                                    Text(groupPath)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("Remove") {
                                        settings.removeSelectedGroup(path: groupPath)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }

                        Button("Use All Visible Projects") {
                            settings.clearSelectedGroups()
                            pendingGroupPath = ""
                        }
                        .buttonStyle(.borderless)
                    }
                }

                LabeledContent("Callback URL") {
                    Text(GitLabAuthManager.redirectURI.absoluteString)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                Text("Register a GitLab OAuth application for a public client with the callback URL above and scope `api`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Selected groups limit the create-issue project picker to projects inside those namespaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Account") {
                if let currentUser = authManager.currentUser {
                    Text("\(currentUser.name) (@\(currentUser.username))")
                        .font(.body)
                    HStack {
                        Button("Refresh") {
                            Task {
                                isRefreshing = true
                                await authManager.refreshCurrentUser()
                                await projectManager.refreshProjects()
                                await tracker.refreshIssues()
                                isRefreshing = false
                            }
                        }
                        .disabled(isRefreshing)

                        Button("Disconnect Account") {
                            authManager.signOut()
                            projectManager.clearProjectState()
                            tracker.clearIssues()
                        }

                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } else {
                    HStack {
                        Button("Connect GitLab Account") {
                            Task {
                                await authManager.signIn()
                                await projectManager.refreshProjects()
                                await tracker.refreshIssues()
                            }
                        }
                        .disabled(!settings.isConfigured || authManager.isAuthenticating)

                        if authManager.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)

                            Button("Cancel") {
                                authManager.cancelSignIn()
                            }
                        }
                    }

                    if authManager.isAuthenticating {
                        Text("Waiting for you to authorize the app in your browser. If nothing happens within about two minutes, the request will time out.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let authError = authManager.authError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(authError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {}
                    }
                ))
            }

            Section("Appearance") {
                Toggle("Show parent issue on issue cards", isOn: $settings.showParentIssueOnCard)
                Toggle("Show status pill on issue cards", isOn: $settings.showStatusPillOnCard)
            }

            Section("Time Tracking") {
                Toggle("Show worked time in menu bar", isOn: $settings.showTrackedTimeInMenuBar)
                Toggle("Show issue ID in menu bar", isOn: $settings.showIssueReferenceInMenuBar)
                HStack {
                    let presets = [5, 10, 15, 20, 25, 30, 45, 60]

                    Picker("Notification interval", selection: Binding(
                        get: {
                            useCustomInterval ? -1 : (presets.contains(settings.checkpointMinutes) ? settings.checkpointMinutes : -1)
                        },
                        set: { newValue in
                            if newValue == -1 {
                                useCustomInterval = true
                            } else {
                                useCustomInterval = false
                                settings.checkpointMinutes = newValue
                            }
                        }
                    )) {
                        ForEach(presets, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                        Text("Custom").tag(-1)
                    }

                    if useCustomInterval {
                        TextField("", value: $settings.checkpointMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("min")
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    useCustomInterval = ![5, 10, 15, 20, 25, 30, 45, 60].contains(settings.checkpointMinutes)
                }
                HStack {
                    Picker("Notification sound", selection: $settings.notificationSound) {
                        ForEach(["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"], id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Button {
                        if let sound = NSSound(named: NSSound.Name(settings.notificationSound)) {
                            sound.volume = 1.0
                            sound.play()
                        }
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.borderless)
                    .help("Preview sound")
                }
                Text("Selecting an issue starts tracking. Every \(settings.checkpointMinutes) minutes the app asks whether to continue. Time is accumulated and booked to GitLab as one entry when you stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                let info = Bundle.main.infoDictionary
                let version = info?["CFBundleShortVersionString"] as? String ?? "—"
                let build = info?["CFBundleVersion"] as? String ?? "—"
                let copyright = info?["NSHumanReadableCopyright"] as? String ?? ""
                let appName = info?["CFBundleName"] as? String ?? "GitLab Timetracking"

                VStack(alignment: .leading, spacing: 4) {
                    Text(appName)
                        .font(.headline)
                    Text("Version \(version) (\(build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !copyright.isEmpty {
                        Text(copyright)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings.gitLabBaseURL) { _, _ in
            settings.save()
            projectManager.handleSettingsSaved()
        }
        .onChange(of: settings.oauthClientID) { _, _ in settings.save() }
        .onChange(of: settings.showTrackedTimeInMenuBar) { _, _ in settings.save() }
        .onChange(of: settings.showIssueReferenceInMenuBar) { _, _ in settings.save() }
        .onChange(of: settings.showParentIssueOnCard) { _, _ in settings.save() }
        .onChange(of: settings.showStatusPillOnCard) { _, _ in settings.save() }
        .onChange(of: settings.checkpointMinutes) { _, _ in settings.save() }
        .onChange(of: settings.notificationSound) { _, _ in settings.save() }
    }
}
