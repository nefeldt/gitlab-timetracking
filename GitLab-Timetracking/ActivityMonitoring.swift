import Foundation

@MainActor
protocol ActivityMonitoring: AnyObject {
    var onAway: ((Date) -> Void)? { get set }
    var onReturn: ((Date) -> Void)? { get set }
    func start()
    func stop()
}
