import SwiftUI

struct TrackingView: View {
    @Environment(TrackingManager.self) private var tracker
    @Environment(ProjectManager.self) private var projectManager
    @Environment(GitLabAuthManager.self) private var authManager

    @State private var searchText = ""

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
                    notConfiguredView
                } else {
                    mainList
                }
            }
            .navigationTitle("Tracking")
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

    // MARK: - Main list

    private var mainList: some View {
        List {
            if let session = tracker.activeSession {
                Section {
                    sessionCardContent(session)
                }

                let undecided = session.awayGaps.filter { $0.resolution == .undecided }
                if !undecided.isEmpty {
                    Section("Away periods — count as work?") {
                        ForEach(undecided) { gap in
                            awayGapRow(gap)
                        }
                    }
                }

                Section {
                    stopButton(session)
                }
            }

            Section("Issues") {
                if filteredIssues.isEmpty && !tracker.isLoading {
                    Text(searchText.isEmpty ? "No issues loaded" : "No results")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredIssues) { issue in
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
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Session card

    private func sessionCardContent(_ session: TrackingManager.Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.issue.references.short)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.15), in: Capsule())
                Spacer()
                if session.awaySince != nil {
                    Label("Away", systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("Tracking", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Text(session.issue.title)
                .font(.headline)
                .lineLimit(3)

            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let minutes = TrackingManager.bookableMinutes(session, at: Date())
                Text(DurationFormatter.format(minutes: minutes))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            if let awaySince = session.awaySince {
                Label("Away since \(awaySince, style: .relative)", systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Away gap row

    private func awayGapRow(_ gap: AwayGap) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(DurationFormatter.format(minutes: gap.minutes))
                    .font(.subheadline)
                Text("\(gap.start, style: .time) – \(gap.end, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Count") {
                tracker.resolveAwayGap(id: gap.id, as: .counted)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Discard") {
                tracker.resolveAwayGap(id: gap.id, as: .discarded)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
    }

    // MARK: - Stop button

    private func stopButton(_ session: TrackingManager.Session) -> some View {
        Button(role: .destructive) {
            tracker.stopTracking()
        } label: {
            HStack {
                Image(systemName: "stop.circle.fill")
                let minutes = TrackingManager.bookableMinutes(session, at: Date())
                Text("Stop & Book \(DurationFormatter.format(minutes: minutes))")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: - Not configured

    private var notConfiguredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Connect to GitLab")
                .font(.title2)
            Text("Go to Settings to configure your GitLab URL and sign in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Issue row

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
