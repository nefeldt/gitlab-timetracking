#if os(iOS)
import ActivityKit
import Foundation

struct TrackingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var issueReference: String
        var issueTitle: String
        var startDate: Date
    }
    var issueID: Int
}
#endif
