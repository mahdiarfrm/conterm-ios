import Foundation
import os

/// One connection per host, shared by everything that wants to talk to it.
///
/// Before this, opening a host's overview while a shell was already running
/// dialled the same machine a second time — a second TCP connect, a second
/// key exchange, a second authentication — and Agent Center made it a third.
/// The handshake is the slow part of SSH and a phone's radio makes it slower
/// still, so the difference is not academic: on a warm pool, opening a second
/// shell or refreshing an overview costs one round trip instead of five.
///
/// Connections are kept for a grace period after their last user leaves, so
/// closing a session and immediately reopening it feels like it never went
/// away — which, for the length of the grace period, it didn't.
@MainActor
final class SSHConnectionPool {
    static let shared = SSHConnectionPool()

    /// How long a connection with no users survives before it is closed.
    /// Long enough to cover backing out of a session and going straight back
    /// in; short enough that a pocketed phone isn't holding sockets open.
    private let grace: TimeInterval = 90

    private struct Entry {
        var connection: SSHConnection
        var address: HostAddress
        var users: Int
        var idleSince: Date?
        var reaper: Task<Void, Never>?
    }

    private var entries: [UUID: Entry] = [:]
    /// In-flight opens, so two callers racing for the same host share one
    /// handshake rather than starting two and discarding one.
    private var opening: [UUID: Task<SSHConnection, any Error>] = [:]

    private let log = Logger(subsystem: "dev.conterm.ios", category: "ssh.pool")

    private init() {}

    /// Borrow the connection for a host, opening one if needed.
    ///
    /// Every caller that takes one must `release` it, exactly once.
    func connection(for host: Host,
                    credentials: SSHCredentials,
                    policy: HostKeyTrust.Policy,
                    onPhase: (@Sendable (SSHConnectPhase) -> Void)? = nil) async throws -> SSHConnection {
        if let existing = try await reuse(host) {
            onPhase?(.ready)
            return existing
        }

        if let inFlight = opening[host.id] {
            let connection = try await inFlight.value
            retain(host, connection: connection)
            return connection
        }

        let address = host.address
        let bastion = try resolveJump(host)
        let task = Task<SSHConnection, any Error> {
            let connection = SSHConnection(address: address)
            try await connection.connect(credentials, trust: policy,
                                         via: bastion, onPhase: onPhase)
            return connection
        }
        opening[host.id] = task

        do {
            let connection = try await task.value
            opening[host.id] = nil
            await connection.setOnClosed { [weak self] reason in
                Task { @MainActor in self?.forget(host.id, reason: reason) }
            }
            retain(host, connection: connection)
            return connection
        } catch {
            opening[host.id] = nil
            throw error
        }
    }

    /// How a host's `ProxyJump` becomes something connectable.
    ///
    /// A property rather than a reach for `HostStore.shared` inside the pool.
    /// The self-test has to stand a bastion up somehow, and the alternative
    /// was writing a host and a private key into the stores a person actually
    /// uses on their own phone and hoping the cleanup ran.
    var resolveJump: JumpResolver = .savedHosts

    struct JumpResolver: Sendable {
        private let resolve: @MainActor @Sendable (Host) throws -> SSHConnection.Bastion?

        init(_ resolve: @escaping @MainActor @Sendable (Host) throws -> SSHConnection.Bastion?) {
            self.resolve = resolve
        }

        @MainActor
        func callAsFunction(_ host: Host) throws -> SSHConnection.Bastion? {
            try resolve(host)
        }

        /// The real one: a bastion is another host you have saved.
        ///
        /// It has to be, because reaching it needs its own credentials from
        /// the Keychain and its own trusted key, and neither can be conjured
        /// from the `user@host` string a config writes.
        ///
        /// Deliberately loud when it cannot resolve. The field used to be
        /// parsed out of an imported config and then dropped, so a host
        /// behind a bastion was saved looking like any other, dialled
        /// directly, and timed out with nothing on screen connecting the two.
        static let savedHosts = JumpResolver { host in
            guard let jump = host.proxyJump?.trimmingCharacters(in: .whitespaces),
                  !jump.isEmpty else { return nil }
            guard let jumpHost = HostStore.shared.jumpHost(for: host) else {
                throw SSHError.connectionFailed("""
                    \(host.alias) is reached through "\(jump)", which is not a saved host. \
                    Add it as a host of its own, with the key it needs, and try again.
                    """)
            }
            guard jumpHost.id != host.id else {
                throw SSHError.connectionFailed("\(host.alias) is set to jump through itself.")
            }
            guard let credentials = KeyStore.shared.credentials(for: jumpHost) else {
                throw SSHError.connectionFailed(
                    "no saved credentials for \(jumpHost.alias), which \(host.alias) jumps through.")
            }
            return SSHConnection.Bastion(address: jumpHost.address, credentials: credentials)
        }
    }

    private func reuse(_ host: Host) async throws -> SSHConnection? {
        guard let entry = entries[host.id] else { return nil }
        // A host that has been edited to point somewhere else must not keep
        // using the old machine's connection.
        guard entry.address == host.address, await entry.connection.isAlive else {
            await entry.connection.shutdown()
            entries[host.id] = nil
            return nil
        }
        retain(host, connection: entry.connection)
        return entry.connection
    }

    private func retain(_ host: Host, connection: SSHConnection) {
        var entry = entries[host.id] ?? Entry(connection: connection,
                                              address: host.address,
                                              users: 0,
                                              idleSince: nil,
                                              reaper: nil)
        entry.connection = connection
        entry.address = host.address
        entry.users += 1
        entry.idleSince = nil
        entry.reaper?.cancel()
        entry.reaper = nil
        entries[host.id] = entry
    }

    func release(_ host: Host) {
        release(hostID: host.id)
    }

    func release(hostID: UUID) {
        guard var entry = entries[hostID] else { return }
        entry.users = max(0, entry.users - 1)
        guard entry.users == 0 else {
            entries[hostID] = entry
            return
        }
        entry.idleSince = Date()
        entry.reaper = Task { [weak self, grace] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            await self?.reap(hostID)
        }
        entries[hostID] = entry
    }

    private func reap(_ hostID: UUID) async {
        guard let entry = entries[hostID], entry.users == 0 else { return }
        entries[hostID] = nil
        await entry.connection.shutdown()
    }

    private func forget(_ hostID: UUID, reason: String?) {
        guard let entry = entries[hostID] else { return }
        entry.reaper?.cancel()
        entries[hostID] = nil
        log.info("connection to \(entry.address.target) closed: \(reason ?? "no reason")")
    }

    /// Drop anything the system killed while we were suspended.
    ///
    /// iOS does not tell an app that its sockets died in the background; it
    /// simply stops scheduling it, and the far end times out. Checking on
    /// resume means the first thing the user touches reconnects, rather than
    /// hanging on a socket that has been dead for an hour.
    func pruneDead() async {
        for (id, entry) in entries {
            if await entry.connection.isAlive { continue }
            entry.reaper?.cancel()
            entries[id] = nil
        }
    }

    /// Close everything, now. Used when the app is told to.
    func closeAll() async {
        let all = entries.values
        entries.removeAll()
        for entry in all {
            entry.reaper?.cancel()
            await entry.connection.shutdown()
        }
    }
}

extension SSHConnectionPool {
    /// Borrow a connection for the duration of one piece of work and give it
    /// back afterwards, whatever happens. Every leaked retain is a socket
    /// that outlives its usefulness, so the balanced form is the only one
    /// callers outside the terminal should use.
    func withConnection<T: Sendable>(
        for host: Host,
        credentials: SSHCredentials,
        policy: HostKeyTrust.Policy,
        onPhase: (@Sendable (SSHConnectPhase) -> Void)? = nil,
        _ body: @Sendable (SSHConnection) async throws -> T
    ) async throws -> T {
        let connection = try await connection(for: host,
                                              credentials: credentials,
                                              policy: policy,
                                              onPhase: onPhase)
        defer { release(host) }
        return try await body(connection)
    }
}
