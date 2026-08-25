import Foundation

/// How the app reaches a host. One protocol so the terminal, the host probe
/// and anything else that needs a remote command all go through the same
/// door — and so the transport can be swapped without touching them.
protocol SSHTransport: Actor {
    /// Connect and authenticate. Throws rather than prompting; anything
    /// interactive is resolved by the caller before this is called.
    func connect(_ credentials: SSHCredentials) async throws

    /// Open an interactive shell with a pty of the given size.
    func openShell(columns: Int, rows: Int) async throws

    /// Bytes typed by the user, on their way to the far end.
    func send(_ data: Data) async

    /// Tell the far end the window changed.
    func resize(columns: Int, rows: Int) async

    /// Run one command to completion and return its stdout. Used by the host
    /// probe, which wants a single round trip rather than a session.
    func exec(_ command: String) async throws -> String

    func disconnect() async
}

/// Everything needed to open one connection.
struct SSHCredentials: Sendable {
    var address: HostAddress
    var method: Method

    enum Method: Sendable {
        case password(String)
        /// PEM/OpenSSH private key material, with the public half when we
        /// have it — libssh2 can derive it, but supplying it is faster and
        /// works for more key formats.
        case privateKey(private: String, public: String?, passphrase: String?)
    }
}

enum SSHError: LocalizedError {
    case connectionFailed(String)
    case authenticationFailed(String)
    case channelFailed(String)
    case hostKeyMismatch(expected: String, got: String)
    case hostKeyUnknown(fingerprint: String)
    case timedOut
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "Couldn't connect: \(m)"
        case .authenticationFailed(let m): return "Authentication failed: \(m)"
        case .channelFailed(let m): return "Couldn't open a session: \(m)"
        case .hostKeyMismatch(let expected, let got):
            return """
                The host key changed.

                Expected \(expected)
                Got      \(got)

                This is what a machine-in-the-middle looks like. It is also \
                what a rebuilt server looks like. Do not continue unless you \
                know which.
                """
        case .hostKeyUnknown(let fp):
            return "First connection to this host. Its key fingerprint is \(fp)."
        case .timedOut: return "The host didn't answer in time."
        case .notConnected: return "Not connected."
        }
    }
}
