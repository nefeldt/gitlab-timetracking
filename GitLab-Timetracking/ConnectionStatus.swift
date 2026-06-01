//
//  ConnectionStatus.swift
//  My GitLab Timetracking
//

import Foundation

/// The app's live ability to talk to GitLab, derived passively from network
/// reachability plus the outcome of real API calls. Raw internet reachability
/// is not enough on its own — the company VPN can be down while the network is
/// otherwise "satisfied", which is exactly the case `gitLabUnreachable` flags.
enum ConnectionStatus: Equatable {
    /// GitLab base URL / OAuth client not set up yet.
    case notConfigured
    /// Configured but no valid GitLab account connected.
    case signedOut
    /// No usable network path at all.
    case offline
    /// Network is up but GitLab isn't responding (typically VPN down).
    case gitLabUnreachable
    /// Recent GitLab interaction succeeded.
    case connected

    /// Short label for the menu bar tooltip / popover row.
    var label: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .signedOut: return "Not signed in"
        case .offline: return "Offline"
        case .gitLabUnreachable: return "Can't reach GitLab"
        case .connected: return "Connected"
        }
    }

    /// Extra context for the actionable (non-connected) states.
    var detail: String? {
        switch self {
        case .notConfigured: return "Configure GitLab in Settings."
        case .signedOut: return "Connect your GitLab account in Settings."
        case .offline: return "No network connection."
        case .gitLabUnreachable: return "Network is up but GitLab isn't responding — check your VPN."
        case .connected: return nil
        }
    }
}
