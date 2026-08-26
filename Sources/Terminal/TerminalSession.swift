import Foundation
import SwiftUI
import UIKit
import os

/// One SSH connection wired to one terminal surface.
///
/// This is the join: bytes off the wire go into `SurfaceController.write`,
/// bytes the terminal produces go out through the transport, and a resize on
/// either side is told to the other. Neither half knows about the other.
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
        }
    }

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

    private let transport = Libssh2Transport()
    private let log = Logger(subsystem: "dev.conterm.ios", category: "session")

    init(host: Host, app: Ghostty.App) {
        self.host = host
        self.surfaceView = TerminalSurfaceView(app: app)

        guard let controller = surfaceView.controller else {
            state = .failed("Couldn't create a terminal surface.")
            return
        }

        // Terminal -> wire.
        controller.onWrite = { [transport, weak self] data in
            self?.bytesOut += data.count
            Task { await transport.send(data) }
        }
        // Terminal geometry -> remote pty.
        controller.onResize = { [transport] columns, rows in
            Task { await transport.resize(columns: columns, rows: rows) }
        }
        controller.onTitle = { [weak self] title in
            self?.title = title
        }
    }

    /// Write a line into the terminal itself.
    ///
    /// Status has been living in overlays on top of the surface, which means
    /// a surface that never draws and a connection that never lands look
    /// identical. Putting status *inside* the terminal makes rendering
    /// self-evident: if you can read this, the renderer works.
    func banner(_ text: String, tint: Banner = .dim) {
        surfaceView.controller?.write(Data((tint.prefix + text + "\u{1b}[0m\r\n").utf8))
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
                self?.surfaceView.controller?.scroll(byPixels: 400)
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

    func connect(credentials: SSHCredentials) {
        state = .connecting
        let controller = surfaceView.controller

        banner("Conterm \u{2014} \(host.displaySubtitle)", tint: .accent)
        banner("connecting\u{2026}")

        Task { [transport, weak self] in
            // Wire -> terminal. Set before connecting so nothing that arrives
            // during login is dropped.
            await transport.setOnOutput { data in
                Task { @MainActor in
                    guard let self else { return }
                    self.bytesIn += data.count
                    controller?.write(data)
                    SessionActivityCenter.shared.update(for: self)
                }
            }
            await transport.setOnClosed { reason in
                Task { @MainActor in
                    self?.state = .closed(reason)
                    self?.banner(reason ?? "connection closed", tint: .bad)
                    SoundEffects.shared.play(.disconnect)
                }
            }

            do {
                try await transport.connect(credentials)
                // Open the pty at the size the surface already is, so the
                // remote shell's first prompt is laid out correctly rather
                // than reflowing a beat later.
                let grid: (columns: Int, rows: Int) =
                    await MainActor.run { controller?.gridSize ?? (columns: 80, rows: 24) }
                try await transport.openShell(columns: grid.columns, rows: grid.rows)
                await MainActor.run {
                    self?.state = .connected
                    self?.banner("connected", tint: .good)
                    SoundEffects.shared.play(.notify)
                    Haptics.shared.fire(.success)
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(error.localizedDescription)
                    // Into the terminal as well as the overlay: the overlay
                    // is dismissable and the scrollback is not.
                    self?.banner(error.localizedDescription, tint: .bad)
                    SoundEffects.shared.play(.error)
                    Haptics.shared.fire(.failure)
                }
            }
        }
    }

    func send(_ text: String) {
        surfaceView.controller?.send(text)
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

    func disconnect() {
        Task { [transport] in await transport.disconnect() }
    }
}
