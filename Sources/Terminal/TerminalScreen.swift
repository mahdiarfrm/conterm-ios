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
                    EmptyView()
                case .failed, .closed:
                    EmptyView()
                case .connected:
                    // Status lives in the terminal's own scrollback now.
                    EmptyView()
                }
            }

            if Self.showDiagnostics { diagnostics }
            KeyAccessoryBar(session: session)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .animation(Theme.Spring.soft, value: session.state)
        .navigationTitle(session.title ?? session.host.alias)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paneTitleBar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Disconnect", systemImage: "bolt.horizontal.circle", role: .destructive) {
                        SessionStore.shared.close(session)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // Deliberately no `onDisappear { disconnect() }`. Leaving the screen
        // is navigation, not hanging up: the shell keeps running and this
        // host reopens straight back into it. Only the menu above ends one.
        .onAppear {
            session.surfaceView.focusKeyboard()
            IdleTimer.terminalAppeared()
        }
        .onDisappear { IdleTimer.terminalDisappeared() }
    }
}

extension TerminalScreen {
    /// The strip is scaffolding, not product: it earned its keep finding the
    /// libxev wakeup bug and it stays reachable for the next one, but a
    /// working terminal shouldn't wear its instrumentation on screen.
    fileprivate static let showDiagnostics =
        ProcessInfo.processInfo.environment["CONTERM_DEMO"] != nil

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
            Text("w\(session.bytesWritten) ↓\(session.bytesIn) ↑\(session.bytesOut)")
            Text(session.renderLayerReport)
            Spacer()
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(Theme.textSecondary.opacity(0.75))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}
