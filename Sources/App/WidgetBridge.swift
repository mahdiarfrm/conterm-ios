import Foundation
import WidgetKit

/// Keeps the widgets' picture of Conterm current.
///
/// One function, called whenever something a widget could be showing has
/// changed. It is deliberately the *only* place that composes a snapshot, so
/// a feature that wants a presence on the home screen has exactly one file to
/// touch — and so nothing else in the app has to know that widgets exist.
///
/// Reloads are coalesced. WidgetKit gives an app a budget of timeline reloads
/// per day and quietly starts ignoring them once it is spent, so asking for
/// one per byte received would end with widgets that never update at all.
/// Everything that changes second by second on those faces — the uptime
/// clocks — is drawn ticking by the system from a fixed start date, so it
/// stays right without a reload being spent on it.
@MainActor
enum WidgetBridge {
    private static var pending: Task<Void, Never>?
    private static var lastWritten: ContermSnapshot?

    /// Rebuild and publish. Safe to call often.
    static func refresh() {
        pending?.cancel()
        pending = Task {
            // A beat, so a burst of changes — closing four sessions, a host
            // list import — becomes one write rather than four.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            publish()
        }
    }

    /// Publish now, without waiting. For the app going to the background,
    /// which is exactly when the home screen is about to be looked at.
    static func publishNow() {
        pending?.cancel()
        pending = nil
        publish()
    }

    private static func publish() {
        let snapshot = compose()
        // Comparing before writing keeps an idle app from spending reloads on
        // a picture that has not changed. `updatedAt` is excluded from the
        // comparison for the obvious reason.
        if var last = lastWritten {
            last.updatedAt = snapshot.updatedAt
            if last == snapshot { return }
        }
        lastWritten = snapshot
        ContermSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func compose() -> ContermSnapshot {
        let sessions = SessionStore.shared.sessions.map { session in
            ContermSnapshot.Session(
                id: String(UInt(bitPattern: ObjectIdentifier(session).hashValue)),
                alias: session.host.alias,
                target: session.host.displaySubtitle,
                startedAt: session.startedAt,
                phase: phase(of: session),
                ordinal: session.ordinal,
                bytesIn: session.bytesIn)
        }

        // A session can raise its own signal; everything else — agents on
        // your Mac, a host that stopped answering — arrives through the
        // SignalCenter, which is also what survives the app being closed.
        let lost: [ContermSnapshot.Signal] = SessionStore.shared.sessions.compactMap {
            session in
            guard case .failed(let why) = session.state else { return nil }
            return ContermSnapshot.Signal(
                id: session.host.id.uuidString,
                kind: .sessionLost,
                title: session.host.alias,
                detail: why,
                at: Date())
        }
        let signals = lost + SignalCenter.shared.all

        return ContermSnapshot(
            updatedAt: Date(),
            sessions: sessions,
            signals: signals,
            hostCount: HostStore.shared.hosts.count)
    }

    private static func phase(of session: TerminalSession) -> ContermSnapshot.Phase {
        switch session.state {
        case .connecting: return .connecting
        case .connected: return .connected
        case .closed: return .closed
        case .failed: return .failed
        }
    }
}
