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
                    // Connected but the far end has said nothing and the
                    // grid is empty — that is a real state, and it is not
                    // the same as a broken renderer. Say which.
                    if session.bytesIn == 0 {
                        SessionMessage(title: "Connected",
                                       detail: "Waiting for the first output from \(session.host.hostname).",
                                       tint: Theme.sshAccent)
                    }
                }
            }

            diagnostics
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

extension TerminalScreen {
    /// A single line of truth about the session. Cheap to read, and the
    /// difference between "the app is broken" and "the host is quiet".
    fileprivate var diagnostics: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.surfaceAlive ? Theme.Status.ready : Theme.Status.danger)
                .frame(width: 5, height: 5)
            Text(session.surfaceAlive
                 ? "surface \(session.grid.columns)×\(session.grid.rows)"
                 : "no surface")
            Text("↓\(session.bytesIn)  ↑\(session.bytesOut)")
            Spacer()
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.textSecondary.opacity(0.75))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
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
