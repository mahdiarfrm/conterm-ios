import Foundation
import SwiftUI
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

    private(set) var state: State = .connecting
    private(set) var title: String?

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
                    self?.bytesIn += data.count
                    controller?.write(data)
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

    func disconnect() {
        Task { [transport] in await transport.disconnect() }
    }
}
