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
    /// Tapping a host means "take me to that machine", and if you are already
    /// on it that means the shell you left running — opening a second
    /// connection behind your back is never what the tap meant. Wanting a
    /// second one is a real thing, but it is a *different* thing, so it has
    /// its own verb: `newSession`.
    func session(for host: Host,
                 app: Ghostty.App,
                 credentials: @autoclosure () -> SSHCredentials) -> TerminalSession {
        if let existing = liveSession(for: host) { return existing }
        return newSession(for: host, app: app, credentials: credentials())
    }

    /// Open another shell on a host you may already be on.
    ///
    /// One box, several jobs — a build tailing in one and a shell to poke at
    /// it in another — is the ordinary way to use a terminal, and the phone
    /// shouldn't be the one client that can't.
    @discardableResult
    func newSession(for host: Host,
                    app: Ghostty.App,
                    credentials: SSHCredentials) -> TerminalSession {
        // Dead sessions for this host are husks; don't let them accumulate
        // just because a new one was opened beside them.
        sessions.removeAll {
            guard $0.host.id == host.id else { return false }
            switch $0.state {
            case .failed, .closed: return true
            case .connecting, .connected: return false
            }
        }
        let session = TerminalSession(host: host, app: app)
        session.ordinal = (sessions.filter { $0.host.id == host.id }.map(\.ordinal).max() ?? 0) + 1
        sessions.insert(session, at: 0)
        session.connect(credentials: credentials)
        // The Island is where a session you walked away from lives.
        SessionActivityCenter.shared.start(for: session)
        return session
    }

    /// How many live shells this host has.
    func liveCount(for host: Host) -> Int {
        live.filter { $0.host.id == host.id }.count
    }

    /// Adopt a session someone else built — Quick Connect makes its own so it
    /// can report an auth failure inside the sheet.
    func adopt(_ session: TerminalSession) {
        guard !sessions.contains(where: { $0 === session }) else { return }
        session.ordinal = (sessions.filter { $0.host.id == session.host.id }
            .map(\.ordinal).max() ?? 0) + 1
        sessions.insert(session, at: 0)
        SessionActivityCenter.shared.start(for: session)
    }

    /// The most recent live shell on this host, if any.
    func liveSession(for host: Host) -> TerminalSession? {
        live.first { $0.host.id == host.id }
    }

    /// Hang up and forget. This is the only path that kills a session, and it
    /// is only ever reached from an explicit user action.
    func close(_ session: TerminalSession) {
        session.disconnect()
        SessionActivityCenter.shared.end(for: session)
        remove(session)
    }

    func closeAll() {
        for session in sessions {
            session.disconnect()
            SessionActivityCenter.shared.end(for: session)
        }
        sessions.removeAll()
    }

    /// Forget sessions that have died and are no longer on screen.
    ///
    /// A dead session is kept while its terminal is open so the failure text
    /// stays readable; once you have left that screen it is just a husk.
    func pruneDead() {
        for session in sessions where !live.contains(where: { $0 === session }) {
            SessionActivityCenter.shared.end(for: session)
        }
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
