import SwiftUI

@main
struct ContermApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var ghostty = GhosttyRuntime()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(ghostty)
                // The terminal is a dark tile whatever the system is doing,
                // and the chrome is built for it. A light-mode phone showing
                // a dark terminal in a light shell reads as two apps.
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            ghostty.scenePhaseChanged(phase)
        }
    }
}

/// Holds the process-wide libghostty app for the lifetime of the scene.
///
/// libghostty is initialised once per process and every surface belongs to
/// one `ghostty_app_t`, so this is deliberately a single long-lived object
/// rather than something a view creates.
@Observable
@MainActor
final class GhosttyRuntime {
    private(set) var app: Ghostty.App?
    private(set) var startupError: String?

    private(set) var ready = false

    init() {}

    /// Build the engine after the first frame.
    ///
    /// Called from the launch overlay, which is on screen while this runs —
    /// so the work is covered rather than staring at nothing. Still on the
    /// main actor, because libghostty wants its app created on the thread
    /// that will tick it; the point is only that it happens *after* SwiftUI
    /// has something to draw.
    func start() {
        guard !ready, startupError == nil else { return }
        defer { ready = true }

        guard let config = Ghostty.Config() else {
            startupError = "Couldn't build a terminal configuration."
            return
        }
        guard let app = Ghostty.App(config: config) else {
            startupError = "Couldn't start the terminal engine."
            return
        }
        self.app = app
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        // Backgrounding parks libghostty's renderer thread. This is the
        // single biggest battery win available: a terminal with a blinking
        // cursor otherwise keeps drawing while the phone is in a pocket.
        app?.setFocus(phase == .active)

        // iOS never tells an app that its sockets died while it was
        // suspended; it simply stops scheduling it and the far end times
        // out. Checking on the way back means the first thing the user
        // touches reconnects, instead of hanging on a socket that has been
        // dead for an hour.
        if phase == .active {
            Task { await SSHConnectionPool.shared.pruneDead() }
        }
    }
}
