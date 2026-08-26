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
        controller.onWrite = { [transport] data in
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

    func connect(credentials: SSHCredentials) {
        state = .connecting
        let controller = surfaceView.controller

        Task { [transport, weak self] in
            // Wire -> terminal. Set before connecting so nothing that arrives
            // during login is dropped.
            await transport.setOnOutput { data in
                Task { @MainActor in controller?.write(data) }
            }
            await transport.setOnClosed { reason in
                Task { @MainActor in self?.state = .closed(reason) }
            }

            do {
                try await transport.connect(credentials)
                // Open the pty at the size the surface already is, so the
                // remote shell's first prompt is laid out correctly rather
                // than reflowing a beat later.
                let grid: (columns: Int, rows: Int) =
                    await MainActor.run { controller?.gridSize ?? (columns: 80, rows: 24) }
                try await transport.openShell(columns: grid.columns, rows: grid.rows)
                await MainActor.run { self?.state = .connected }
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
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
