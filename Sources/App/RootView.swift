import SwiftUI

struct RootView: View {
    @Environment(GhosttyRuntime.self) private var ghostty
    @State private var launching = Preferences.shared.launchAnimation
    /// Built once, on appear, and held. Built inside the body it was gone
    /// before its own answer arrived — the probe finishes on a task that
    /// holds it weakly — and built in the initialiser it ran before the app
    /// was up.
    @State private var overviewHarness: OverviewHarness.Rig?

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            if !ghostty.ready {
                // Nothing yet — the overlay is covering this.
                Color.clear
            } else if let error = ghostty.startupError {
                StartupFailureView(message: error)
            } else if let app = ghostty.app {
                if ProcessInfo.processInfo.environment["CONTERM_OVERVIEW"] != nil,
                   let harness = overviewHarness {
                    NavigationStack { HostOverviewView(host: harness.host,
                                                       injected: harness.probe) }
                } else if ProcessInfo.processInfo.environment["CONTERM_WIDGETS"] != nil {
                    NavigationStack { WidgetGallery() }
                } else if ProcessInfo.processInfo.environment["CONTERM_DEMO"] == "1" {
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
        .task {
            if ProcessInfo.processInfo.environment["CONTERM_OVERVIEW"] != nil,
               overviewHarness == nil {
                overviewHarness = OverviewHarness.make()
            }
        }
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

/// Points Host Overview at the throwaway test host, so the screen can be
/// looked at without a saved host or a key in the Keychain.
///
/// The same reasoning as the widget gallery: a design you can only see by
/// setting up real data first is a design that stops getting looked at.
enum OverviewHarness {
    struct Rig {
        let host: Host
        let probe: HostProbeModel
    }

    @MainActor
    static func make() -> Rig? {
        let env = ProcessInfo.processInfo.environment
        guard let hostname = env["CONTERM_SSHTEST_HOST"],
              let user = env["CONTERM_SSHTEST_USER"],
              let keyPath = env["CONTERM_SSHTEST_KEY"],
              let key = try? String(contentsOfFile: keyPath, encoding: .utf8)
        else { return nil }

        var host = Host(alias: hostname, hostname: hostname,
                        port: Int(env["CONTERM_SSHTEST_PORT"] ?? "22") ?? 22,
                        username: user, auth: .privateKey)
        host.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000fe")!
        let credentials = SSHCredentials(
            address: host.address,
            method: .privateKey(private: key,
                                public: try? String(contentsOfFile: keyPath + ".pub",
                                                    encoding: .utf8),
                                passphrase: nil))
        // The harness is handed the fingerprint by the script that started
        // the test host, so trust is established the same way it would be by
        // accepting the prompt — rather than by giving the trust store a
        // bypass, which is the sort of thing that escapes into a release.
        if let fingerprint = env["CONTERM_SSHTEST_FINGERPRINT"] {
            KnownHostsStore.shared.remember(fingerprint: fingerprint,
                                            keyType: "ssh-ed25519",
                                            for: host.address)
        }
        let probe = HostProbeModel(
            address: host.address,
            runner: SSHCommandRunner(host: host, credentials: credentials, policy: .ask))
        return Rig(host: host, probe: probe)
    }
}
