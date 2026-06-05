import ActivityKit
import SwiftUI
import WidgetKit

@main
struct GitLabTimetrackingWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
    }
}

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackingActivityAttributes.self) { context in
            // Lock screen / notification banner
            HStack(spacing: 16) {
                Image(systemName: "timer")
                    .font(.title2)
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.issueReference)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(context.state.issueTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }

                Spacer()

                Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .trailing)
            }
            .padding()
            .activityBackgroundTint(Color.purple.opacity(0.15))
            .activitySystemActionForegroundColor(.purple)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.issueReference, systemImage: "timer")
                        .font(.callout)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                        .font(.callout.monospacedDigit())
                        .fontWeight(.semibold)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.issueTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(.purple)
            } compactTrailing: {
                Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit())
                    .fontWeight(.semibold)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(.purple)
            }
            .widgetURL(URL(string: "gitlab-timetracking://tracking"))
        }
    }
}
