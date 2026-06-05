import SwiftUI

struct BookingHistoryView: View {
    @Environment(TrackingManager.self) private var tracker

    var body: some View {
        NavigationStack {
            Group {
                if tracker.bookingHistory.isEmpty {
                    ContentUnavailableView(
                        "No bookings yet",
                        systemImage: "clock",
                        description: Text("Bookings appear here after you stop tracking.")
                    )
                } else {
                    historyList
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if tracker.isSyncingHistory {
                        ProgressView()
                    } else {
                        Button {
                            Task { await tracker.syncHistoryFromGitLab(force: true) }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                }
            }
        }
    }

    private var historyList: some View {
        List(tracker.bookingHistory) { entry in
            HistoryRow(entry: entry)
        }
        .listStyle(.plain)
    }
}

private struct HistoryRow: View {
    let entry: BookingHistoryEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.issueReference)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.issueTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(entry.bookedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(DurationFormatter.format(minutes: entry.minutes))
                    .font(.subheadline)
                    .fontWeight(.medium)
                statusBadge
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch entry.status {
        case .booked:
            Label("Booked", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .uploading:
            Label("Uploading", systemImage: "arrow.up.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .pending:
            Label("Pending", systemImage: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
