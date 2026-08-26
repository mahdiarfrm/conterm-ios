import Foundation

/// Runs one-shot commands over SSH.
///
/// The host probe wants a single round trip, not a session, so this opens a
/// connection, execs, and closes. Conterm on macOS got the same shape for free
/// by shelling out to `ssh host sh` with `BatchMode=yes`; here it is explicit.
actor SSHCommandRunner: HostCommandRunner {
    private let credentials: SSHCredentials
    private let timeout: Duration

    /// Conterm's probe gives a wedged connection 15 seconds before it kills
    /// it. A phone on cellular deserves a little more rope.
    init(credentials: SSHCredentials, timeout: Duration = .seconds(25)) {
        self.credentials = credentials
        self.timeout = timeout
    }

    func runShell(_ script: String, on host: HostAddress) async throws -> String {
        let transport = Libssh2Transport()
        let credentials = self.credentials

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await transport.connect(credentials)
                defer { Task { await transport.disconnect() } }
                // The collector is a POSIX-sh script fed to a shell, exactly
                // as the Mac app pipes it to `ssh host sh` over stdin.
                return try await transport.exec(script)
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw SSHError.timedOut
            }

            guard let first = try await group.next() else { throw SSHError.timedOut }
            group.cancelAll()
            return first
        }
    }
}
