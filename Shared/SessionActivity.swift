import ActivityKit
import Foundation

/// What the Dynamic Island shows while an SSH session is up.
///
/// Compiled into both the app and the widget extension, which is the whole
/// reason this lives in its own folder: the two targets must agree on this
/// type byte for byte, and the compiler is the only thing that can enforce
/// that.
///
/// Deliberately small. A Live Activity is refreshed by the system on its own
/// schedule, and every field here is one more thing that can be stale on
/// screen — so it carries the few facts that stay true between updates and
/// nothing that looks like live telemetry.
struct SessionActivityAttributes: ActivityAttributes {
    /// Fixed for the life of the session.
    var hostAlias: String
    var target: String
    /// Which shell on this host, when there is more than one.
    var ordinal: Int
    /// When the session opened.
    ///
    /// In the attributes rather than the state because it never changes —
    /// and because that lets the Island count upwards on its own, with
    /// `Text(style: .timer)`, without spending a single refresh from the
    /// system's budget. A live-looking number for free is exactly the trade
    /// a Live Activity should be making.
    var startedAt: Date

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Set once the far end names itself — usually `user@host: ~/dir`.
        var title: String?
        /// Bytes received, which is the cheapest honest proof the connection
        /// is doing something rather than merely being open.
        var bytesIn: Int
        /// Why it ended, when it did.
        var detail: String?

        enum Phase: String, Codable, Hashable {
            case connecting, connected, closed, failed

            var label: String {
                switch self {
                case .connecting: return "connecting"
                case .connected: return "connected"
                case .closed: return "closed"
                case .failed: return "failed"
                }
            }
        }
    }
}
