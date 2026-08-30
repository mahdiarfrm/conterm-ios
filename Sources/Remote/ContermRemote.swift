import Foundation
import Observation

/// A remote view of Conterm running on a Mac.
///
/// **Why a file over SSH and not a socket.** The obvious design is a small
/// server in the Mac app and a client here. It is also the wrong one: it
/// means a listening port on a laptop, a firewall prompt, an authentication
/// scheme invented from scratch, and a feature that only works on the same
/// network. Publishing a file that this app reads over the SSH connection it
/// already has costs the Mac nothing, adds no attack surface, authenticates
/// by the same key you already trust, and works from anywhere you can reach
/// the machine — including through a jump host.
///
/// The Mac writes `~/.config/conterm/remote-state.json`, beside the
/// `tab-groups.json` it already keeps there, and watches an inbox directory
/// for what the phone asks back. If Conterm isn't running the file is simply
/// stale, and staleness is a fact worth showing rather than an error worth
/// hiding.
///
/// `ContermRemoteLink` holds the live end of this.
struct ContermState: Codable, Sendable {
    /// Bumped when the shape changes incompatibly. A phone newer than the Mac
    /// says so rather than decoding half a file.
    static let supportedVersion = 1

    var version: Int
    var publishedAt: Date
    var hostName: String?
    var appVersion: String?
    var windows: [Window]

    struct Window: Codable, Sendable, Identifiable {
        var index: Int
        var title: String?
        var isKey: Bool
        var tabs: [Tab]

        var id: Int { index }
    }

    struct Tab: Codable, Sendable, Identifiable {
        var index: Int
        var title: String
        var isSelected: Bool
        var groupName: String?
        var groupColorKey: String?
        var panes: [Pane]

        var id: String { "\(index)-\(title)" }
    }

    struct Pane: Codable, Sendable, Identifiable {
        var id: String
        var index: Int
        var title: String?
        var cwd: String?
        var dirLabel: String?
        /// Set when the pane is SSH'd somewhere — a Mac tab that is really a
        /// window onto another machine.
        var remoteHost: String?
        var isActive: Bool
        var agentPhase: String?
        var agentTool: String?
        var agentLabel: String?
    }

    /// How stale this snapshot is. The Mac republishes on a timer, so a
    /// snapshot much older than that cadence means Conterm has quit — which
    /// is exactly what you want to know before you trust what's on screen.
    var age: TimeInterval { Date().timeIntervalSince(publishedAt) }
    var looksLive: Bool { age < 90 }

    var paneCount: Int {
        windows.reduce(0) { $0 + $1.tabs.reduce(0) { $0 + $1.panes.count } }
    }

    var agentsNeedingYou: Int {
        windows.reduce(0) { w, window in
            w + window.tabs.reduce(0) { t, tab in
                t + tab.panes.filter { $0.agentPhase == "attention" }.count
            }
        }
    }
}
