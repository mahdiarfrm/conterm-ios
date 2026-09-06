import Foundation
import SwiftUI
import UIKit
import os

/// One SSH shell wired to one terminal surface.
///
/// This is the join: bytes off the wire go into `SurfaceController.write`,
/// bytes the terminal produces go out through the connection, and a resize on
/// either side is told to the other. Neither half knows about the other.
///
/// The shell is a *channel* on a connection the pool owns, not a connection of
/// its own. That is what makes a second shell on the same host open instantly,
/// and what lets a host overview refresh without the keyboard going dead for
/// the duration.
@Observable
@MainActor
final class TerminalSession: Identifiable, Hashable {
    nonisolated static func == (a: TerminalSession, b: TerminalSession) -> Bool {
        a === b
    }
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
        case closed(String?)
    }

    let host: Host
    let surfaceView: TerminalSurfaceView

    private(set) var state: State = .connecting {
        didSet {
            guard state != oldValue else { return }
            // A phase change is the only thing worth spending an immediate
            // Live Activity refresh on.
            SessionActivityCenter.shared.update(for: self, force: true)
            WidgetBridge.refresh()
        }
    }

    /// How far the connection has got. "connecting…" for eight seconds says
    /// nothing about what is slow; this does, and on a phone the answer is
    /// usually the radio rather than the host.
    private(set) var phase: SSHConnectPhase?

    /// Set while waiting to try again after a drop, for the overlay to show.
    private(set) var reconnectingIn: Int?

    /// Scrollback search. `searchSelected` is libghostty's index of the
    /// current match, counted from the *end* of the buffer, so the find bar
    /// converts it to something a person would say.
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            searchTotal = 0
            searchSelected = 0
            surfaceView.controller?.search(searchQuery)
        }
    }
    private(set) var searchTotal = 0
    private(set) var searchSelected = 0

    func stepSearch(next: Bool) {
        surfaceView.controller?.navigateSearch(next: next)
    }

    func endSearch() {
        searchQuery = ""
        surfaceView.controller?.endSearch()
    }

    /// When this session was opened. The widgets and the Dynamic Island both
    /// count up from it, drawn by the system, so neither has to be told the
    /// time has passed.
    let startedAt = Date()

    /// Which shell on this host this is, 1-based. Only ever shown when a host
    /// has more than one, because "web-01 #1" on its own is just noise.
    var ordinal = 1
    private(set) var title: String? {
        didSet {
            guard title != oldValue else { return }
            SessionActivityCenter.shared.update(for: self)
        }
    }

    /// Diagnostics. A black terminal can mean the surface failed, the
    /// connection failed, or the far end simply hasn't said anything yet —
    /// three very different problems that look identical without these.
    private(set) var bytesIn = 0
    private(set) var bytesOut = 0
    var surfaceAlive: Bool { surfaceView.controller?.handle != nil }
    var grid: (columns: Int, rows: Int) { surfaceView.controller?.gridSize ?? (0, 0) }
    var renderLayerReport: String { surfaceView.renderLayerReport }
    var bytesWritten: Int { surfaceView.controller?.bytesWritten ?? 0 }

    private var connection: SSHConnection?
    private var channel: SSHChannelID?
    private var credentials: SSHCredentials?
    private var holdsConnection = false
    /// True once the user has closed this on purpose, which is the difference
    /// between "reconnect" and "leave it alone".
    private var userClosed = false
    private var attempt = 0
    private var reconnectTask: Task<Void, Never>?

    /// A drop on a phone is normal — a lift doorway, a handover, a radio
    /// asleep. Giving up after one is wrong; retrying forever on a host that
    /// is genuinely gone is also wrong.
    private let maxAttempts = 5

    private let log = Logger(subsystem: "dev.conterm.ios", category: "session")

    init(host: Host, app: Ghostty.App) {
        self.host = host
        self.surfaceView = TerminalSurfaceView(app: app)

        guard let controller = surfaceView.controller else {
            state = .failed("Couldn't create a terminal surface.")
            return
        }

        // Terminal -> wire.
        controller.onWrite = { [weak self] data in
            self?.sendToRemote(data)
        }
        // Terminal geometry -> remote pty.
        controller.onResize = { [weak self] columns, rows in
            guard let self, let connection = self.connection, let channel = self.channel
            else { return }
            Task { await connection.resize(columns: columns, rows: rows, on: channel) }
        }
        controller.onTitle = { [weak self] title in
            self?.title = title
        }
        controller.onSearchCount = { [weak self] total, selected in
            if let total { self?.searchTotal = total }
            if let selected { self?.searchSelected = selected }
        }
    }

    // MARK: - Banners

    /// Write a line into the terminal itself.
    ///
    /// Status has been living in overlays on top of the surface, which means
    /// a surface that never draws and a connection that never lands look
    /// identical. Putting status *inside* the terminal makes rendering
    /// self-evident: if you can read this, the renderer works.
    func banner(_ text: String, tint: Banner = .dim) {
        surfaceView.controller?.write(Data((tint.prefix + text + "\u{1b}[0m\r\n").utf8))
    }

    /// A full-width rule with a label in it. Used for the one thing a
    /// terminal must never be quiet about: that the shell you are looking at
    /// is not the shell you were looking at a moment ago.
    func rule(_ label: String, tint: Banner = .dim) {
        let width = max(grid.columns, 20)
        let text = " \(label) "
        let dashes = max(width - text.count, 2)
        let left = String(repeating: "\u{2500}", count: dashes / 2)
        let right = String(repeating: "\u{2500}", count: dashes - dashes / 2)
        banner(left + text + right, tint: tint)
    }

    enum Banner {
        case dim, good, bad, accent
        var prefix: String {
            switch self {
            case .dim: return "\u{1b}[2m"
            case .good: return "\u{1b}[32m"
            case .bad: return "\u{1b}[31m"
            case .accent: return "\u{1b}[36m"
            }
        }
    }

    // MARK: - Connecting

    func connect(credentials: SSHCredentials) {
        self.credentials = credentials
        userClosed = false
        attempt = 0

        banner("Conterm \u{2014} \(host.displaySubtitle)", tint: .accent)
        establish(retrying: false)
    }

    private func establish(retrying: Bool) {
        guard let credentials else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectingIn = nil
        state = .connecting
        phase = .resolving

        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await SSHConnectionPool.shared.connection(
                    for: host,
                    credentials: credentials,
                    policy: .ask,
                    onPhase: { step in
                        Task { @MainActor [weak self] in self?.note(step) }
                    })
                self.connection = connection
                self.holdsConnection = true

                // Open the pty at the size the surface already is, so the
                // remote shell's first prompt is laid out correctly rather
                // than reflowing a beat later.
                let grid = self.surfaceView.controller?.gridSize ?? (columns: 80, rows: 24)
                let channel = try await connection.openShell(
                    columns: grid.columns,
                    rows: grid.rows,
                    onOutput: { data in
                        Task { @MainActor [weak self] in self?.receive(data) }
                    },
                    onClosed: { reason in
                        Task { @MainActor [weak self] in self?.shellClosed(reason) }
                    })

                self.channel = channel
                self.phase = .ready
                self.attempt = 0
                self.state = .connected
                if retrying {
                    // Unmistakable, because it has to be: the far end is a
                    // brand new shell. Different directory, no history, none
                    // of what was running before. A quiet reconnect that
                    // looked like the old session would be a trap.
                    self.rule("reconnected \u{00b7} new shell", tint: .accent)
                } else {
                    self.banner("connected", tint: .good)
                }
                SoundEffects.shared.play(.notify)
                Haptics.shared.fire(.success)
            } catch {
                self.phase = nil
                self.releaseConnection()
                self.failed(error)
            }
        }
    }

    private func note(_ step: SSHConnectPhase) {
        guard case .connecting = state else { return }
        phase = step
    }

    private func receive(_ data: Data) {
        bytesIn += data.count
        surfaceView.controller?.write(data)
        SessionActivityCenter.shared.update(for: self)
    }

    private func sendToRemote(_ data: Data) {
        bytesOut += data.count
        guard let connection, let channel else { return }
        Task { await connection.write(data, to: channel) }
    }

    private func failed(_ error: any Error) {
        let text = error.localizedDescription
        state = .failed(text)
        // Into the terminal as well as the overlay: the overlay is
        // dismissable and the scrollback is not.
        banner(text, tint: .bad)
        if case SSHError.hostKeyMismatch = error {
            banner("")
            banner("Nothing was sent to that host \u{2014} not your password, "
                 + "not a signature.", tint: .dim)
            banner("If you rebuilt this machine, forget its key in the host's "
                 + "settings.", tint: .dim)
        }
        SoundEffects.shared.play(.error)
        Haptics.shared.fire(.failure)
    }

    // MARK: - Losing it

    private func shellClosed(_ reason: String?) {
        channel = nil
        releaseConnection()

        if userClosed {
            state = .closed(reason)
            return
        }

        // A shell that exited cleanly is the user typing `exit`, and
        // reconnecting into a fresh one would be obnoxious. A shell that died
        // with a reason is the network, and that is worth retrying.
        guard reason != nil, attempt < maxAttempts else {
            state = .closed(reason)
            banner(reason ?? "connection closed", tint: reason == nil ? .dim : .bad)
            SoundEffects.shared.play(.disconnect)
            return
        }

        attempt += 1
        // 1s, 2s, 4s, 8s, 15s. Fast enough that a doorway costs nothing,
        // slow enough that a genuinely dead host isn't hammered.
        let delay = min(Int(pow(2.0, Double(attempt - 1))), 15)
        state = .connecting
        banner(reason ?? "connection lost", tint: .bad)
        SoundEffects.shared.play(.disconnect)

        reconnectTask = Task { [weak self] in
            for remaining in stride(from: delay, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.reconnectingIn = remaining }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.userClosed else { return }
                self.reconnectingIn = nil
                self.banner("reconnecting\u{2026} (\(self.attempt) of \(self.maxAttempts))")
                self.establish(retrying: true)
            }
        }
    }

    /// Reconnect immediately, skipping whatever is left of the backoff
    /// schedule. Driven by the manual Reconnect action.
    func reconnect() {
        guard credentials != nil else { return }
        userClosed = false
        attempt = 0
        establish(retrying: true)
    }

    private func releaseConnection() {
        guard holdsConnection else { return }
        holdsConnection = false
        connection = nil
        SSHConnectionPool.shared.release(host)
    }

    func disconnect() {
        userClosed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectingIn = nil
        if let connection, let channel {
            Task { await connection.closeChannel(channel) }
        }
        channel = nil
        releaseConnection()
    }

    // MARK: - Input

    /// Paste text. Bracketed, and control bytes stripped — which is correct
    /// for a clipboard and wrong for a keyboard.
    func send(_ text: String) {
        surfaceView.controller?.send(text)
    }

    /// Type text, as a sequence of key events. See `SurfaceController.type`.
    func type(_ text: String) {
        surfaceView.controller?.type(text)
    }

    /// Press a key, as opposed to inserting text. See `TerminalKeyMap.press`
    /// for why the difference matters.
    func press(_ usage: UIKeyboardHIDUsage,
               mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
               text: String? = nil) {
        guard let key = TerminalKeyMap.press(usage, mods: mods, text: text),
              let controller = surfaceView.controller else { return }
        controller.send(key: key)
        var release = key
        release.action = GHOSTTY_ACTION_RELEASE
        controller.send(key: release)
    }

    // MARK: - Diagnostics

    /// Open the surface with no connection at all and write into it.
    ///
    /// This exists to separate two failures that look identical: a renderer
    /// that never draws, and a connection that never lands. If text appears
    /// here, the Ghostty surface and the external termio backend both work
    /// and the problem is the network. Reachable with CONTERM_DEMO=1.
    func runRenderCheck() {
        state = .connected
        banner("Conterm \u{2014} render check", tint: .accent)
        banner("")
        banner("If you can read this, the Ghostty surface is drawing and", tint: .good)
        banner("the external termio backend is carrying bytes.", tint: .good)
        banner("")
        banner("libghostty \(Ghostty.versionString)")
        let g = grid
        banner("grid \(g.columns)\u{00d7}\(g.rows)")
        banner("")
        banner("Typing echoes locally; nothing is connected.")
        banner("")
        // Echo what is typed, so the input path is exercised too.
        surfaceView.controller?.onWrite = { [weak self] data in
            self?.surfaceView.controller?.write(data)
        }

        // Drive one keystroke through the whole loop: ghostty_surface_text
        // -> External.queueWrite -> the write callback on libghostty's IO
        // thread -> back in as output. If this echoes, the input half works
        // too, which no amount of staring at the screen can tell you.
        send("input path ok\r")

        // Scroll direction is easy to get backwards and impossible to eyeball
        // from a screenshot, so the render check proves it: fill the
        // scrollback with numbered lines, drag "down", and read back which
        // ones are on screen. Higher numbers scrolling away means older
        // output came into view, which is what dragging down should do.
        if ProcessInfo.processInfo.environment["CONTERM_SCROLLTEST"] != nil {
            for i in 1...200 { surfaceView.controller?.write(Data("line \(i)\r\n".utf8)) }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                NSLog("CONTERM-DIAG before scroll: \(self?.firstViewportLine ?? "-")")
                self?.surfaceView.controller?.scroll(byPoints: 400)
                try? await Task.sleep(for: .milliseconds(300))
                NSLog("CONTERM-DIAG after drag down: \(self?.firstViewportLine ?? "-")")
            }
        }

        // Exercise the Live Activity from the render check, which is the only
        // way to see the Island without a host to connect to.
        if ProcessInfo.processInfo.environment["CONTERM_ISLAND"] != nil {
            SessionActivityCenter.shared.start(for: self)
            NSLog("CONTERM-DIAG island available=\(SessionActivityCenter.shared.isAvailable)")
        }

        // Report what the emulator and the layer actually hold, a beat later
        // so the display link has had frames to present. This is the probe
        // that found the libxev wakeup bug and it is cheap, so it stays.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.dumpDiagnostics()
        }
    }

    /// The first non-empty line currently on screen.
    var firstViewportLine: String {
        let text = surfaceView.controller?.viewportText ?? ""
        return text.split(separator: "\n").first.map(String.init) ?? "(empty)"
    }

    /// Print what the terminal contains and what the render layer looks like.
    func dumpDiagnostics() {
        let text = surfaceView.controller?.viewportText
        let trimmed = (text ?? "").split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(6).joined(separator: " | ")
        NSLog("CONTERM-DIAG layer: \(renderLayerReport)  \(surfaceView.renderPixelReport)")
        NSLog("CONTERM-DIAG written=\(bytesWritten) grid=\(grid.columns)x\(grid.rows) "
            + "viewport=\(text == nil ? "nil" : "\(text!.count)ch")")
        NSLog("CONTERM-DIAG text: \(trimmed)")
    }
}
