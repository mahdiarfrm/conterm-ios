import SwiftUI

struct RootView: View {
    @Environment(GhosttyRuntime.self) private var ghostty
    @State private var launching = Preferences.shared.launchAnimation

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            if !ghostty.ready {
                // Nothing yet — the overlay is covering this.
                Color.clear
            } else if let error = ghostty.startupError {
                StartupFailureView(message: error)
            } else if let app = ghostty.app {
                if ProcessInfo.processInfo.environment["CONTERM_DEMO"] == "1" {
                    RenderCheckScreen(app: app)
                } else {
                    HostListView(app: app)
                }
            } else {
                ProgressView().tint(Theme.accentOnDark)
            }

            if launching {
                LaunchOverlay(
                    // Build the engine while the animation plays, one runloop
                    // in, so the overlay is actually on screen first.
                    onAppear: { ghostty.start() },
                    onFinish: { launching = false })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(Theme.crossfade, value: launching)
        // At the root, because a connection can be started from the host
        // list, the palette or a session, and the prompt has to outlive any
        // of those being dismissed underneath it.
        .hostKeyPrompts()
        // The overlay normally starts the engine, one runloop in, so it is
        // actually on screen first. With the animation turned off there is
        // no overlay to do it — `start()` is idempotent, so both paths can
        // call it.
        .task { if !launching { ghostty.start() } }
        // Exercises the SSH layer against a real server and logs PASS/FAIL.
        // Off unless asked for; see SSHSelfTest.
        .task {
            guard SSHSelfTest.isRequested else { return }
            // The terminal half needs a live engine, which the launch
            // overlay is still building when this task starts.
            while ghostty.app == nil { try? await Task.sleep(for: .milliseconds(100)) }
            await SSHSelfTest.run(app: ghostty.app)
        }
    }
}

/// Shown when libghostty itself won't start. Rare, and always a build
/// problem rather than a user problem — so it says so, instead of offering
/// a retry that cannot work.
private struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.Status.danger)
            Text("The terminal engine didn't start")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("libghostty \(Ghostty.versionString)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(28)
        .glassPanel(cornerRadius: Theme.sheetCorner)
        .padding(32)
    }
}


/// Standalone surface with no networking, for proving the renderer works.
private struct RenderCheckScreen: View {
    let app: Ghostty.App
    @State private var session: TerminalSession?

    var body: some View {
        Group {
            if let session {
                TerminalScreen(session: session)
            } else {
                Color.clear
            }
        }
        .task {
            guard session == nil else { return }
            let host = Host(alias: "render-check", hostname: "localhost",
                            username: "none")
            let s = TerminalSession(host: host, app: app)
            session = s
            // One runloop, so the surface is mounted and sized before we
            // write into it — otherwise the grid is still 0x0.
            try? await Task.sleep(for: .milliseconds(120))
            s.runRenderCheck()
        }
    }
}
