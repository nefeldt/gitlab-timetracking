import SwiftUI

struct IssuePickerView: View {
    @Environment(TrackingManager.self) private var tracker
    @Environment(ProjectManager.self) private var projectManager
    @Environment(GitLabAuthManager.self) private var authManager

    @State private var searchText = ""
    @State private var isLoading = false

    var filteredIssues: [GitLabIssue] {
        guard !searchText.isEmpty else { return tracker.issues }
        let q = searchText.lowercased()
        return tracker.issues.filter {
            $0.title.lowercased().contains(q) || $0.references.short.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !authManager.isAuthenticated {
                    Text("Sign in from Settings to see your issues.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else if filteredIssues.isEmpty && !tracker.isLoading {
                    ContentUnavailableView.search
                } else {
                    issueList
                }
            }
            .navigationTitle("Issues")
            .searchable(text: $searchText, prompt: "Search issues")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if tracker.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await tracker.refreshIssues() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                if tracker.issues.isEmpty {
                    await tracker.refreshIssues()
                }
            }
        }
    }

    private var issueList: some View {
        List(filteredIssues) { issue in
            IssueRow(
                issue: issue,
                isTracking: tracker.activeSession?.issue.id == issue.id,
                onStart: {
                    if tracker.activeSession != nil {
                        tracker.stopTracking()
                    }
                    tracker.startTracking(issue: issue)
                }
            )
        }
        .listStyle(.plain)
    }
}

private struct IssueRow: View {
    let issue: GitLabIssue
    let isTracking: Bool
    let onStart: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.references.short)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(issue.title)
                    .font(.subheadline)
                    .lineLimit(2)
            }
            Spacer()
            if isTracking {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button {
                    onStart()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
