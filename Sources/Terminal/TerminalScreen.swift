import SwiftUI

/// A live session: the terminal, the key row, and whatever the connection is
/// currently doing.
struct TerminalScreen: View {
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TerminalView(session: session)
                    .background(Theme.paneTile)

                switch session.state {
                case .connecting:
                    ConnectingOverlay(host: session.host.alias)
                case .failed(let message):
                    SessionMessage(title: "Couldn't connect",
                                   detail: message,
                                   tint: Theme.Status.danger)
                case .closed(let reason):
                    SessionMessage(title: "Disconnected",
                                   detail: reason ?? "The host closed the connection.",
                                   tint: Theme.textSecondary)
                case .connected:
                    EmptyView()
                }
            }

            KeyAccessoryBar(session: session)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .animation(Theme.Spring.soft, value: session.state)
        .navigationTitle(session.title ?? session.host.alias)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paneTitleBar, for: .navigationBar)
        .onDisappear { session.disconnect() }
    }
}

private struct ConnectingOverlay: View {
    let host: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Theme.sshAccent)
            Text("Connecting to \(host)")
                .font(.system(size: Theme.ui(13), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(20)
        .glassPanel(cornerRadius: Theme.panelCorner, shadowRadius: 24, shadowY: 11)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
        .rollUp()
    }
}

private struct SessionMessage: View {
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(detail)
                .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .glassPanel(cornerRadius: Theme.panelCorner, shadowRadius: 24, shadowY: 11)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
        .rollUp()
    }
}
