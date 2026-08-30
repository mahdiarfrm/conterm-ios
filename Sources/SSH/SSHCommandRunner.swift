import Foundation

/// Runs one-shot commands over SSH.
///
/// The host probe, Agent Center and the Mac reader all want to say one thing
/// and hear the answer. They used to do it by opening a whole connection each
/// — the shape Conterm on macOS gets for free by shelling out to `ssh host
/// sh`, and the shape that is most expensive on a phone. Now they borrow the
/// host's existing connection from the pool and open a channel on it, so the
/// second and every subsequent command costs a round trip rather than a
/// handshake.
///
/// The trust policy is `requireKnown` on purpose: none of these callers is a
/// gesture the user just made, and a fingerprint prompt that appears on its
/// own, during a background refresh, is a prompt people learn to tap through.
/// Trust is established by opening a terminal, deliberately, once.
struct SSHCommandRunner: HostCommandRunner {
    private let host: Host
    private let credentials: SSHCredentials
    private let timeout: Duration
    private let policy: HostKeyTrust.Policy

    /// Conterm's probe gives a wedged connection 15 seconds before it kills
    /// it. A phone on cellular deserves a little more rope.
    init(host: Host,
         credentials: SSHCredentials,
         timeout: Duration = .seconds(25),
         policy: HostKeyTrust.Policy = .requireKnown) {
        self.host = host
        self.credentials = credentials
        self.timeout = timeout
        self.policy = policy
    }

    func runShell(_ script: String, on address: HostAddress) async throws -> String {
        let timeout = self.timeout
        return try await SSHConnectionPool.shared.withConnection(
            for: host, credentials: credentials, policy: policy
        ) { connection in
            // The collector is a POSIX-sh script handed to the login shell,
            // exactly as the Mac app pipes it to `ssh host sh`.
            try await connection.exec(script, timeout: timeout).output
        }
    }
}
