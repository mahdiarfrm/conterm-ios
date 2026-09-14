import SwiftUI

/// A live session: the terminal, the key row, and whatever the connection is
/// currently doing.
///
/// The title is a button. Tapping it drops the shell deck over the
/// terminal: every other shell you have running, one tap from being the
/// one on screen, and a new one on this host. A desktop terminal has tabs
/// for this; a phone has no room for a tab strip, so the strip appears
/// only when asked for.
struct TerminalScreen: View {
    let session: TerminalSession
    /// The same shell, continued in a tab of Conterm on a Mac. Declared
    /// before `onNewShell` so a trailing closure still means a new shell.
    var onHandoff: ((Host) -> Void)?
    /// Another running shell picked from the deck, to take this screen.
    var onSwitch: ((TerminalSession) -> Void)?
    /// Supplied by whoever pushed this screen, so a second shell is opened by
    /// the thing that owns navigation rather than from in here.
    var onNewShell: ((Host) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeRouter.self) private var router: HomeRouter?
    @State private var finding = false
    @State private var showingSnippets = false
    /// The deck, dropped over the terminal.
    @State private var switching = false

    private var others: Int { SessionStore.shared.live.filter { $0 !== session }.count }

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
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    statusStrip
                    if finding { FindBar(session: session, finding: $finding) }
                }
            }
            .overlay(alignment: .top) {
                if switching { switcher }
            }

            if Self.showDiagnostics { diagnostics }
            KeyAccessoryBar(session: session)
        }
        // The terminal's own black, under everything including the
        // keyboard: the keyboard is translucent and shows what is behind
        // it, and the ground's red behind a dark keyboard read as a bug.
        .background(Theme.paneTile.ignoresSafeArea(.all, edges: .all))
        .animation(Theme.Spring.soft, value: session.state)
        .animation(Theme.crossfade, value: session.reconnectingIn)
        .animation(Theme.Spring.snappy, value: finding)
        .animation(Theme.Spring.snappy, value: switching)
        .navigationTitle(session.title ?? session.host.alias)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paneTitleBar, for: .navigationBar)
        .toolbar {
            // The title, as the way to the other shells: the name of this
            // one, and a chevron when there is anywhere else to go.
            ToolbarItem(placement: .principal) {
                Button {
                    Haptics.shared.fire(.light)
                    switching.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(session.title ?? session.host.alias)
                            .font(Theme.font(Theme.ui(15), .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Image(systemName: "chevron.down")
                            .font(.system(size: Theme.ui(9), weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .rotationEffect(.degrees(switching ? 180 : 0))
                    }
                    .frame(maxWidth: 220)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch shell")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Snippets", systemImage: "text.badge.plus") {
                        showingSnippets = true
                    }
                    Button("Find in scrollback", systemImage: "magnifyingglass") {
                        finding = true
                    }
                    if others > 0 {
                        Button("Switch shell", systemImage: "rectangle.stack") {
                            switching = true
                        }
                    }
                    Button("Open another shell", systemImage: "plus.rectangle.on.rectangle") {
                        onNewShell?(session.host)
                    }
                    .disabled(onNewShell == nil || session.isLocalLinux)
                    if let onHandoff, session.host.distro != Distro.macos.rawValue,
                       !session.isLocalLinux, !Handoff.macs.isEmpty {
                        Button("Continue on Mac", systemImage: "macbook.and.iphone") {
                            onHandoff(session.host)
                        }
                    }
                    Divider()
                    Button(session.isLocalLinux ? "Power off" : "Disconnect",
                           systemImage: session.isLocalLinux ? "power" : "bolt.horizontal.circle",
                           role: .destructive) {
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
        // The harness: `router.switcherRequest` toggles the deck.
        .onChange(of: router?.switcherRequest ?? 0) { switching.toggle() }
        .sheet(isPresented: $showingSnippets) {
            SnippetsView(host: session.host) { snippet in
                // Typed, not pasted, and submitted with a real Return — the
                // same path a keyboard takes, so a snippet behaves exactly
                // like having typed it.
                session.type(snippet.command)
                if snippet.submits { session.press(.keyboardReturnOrEnter) }
            }
        }
    }
}

extension TerminalScreen {
    /// The deck over the terminal: the other shells, then the rest of the
    /// screen dimmed, a tap on which puts it away. The keyboard goes down
    /// with it; the cards want the whole width.
    fileprivate var switcher: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { switching = false }
            ShellDeck(mode: .switcher(current: session),
                      onPick: { picked in
                          switching = false
                          guard picked !== session else { return }
                          onSwitch?(picked)
                      },
                      onNew: onNewShell == nil ? nil : {
                          switching = false
                          onNewShell?(session.host)
                      })
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .background(Theme.paneTitleBar)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.stroke).frame(height: 0.5)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        .onAppear { session.surfaceView.dismissKeyboard() }
    }

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
                strip(session.bootPhase ?? session.phase?.label ?? "connecting",
                      tint: Theme.sshAccent, busy: true)
            }
        case .failed(let why):
            strip(why, tint: Theme.Status.danger, busy: false, retry: true)
        case .closed(let why):
            strip(why ?? "session ended", tint: Theme.Status.neutral, busy: false, retry: true)
        }
    }

    /// A capsule floating under the bar, in glass: the gem, what the
    /// connection is doing, and a way to try again when it has stopped.
    fileprivate func strip(_ text: String,
                           tint: Color,
                           busy: Bool,
                           retry: Bool = false) -> some View {
        HStack(spacing: 9) {
            if busy {
                ProgressView().controlSize(.mini).tint(tint)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(Theme.font(Theme.ui(12.5), .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                // "resolving" becomes "authenticating" becomes gone — each
                // phase focuses in over the last rather than flickering.
                .morph(on: text, alignment: .leading)
            if retry {
                Button {
                    Haptics.shared.fire(.light)
                    session.reconnect()
                } label: {
                    Text("Reconnect")
                        .font(Theme.font(Theme.ui(12), .bold))
                        .foregroundStyle(Theme.Brand.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(Theme.Brand.cream))
                }
                .buttonStyle(PressablePill(scale: 0.9))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, retry ? 8 : 16)
        .padding(.vertical, retry ? 6 : 10)
        .floatingGlass()
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.top, 10)
        .transition(.morph)
    }
}

/// Find in the scrollback.
///
/// This drives libghostty's own search engine rather than scraping the
/// viewport, which is the difference between finding a line that scrolled off
/// an hour ago and finding one that happens to still be on screen. Matches
/// are highlighted by the renderer, and stepping one scrolls it into view.
///
/// It sits under the status strip rather than above the keyboard, because on
/// a phone you are usually searching something you are *reading* — the
/// keyboard is down, and a bar that forced it up would cost you half of what
/// you came to look at.
private struct FindBar: View {
    let session: TerminalSession
    @Binding var finding: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.ui(12), weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            TextField("Find in scrollback", text: Binding(
                get: { session.searchQuery },
                set: { session.searchQuery = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: Theme.ui(13), weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { session.stepSearch(next: true) }

            if !session.searchQuery.isEmpty {
                Text(count)
                    .font(Theme.font(Theme.ui(11), .semibold))
                    .foregroundStyle(session.searchTotal == 0 ? Theme.warning
                                                             : Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .rollingDigits(on: count)
            }

            Button { session.stepSearch(next: false) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(session.searchTotal == 0)

            Button { session.stepSearch(next: true) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(session.searchTotal == 0)

            Button {
                session.endSearch()
                finding = false
                session.surfaceView.focusKeyboard()
            } label: {
                Image(systemName: "xmark")
            }
        }
        .font(.system(size: Theme.ui(12), weight: .semibold))
        .foregroundStyle(Theme.accentOnDark)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 0.5)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { focused = true }
    }

    /// libghostty counts the selected match from the end of the buffer, so
    /// the raw number counts *down* as you walk forwards. Nobody describes
    /// the first hit they were shown as "seventeen of seventeen".
    private var count: String {
        guard session.searchTotal > 0 else { return "none" }
        let position = session.searchTotal - session.searchSelected
        return "\(max(position, 1))/\(session.searchTotal)"
    }
}
