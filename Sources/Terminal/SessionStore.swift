import Foundation
import Observation

/// The live SSH sessions, keyed by host.
///
/// A terminal is not a screen you visit, it is a process you leave running.
/// Navigating back to the host list has to leave the shell — and whatever it
/// is in the middle of — exactly where it was, and tapping the same host
/// again has to return to *that* shell rather than opening a second one
/// beside it. Nothing else about a phone SSH client matters if a stray back
/// swipe kills a `tail -f`.
///
/// So sessions outlive the views that show them, and only two things end
/// one: the user disconnecting on purpose, or the far end hanging up.
@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    /// Every session this launch still holds, most recently opened first.
    /// Includes ones that have died — their terminal may still be on screen,
    /// and the reason they died is worth reading.
    private(set) var sessions: [TerminalSession] = []

    /// The ones with a shell actually on the other end.
    var live: [TerminalSession] {
        sessions.filter { $0.state == .connecting || $0.state == .connected }
    }

    private init() {}

    /// The session for a host, resuming the existing one if it is still up.
    ///
    /// A session that has failed or been closed is not reusable — its
    /// transport is gone — so it is replaced rather than handed back.
    func session(for host: Host,
                 app: Ghostty.App,
                 credentials: @autoclosure () -> SSHCredentials) -> TerminalSession {
        if let existing = sessions.first(where: { $0.host.id == host.id }) {
            switch existing.state {
            case .connecting, .connected:
                return existing
            case .failed, .closed:
                remove(existing)
            }
        }

        let session = TerminalSession(host: host, app: app)
        sessions.insert(session, at: 0)
        session.connect(credentials: credentials())
        return session
    }

    /// Adopt a session someone else built — Quick Connect makes its own so it
    /// can report an auth failure inside the sheet.
    func adopt(_ session: TerminalSession) {
        guard !sessions.contains(where: { $0 === session }) else { return }
        sessions.insert(session, at: 0)
    }

    /// Whether this host already has a shell waiting.
    func liveSession(for host: Host) -> TerminalSession? {
        sessions.first {
            $0.host.id == host.id && ($0.state == .connecting || $0.state == .connected)
        }
    }

    /// Hang up and forget. This is the only path that kills a session, and it
    /// is only ever reached from an explicit user action.
    func close(_ session: TerminalSession) {
        session.disconnect()
        remove(session)
    }

    func closeAll() {
        for session in sessions { session.disconnect() }
        sessions.removeAll()
    }

    /// Forget sessions that have died and are no longer on screen.
    ///
    /// A dead session is kept while its terminal is open so the failure text
    /// stays readable; once you have left that screen it is just a husk.
    func pruneDead() {
        sessions.removeAll {
            switch $0.state {
            case .failed, .closed: return true
            case .connecting, .connected: return false
            }
        }
    }

    private func remove(_ session: TerminalSession) {
        sessions.removeAll { $0 === session }
    }
}
