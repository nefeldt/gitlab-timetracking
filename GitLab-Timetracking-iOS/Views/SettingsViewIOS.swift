import SwiftUI

struct SettingsViewIOS: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GitLabAuthManager.self) private var authManager

    @State private var baseURLInput = ""
    @State private var clientIDInput = ""
    @State private var groupPathInput = ""
    @State private var showingAddGroup = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                connectionSection
                groupsSection
                trackingSection
            }
            .navigationTitle("Settings")
            .onAppear {
                baseURLInput = settings.gitLabBaseURL
                clientIDInput = settings.oauthClientID
            }
            .onChange(of: settings.gitLabBaseURL) { baseURLInput = settings.gitLabBaseURL }
            .onChange(of: settings.oauthClientID) { clientIDInput = settings.oauthClientID }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            if let user = authManager.currentUser {
                HStack {
                    VStack(alignment: .leading) {
                        Text(user.name)
                            .font(.headline)
                        Text("@\(user.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out", role: .destructive) {
                        authManager.signOut()
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("GitLab Connection") {
            LabeledContent("Instance URL") {
                TextField("https://gitlab.com", text: $baseURLInput)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit { applyURL() }
            }

            LabeledContent("OAuth Client ID") {
                TextField("Application ID", text: $clientIDInput)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { applyClientID() }
            }

            if settings.isConfigured {
                if authManager.isAuthenticating {
                    HStack {
                        ProgressView()
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                } else if authManager.isAuthenticated {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Connect to GitLab") {
                        applyURL()
                        applyClientID()
                        Task { await authManager.signIn() }
                    }
                }
            }

            if let error = authManager.authError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if settings.isConfigured {
                Text("iOS redirect URI — add to your GitLab OAuth app:\n\(GitLabAuthManager.redirectURI.absoluteString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Groups

    private var groupsSection: some View {
        Section("Group Filter") {
            ForEach(settings.gitLabGroupPaths, id: \.self) { path in
                Text(path)
            }
            .onDelete { indices in
                for index in indices {
                    settings.removeSelectedGroup(path: settings.gitLabGroupPaths[index])
                }
            }

            Button("Add Group") {
                showingAddGroup = true
            }
            .alert("Add Group", isPresented: $showingAddGroup) {
                TextField("group/subgroup", text: $groupPathInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    settings.addSelectedGroup(path: groupPathInput)
                    groupPathInput = ""
                }
                Button("Cancel", role: .cancel) { groupPathInput = "" }
            }
        }
    }

    // MARK: - Tracking

    private var trackingSection: some View {
        @Bindable var s = settings
        return Section("Tracking") {
            Stepper(
                "Checkpoint every \(settings.checkpointMinutes) min",
                value: $s.checkpointMinutes,
                in: 5...120,
                step: 5
            )
            .onChange(of: settings.checkpointMinutes) { settings.save() }
        }
    }

    // MARK: - Helpers

    private func applyURL() {
        settings.gitLabBaseURL = baseURLInput
        settings.save()
    }

    private func applyClientID() {
        settings.oauthClientID = clientIDInput
        settings.save()
    }
}
