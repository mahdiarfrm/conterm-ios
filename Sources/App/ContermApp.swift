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

    init() {
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
    }
}
