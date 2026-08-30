@preconcurrency import ActivityKit
import Foundation
import os

/// Puts live sessions in the Dynamic Island.
///
/// A terminal on a phone is a thing you leave running and walk away from —
/// that is the whole reason sessions outlive their screen. The Island is where
/// that fact belongs: it is the one place iOS will show you "still connected
/// to prod" while you are in another app entirely.
///
/// Updates are deliberately sparse. The system budgets Live Activity
/// refreshes and throttles an app that spends them, so this pushes on state
/// changes and on a slow timer, never on bytes arriving — a terminal under
/// `yes` would otherwise burn the budget in seconds and then go stale exactly
/// when something interesting happened.
@MainActor
final class SessionActivityCenter {
    static let shared = SessionActivityCenter()

    private var activities: [ObjectIdentifier: Activity<SessionActivityAttributes>] = [:]
    private var lastPush: [ObjectIdentifier: Date] = [:]
    private let log = Logger(subsystem: "dev.conterm.ios", category: "activity")

    /// The floor between throughput-only updates. State changes ignore it.
    private let quietInterval: TimeInterval = 20

    private init() {}

    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(for session: TerminalSession) {
        guard isAvailable else { return }
        let key = ObjectIdentifier(session)
        guard activities[key] == nil else { return }

        let attributes = SessionActivityAttributes(
            hostAlias: session.host.alias,
            target: session.host.displaySubtitle,
            ordinal: session.ordinal,
            startedAt: Date())
        let state = contentState(for: session)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil))
            activities[key] = activity
            lastPush[key] = Date()
        } catch {
            // Not fatal and not worth telling the user: Live Activities can be
            // off system-wide, or the app can be over its concurrent limit.
            log.info("live activity unavailable: \(error.localizedDescription)")
        }
    }

    /// Push a change. `force` for anything that alters the phase, which is
    /// the only thing worth spending the refresh budget on immediately.
    func update(for session: TerminalSession, force: Bool = false) {
        let key = ObjectIdentifier(session)
        guard let activity = activities[key] else { return }
        if !force, let last = lastPush[key],
           Date().timeIntervalSince(last) < quietInterval { return }
        lastPush[key] = Date()

        // `Activity` is not Sendable, so the handle can't cross into the
        // task. Its id is just a string — carry that and look the activity
        // up again on the other side.
        let id = activity.id
        let content = ActivityContent(state: contentState(for: session), staleDate: nil)
        Task { await Self.activity(id)?.update(content) }
    }

    /// End the activity. A session that failed leaves its reason on screen
    /// for a moment — the Island is often where you'll notice a drop at all.
    func end(for session: TerminalSession) {
        let key = ObjectIdentifier(session)
        guard let activity = activities.removeValue(forKey: key) else { return }
        lastPush[key] = nil
        let state = contentState(for: session)
        let lingers: Bool
        switch session.state {
        case .failed, .closed: lingers = true
        case .connecting, .connected: lingers = false
        }
        let id = activity.id
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await Self.activity(id)?.end(
                content, dismissalPolicy: lingers ? .after(.now + 8) : .immediate)
        }
    }

    private static func activity(_ id: String) -> Activity<SessionActivityAttributes>? {
        Activity<SessionActivityAttributes>.activities.first { $0.id == id }
    }

    private func contentState(
        for session: TerminalSession
    ) -> SessionActivityAttributes.ContentState {
        let phase: SessionActivityAttributes.ContentState.Phase
        var detail: String?
        switch session.state {
        case .connecting: phase = .connecting
        case .connected: phase = .connected
        case .failed(let why): phase = .failed; detail = why
        case .closed(let why): phase = .closed; detail = why
        }
        return .init(phase: phase,
                     title: session.title,
                     bytesIn: session.bytesIn,
                     detail: detail)
    }
}
