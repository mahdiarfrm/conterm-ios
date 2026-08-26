import SwiftUI

struct RootView: View {
    @Environment(GhosttyRuntime.self) private var ghostty
    @State private var launching = true

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            if let error = ghostty.startupError {
                StartupFailureView(message: error)
            } else if let app = ghostty.app {
                HostListView(app: app)
            } else {
                ProgressView().tint(Theme.accentOnDark)
            }

            if launching {
                LaunchOverlay { launching = false }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(Theme.crossfade, value: launching)
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
