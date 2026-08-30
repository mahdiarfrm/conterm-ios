import SwiftUI

/// A live session: the terminal, the key row, and whatever the connection is
/// currently doing.
struct TerminalScreen: View {
    let session: TerminalSession
    /// Supplied by whoever pushed this screen, so a second shell is opened by
    /// the thing that owns navigation rather than from in here.
    var onNewShell: ((Host) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TerminalView(session: session)
                    .background(Theme.paneTile)

            }
            // Status lives in the terminal's own scrollback, which is the
            // right home for anything you might want to scroll back to. The
            // one exception is what is happening *right now* and will be
            // gone in a second — a connect phase, a retry countdown — which
            // belongs somewhere that clears itself.
            .overlay(alignment: .top) { statusStrip }

            if Self.showDiagnostics { diagnostics }
            KeyAccessoryBar(session: session)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .animation(Theme.Spring.soft, value: session.state)
        .animation(Theme.crossfade, value: session.reconnectingIn)
        .navigationTitle(session.title ?? session.host.alias)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paneTitleBar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Open another shell", systemImage: "plus.rectangle.on.rectangle") {
                        onNewShell?(session.host)
                    }
                    .disabled(onNewShell == nil)
                    Divider()
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

extension TerminalScreen {
    /// A thin line at the top of the terminal, present only while something
    /// is in flight or has gone wrong.
    ///
    /// "connecting…" for eight seconds tells you nothing about what is slow.
    /// On a phone the answer is usually the radio waking up rather than the
    /// host refusing you, and those deserve different amounts of patience.
    @ViewBuilder
    fileprivate var statusStrip: some View {
        switch session.state {
        case .connected:
            EmptyView()
        case .connecting:
            if let seconds = session.reconnectingIn {
                strip("reconnecting in \(seconds)s", tint: Theme.warning, busy: false)
            } else {
                strip(session.phase?.label ?? "connecting", tint: Theme.sshAccent, busy: true)
            }
        case .failed(let why):
            strip(why, tint: Theme.Status.danger, busy: false, retry: true)
        case .closed(let why):
            strip(why ?? "session ended", tint: Theme.Status.neutral, busy: false, retry: true)
        }
    }

    fileprivate func strip(_ text: String,
                           tint: Color,
                           busy: Bool,
                           retry: Bool = false) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.mini).tint(tint)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                    .shadow(color: tint.opacity(0.7), radius: 3)
            }
            Text(text)
                .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if retry {
                Button("Reconnect") { session.reconnect() }
                    .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.sshAccent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 0.5)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
