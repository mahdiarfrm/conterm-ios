import Foundation
import Darwin
import os

typealias SSHChannelID = Int

/// The result of one command run to completion.
struct SSHExecResult: Sendable {
    var output: String
    var errorOutput: String
    var exitStatus: Int32
}

/// Where a connection has got to. Shown live while connecting, because
/// "connecting…" for eight seconds tells you nothing about *what* is slow —
/// and on a phone the answer is usually the radio waking up, which is worth
/// distinguishing from a host that is refusing you.
enum SSHConnectPhase: Sendable {
    case resolving
    case connecting
    case handshaking
    case verifying
    case authenticating
    case ready

    var label: String {
        switch self {
        case .resolving: return "looking up the host"
        case .connecting: return "opening a connection"
        case .handshaking: return "exchanging keys"
        case .verifying: return "checking the host key"
        case .authenticating: return "authenticating"
        case .ready: return "connected"
        }
    }
}

/// A live SSH connection to one host, carrying many channels at once.
///
/// The shape this replaces was one connection per *thing you wanted to do*:
/// the terminal opened one, the host probe opened another, Agent Center a
/// third, the Mac reader a fourth. Each paid a TCP connect, a key exchange
/// and an authentication — the expensive part of SSH, and the part a phone's
/// radio punishes hardest. SSH has multiplexing built in and this uses it:
/// one handshake per host, after which shells, one-shot commands and
/// long-lived watchers are all just channels. A second shell on a host you
/// are already on costs one round trip.
///
/// libssh2 is not thread-safe across concurrent calls on one session, so
/// every call into it happens on this actor. The one thing deliberately kept
/// *off* the actor is the `poll` that waits for the socket. Waiting while
/// holding the lock is what the old transport did, and it meant a keystroke
/// queued behind the wait: up to 200ms of latency per keypress on an idle
/// connection, which is exactly the connection you are typing on. Here the
/// wait happens on a plain dispatch queue and a self-pipe lets a write
/// interrupt it immediately.
actor SSHConnection {
    let address: HostAddress

    private var session: OpaquePointer?
    private var socket: Int32 = -1
    private var channels: [SSHChannelID: Chan] = [:]
    private var nextID: SSHChannelID = 1
    private var pump: Task<Void, Never>?
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var closed = false

    /// The self-pipe. `nonisolated let` so `write` can poke it without
    /// waiting for the actor — the whole point is that it never blocks.
    private nonisolated let wakeRead: Int32
    private nonisolated let wakeWrite: Int32

    /// Fired when the connection itself goes away, as opposed to one channel.
    var onClosed: (@Sendable (String?) -> Void)?

    private let log = Logger(subsystem: "dev.conterm.ios", category: "ssh")

    /// Concurrent so two hosts don't wait on each other's socket.
    private static let pollQueue = DispatchQueue(
        label: "dev.conterm.ssh.poll", attributes: .concurrent)
    private static let blockingQueue = DispatchQueue(
        label: "dev.conterm.ssh.blocking", attributes: .concurrent)

    private static let libraryReady: Bool = { libssh2_init(0) == 0 }()

    init(address: HostAddress) {
        self.address = address
        var fds: [Int32] = [-1, -1]
        // A socketpair rather than a pipe: both ends are sockets, so the
        // same `poll` handles them, and closing either end is symmetric.
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        for fd in fds where fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
        self.wakeRead = fds[0]
        self.wakeWrite = fds[1]
    }

    deinit {
        if wakeRead >= 0 { Darwin.close(wakeRead) }
        if wakeWrite >= 0 { Darwin.close(wakeWrite) }
    }

    var isAlive: Bool { !closed && session != nil }
    var channelCount: Int { channels.count }

    func setOnClosed(_ handler: @escaping @Sendable (String?) -> Void) {
        onClosed = handler
    }

    // MARK: - Connecting

    func connect(_ credentials: SSHCredentials,
                 trust: HostKeyTrust.Policy,
                 onPhase: (@Sendable (SSHConnectPhase) -> Void)? = nil) async throws {
        guard Self.libraryReady else {
            throw SSHError.connectionFailed("libssh2 failed to initialise")
        }
        guard session == nil else { return }

        // Everything up to the host key is blocking work — name resolution,
        // TCP, key exchange — and none of it may run on a cooperative thread,
        // so it goes to a dispatch queue and the actor stays free.
        onPhase?(.resolving)
        let handshake = try await Self.handshake(address: address, onPhase: onPhase)
        self.socket = handshake.socket
        self.session = handshake.session

        onPhase?(.verifying)
        let verdict = await HostKeyTrust.shared.verdict(
            fingerprint: handshake.fingerprint,
            keyType: handshake.keyType,
            for: address,
            policy: trust)

        switch verdict {
        case .trust:
            break
        case .unknown(let fingerprint, _):
            teardown()
            throw SSHError.hostKeyUnknown(fingerprint: fingerprint)
        case .mismatch(let expected, let got):
            teardown()
            throw SSHError.hostKeyMismatch(expected: expected, got: got)
        }

        onPhase?(.authenticating)
        do {
            try await Self.authenticate(credentials, session: handshake.session)
        } catch {
            teardown()
            throw error
        }

        // From here reads and writes interleave across many channels, so both
        // the socket and libssh2 go non-blocking. The old code set only the
        // latter, which left `libssh2_channel_read` free to block inside
        // `recv` on an idle connection and stall every other channel with it.
        _ = fcntl(handshake.socket, F_SETFL,
                  fcntl(handshake.socket, F_GETFL, 0) | O_NONBLOCK)
        libssh2_session_set_blocking(handshake.session, 0)
        // Ask the far end for a reply so a link that has gone away is noticed
        // rather than discovered the next time you type. Phones move between
        // networks and sit behind NATs that drop idle flows in minutes.
        libssh2_keepalive_config(handshake.session, 1, 30)

        closed = false
        startPump()
        onPhase?(.ready)
    }

    private struct Handshaken: @unchecked Sendable {
        let socket: Int32
        let session: OpaquePointer
        let fingerprint: String
        let keyType: String
    }

    private static func handshake(
        address: HostAddress,
        onPhase: (@Sendable (SSHConnectPhase) -> Void)?
    ) async throws -> Handshaken {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                do {
                    onPhase?(.connecting)
                    let socket = try openSocket(host: address.hostname,
                                                port: address.port,
                                                timeout: 12)
                    guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
                        Darwin.close(socket)
                        throw SSHError.connectionFailed("couldn't create an SSH session")
                    }
                    libssh2_session_set_blocking(session, 1)
                    // A wedged key exchange used to hang until the kernel gave
                    // up, which is minutes. Twenty seconds is already generous
                    // for a handshake on a bad cellular link.
                    libssh2_session_set_timeout(session, 20_000)

                    onPhase?(.handshaking)
                    guard libssh2_session_handshake(session, socket) == 0 else {
                        let message = lastError(session)
                        libssh2_session_free(session)
                        Darwin.close(socket)
                        throw SSHError.connectionFailed(message)
                    }

                    let (fingerprint, keyType) = try Self.hostKey(session)
                    continuation.resume(returning: Handshaken(socket: socket,
                                                              session: session,
                                                              fingerprint: fingerprint,
                                                              keyType: keyType))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func hostKey(_ session: OpaquePointer) throws -> (String, String) {
        guard let hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            throw SSHError.connectionFailed("the host offered no key")
        }
        // SHA256 fingerprints are shown base64 and unpadded, the way OpenSSH
        // prints them, so a fingerprint can be compared against `ssh-keyscan`
        // output by eye without converting anything.
        let raw = Data(bytes: hash, count: 32)
        let fingerprint = "SHA256:" + raw.base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        var typeCode: Int32 = 0
        var length: Int = 0
        _ = libssh2_session_hostkey(session, &length, &typeCode)
        let keyType: String
        switch typeCode {
        case LIBSSH2_HOSTKEY_TYPE_RSA: keyType = "ssh-rsa"
        case LIBSSH2_HOSTKEY_TYPE_DSS: keyType = "ssh-dss"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: keyType = "ecdsa-sha2-nistp256"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: keyType = "ecdsa-sha2-nistp384"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: keyType = "ecdsa-sha2-nistp521"
        case LIBSSH2_HOSTKEY_TYPE_ED25519: keyType = "ssh-ed25519"
        default: keyType = "unknown"
        }
        return (fingerprint, keyType)
    }

    private static func authenticate(_ credentials: SSHCredentials,
                                     session: OpaquePointer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                let user = credentials.address.username
                let rc: Int32

                switch credentials.method {
                case .password(let password):
                    rc = user.withCString { u in
                        password.withCString { p in
                            libssh2_userauth_password_ex(session, u, UInt32(strlen(u)),
                                                         p, UInt32(strlen(p)), nil)
                        }
                    }

                case .privateKey(let privateKey, let publicKey, let passphrase):
                    rc = user.withCString { u -> Int32 in
                        privateKey.withCString { priv -> Int32 in
                            let run: (UnsafePointer<CChar>?, Int) -> Int32 = { pub, pubLen in
                                if let passphrase {
                                    return passphrase.withCString { pass in
                                        libssh2_userauth_publickey_frommemory(
                                            session, u, strlen(u),
                                            pub, pubLen,
                                            priv, strlen(priv),
                                            pass)
                                    }
                                }
                                return libssh2_userauth_publickey_frommemory(
                                    session, u, strlen(u),
                                    pub, pubLen,
                                    priv, strlen(priv),
                                    nil)
                            }
                            if let publicKey {
                                return publicKey.withCString { pub in run(pub, strlen(pub)) }
                            }
                            return run(nil, 0)
                        }
                    }
                }

                if rc == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing:
                        SSHError.authenticationFailed(lastError(session)))
                }
            }
        }
    }

    // MARK: - Channels

    /// An interactive shell with a pty.
    func openShell(columns: Int,
                   rows: Int,
                   onOutput: @escaping @Sendable (Data) -> Void,
                   onClosed: @escaping @Sendable (String?) -> Void) async throws -> SSHChannelID {
        let raw = try await openRawChannel()

        // xterm-256color rather than xterm-ghostty: the terminfo entry that
        // matters lives on the *remote* machine, and almost no host has
        // Ghostty's. Conterm reached the same conclusion for its SSH panes.
        let term = "xterm-256color"
        let pty = await retry { [term] in
            term.withCString { t in
                libssh2_channel_request_pty_ex(raw, t, UInt32(strlen(t)),
                                               nil, 0,
                                               Int32(columns), Int32(rows), 0, 0)
            }
        }
        guard pty == 0 else {
            discard(raw)
            throw SSHError.channelFailed("the host refused a pty: \(lastError())")
        }

        let start = await retry {
            "shell".withCString { s in
                libssh2_channel_process_startup(raw, s, 5, nil, 0)
            }
        }
        guard start == 0 else {
            discard(raw)
            throw SSHError.channelFailed(lastError())
        }

        let chan = Chan(id: takeID(), raw: raw, kind: .shell)
        chan.onData = onOutput
        chan.onClosed = onClosed
        channels[chan.id] = chan
        wake()
        return chan.id
    }

    /// Run one command and collect its output.
    ///
    /// This rides the same session as any open shell rather than dialling the
    /// host again, and — because it is just another channel in the pump — it
    /// no longer freezes the terminal for the duration. The old version put
    /// the session back into blocking mode and read to completion while
    /// holding the lock, so a 3-second host probe was a 3-second dead
    /// keyboard.
    func exec(_ command: String, timeout: Duration = .seconds(25)) async throws -> SSHExecResult {
        let raw = try await openRawChannel()
        let rc = await retry {
            command.withCString { c in
                "exec".withCString { e in
                    libssh2_channel_process_startup(raw, e, 4, c, UInt32(strlen(c)))
                }
            }
        }
        guard rc == 0 else {
            discard(raw)
            throw SSHError.channelFailed(lastError())
        }

        let chan = Chan(id: takeID(), raw: raw, kind: .command)
        chan.deadline = Date().addingTimeInterval(
            Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        chan.wantsEOF = true
        channels[chan.id] = chan
        wake()

        return try await withCheckedThrowingContinuation { continuation in
            chan.completion = continuation
        }
    }

    /// Run a command that keeps talking, delivering output as it arrives.
    ///
    /// This is what makes the Mac feel live rather than polled: instead of
    /// reconnecting every few seconds to `cat` a file, one channel stays open
    /// and the far end pushes.
    func execStream(_ command: String,
                    onData: @escaping @Sendable (Data) -> Void,
                    onClosed: @escaping @Sendable (String?) -> Void) async throws -> SSHChannelID {
        let raw = try await openRawChannel()
        let rc = await retry {
            command.withCString { c in
                "exec".withCString { e in
                    libssh2_channel_process_startup(raw, e, 4, c, UInt32(strlen(c)))
                }
            }
        }
        guard rc == 0 else {
            discard(raw)
            throw SSHError.channelFailed(lastError())
        }

        let chan = Chan(id: takeID(), raw: raw, kind: .stream)
        chan.onData = onData
        chan.onClosed = onClosed
        channels[chan.id] = chan
        wake()
        return chan.id
    }

    func write(_ data: Data, to id: SSHChannelID) {
        guard let chan = channels[id], !data.isEmpty else { return }
        chan.outbound.append(data)
        // Poke the poll so the pump picks this up now rather than whenever
        // the socket next has something to say. This is the difference
        // between a keystroke echoing immediately and echoing eventually.
        wake()
    }

    func resize(columns: Int, rows: Int, on id: SSHChannelID) {
        guard let chan = channels[id] else { return }
        _ = libssh2_channel_request_pty_size_ex(chan.raw, Int32(columns), Int32(rows), 0, 0)
    }

    func closeChannel(_ id: SSHChannelID) {
        guard let chan = channels[id] else { return }
        finish(chan, reason: nil)
    }

    // MARK: - The pump

    private func startPump() {
        pump?.cancel()
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch await self.service() {
                case .busy:
                    continue
                case .idle(let params):
                    if await SSHConnection.wait(params) {
                        await self.fail(reason: "the connection dropped")
                        return
                    }
                case .finished:
                    return
                }
            }
        }
    }

    private enum Step {
        case busy
        case idle(PollParams)
        case finished
    }

    private struct PollParams: Sendable {
        var fd: Int32
        var wake: Int32
        var events: Int16
        var timeoutMS: Int32
    }

    private func service() -> Step {
        guard let session, !closed else { return .finished }

        var next: Int32 = 0
        _ = libssh2_keepalive_send(session, &next)

        var busy = false
        // A snapshot, because finishing a channel mutates the dictionary.
        for chan in Array(channels.values) {
            if drain(chan) { busy = true }
            if read(chan) { busy = true }
        }
        reapExpired()

        if closed { return .finished }
        if busy { return .busy }

        let directions = libssh2_session_block_directions(session)
        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 || directions == 0 {
            events |= Int16(POLLIN)
        }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            events |= Int16(POLLOUT)
        }
        // The timeout only has to be short enough to service keepalives and
        // command deadlines; the self-pipe covers everything urgent.
        return .idle(PollParams(fd: socket, wake: wakeRead,
                                events: events, timeoutMS: 1000))
    }

    /// Waits off the actor. Returns true if the socket itself died.
    private static func wait(_ p: PollParams) async -> Bool {
        await withCheckedContinuation { continuation in
            pollQueue.async {
                var fds = [pollfd(fd: p.fd, events: p.events, revents: 0),
                           pollfd(fd: p.wake, events: Int16(POLLIN), revents: 0)]
                let rc = poll(&fds, 2, p.timeoutMS)
                if rc > 0, fds[1].revents & Int16(POLLIN) != 0 {
                    // Drain the pokes; one wakeup covers any number of them.
                    var scratch = [UInt8](repeating: 0, count: 256)
                    while true {
                        let n = scratch.withUnsafeMutableBytes {
                            Darwin.read(p.wake, $0.baseAddress, $0.count)
                        }
                        if n <= 0 { break }
                    }
                }
                let dead = rc > 0 &&
                    fds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
                continuation.resume(returning: dead)
            }
        }
    }

    private nonisolated func wake() {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
    }

    private func drain(_ chan: Chan) -> Bool {
        guard !chan.outbound.isEmpty else {
            // A command's stdin is closed once, after startup, so the far end
            // knows nothing more is coming and can exit.
            if chan.wantsEOF && !chan.sentEOF {
                let rc = libssh2_channel_send_eof(chan.raw)
                if rc != Int32(LIBSSH2_ERROR_EAGAIN) { chan.sentEOF = true }
                return true
            }
            return false
        }

        let written = chan.outbound.withUnsafeBytes { raw -> Int in
            libssh2_channel_write_ex(chan.raw, 0,
                                     raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                     raw.count)
        }
        if written > 0 {
            chan.outbound.removeFirst(written)
            return true
        }
        if written < 0 && written != Int(LIBSSH2_ERROR_EAGAIN) {
            finish(chan, reason: lastError())
            return true
        }
        // EAGAIN: the window is full. The pump will come back to it.
        return false
    }

    private func read(_ chan: Chan) -> Bool {
        var didWork = false
        for stream in [Int32(0), Int32(SSH_EXTENDED_DATA_STDERR)] {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                libssh2_channel_read_ex(chan.raw, stream,
                                        raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                        raw.count)
            }
            if n > 0 {
                didWork = true
                let data = Data(buffer[0..<n])
                switch chan.kind {
                case .command:
                    if stream == 0 { chan.stdout.append(data) } else { chan.stderr.append(data) }
                case .shell, .stream:
                    // A pty merges stderr into stdout, so for a shell the
                    // extended stream never fires; for a stream it might, and
                    // the caller wants it in order with everything else.
                    chan.onData?(data)
                }
                continue
            }
            if n < 0 && n != Int(LIBSSH2_ERROR_EAGAIN) {
                finish(chan, reason: lastError())
                return true
            }
        }

        if libssh2_channel_eof(chan.raw) == 1 {
            // EOF is not the end. The remote sends `exit-status` *after* it
            // and before the channel close, so finishing here loses the exit
            // code — every command looked like it succeeded. Ask for the
            // close and let the pump come back when the reply lands.
            if chan.eofAt == nil { chan.eofAt = Date() }
            let rc = libssh2_channel_close(chan.raw)
            let waited = Date().timeIntervalSince(chan.eofAt ?? Date())
            if rc != Int32(LIBSSH2_ERROR_EAGAIN) || waited > 3 {
                finish(chan, reason: nil)
                return true
            }
            // Deliberately not "busy": a server that is slow to close would
            // otherwise spin the pump flat out until the grace ran out.
            return didWork
        }
        return didWork
    }

    private func reapExpired() {
        let now = Date()
        for chan in Array(channels.values) {
            guard let deadline = chan.deadline, deadline < now else { continue }
            finish(chan, reason: nil, error: SSHError.timedOut)
        }
    }

    private func finish(_ chan: Chan, reason: String?, error: (any Error)? = nil) {
        guard channels.removeValue(forKey: chan.id) != nil else { return }
        let status = libssh2_channel_get_exit_status(chan.raw)
        libssh2_channel_close(chan.raw)
        libssh2_channel_free(chan.raw)

        if let completion = chan.completion {
            chan.completion = nil
            if let error {
                completion.resume(throwing: error)
            } else {
                completion.resume(returning: SSHExecResult(
                    output: String(decoding: chan.stdout, as: UTF8.self),
                    errorOutput: String(decoding: chan.stderr, as: UTF8.self),
                    exitStatus: status))
            }
        }
        chan.onClosed?(reason)
    }

    // MARK: - Teardown

    /// The connection died under us, as opposed to being closed on purpose.
    private func fail(reason: String?) {
        guard !closed else { return }
        shutdown(reason: reason)
    }

    func shutdown(reason: String? = nil) {
        guard !closed else { return }
        closed = true
        pump?.cancel()
        pump = nil

        for chan in Array(channels.values) {
            channels.removeValue(forKey: chan.id)
            if let completion = chan.completion {
                chan.completion = nil
                completion.resume(throwing: SSHError.notConnected)
            }
            libssh2_channel_close(chan.raw)
            libssh2_channel_free(chan.raw)
            chan.onClosed?(reason)
        }

        teardown()
        onClosed?(reason)
    }

    private func teardown() {
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
            self.session = nil
        }
        if socket >= 0 { Darwin.close(socket); socket = -1 }
    }

    // MARK: - Plumbing

    private func takeID() -> SSHChannelID {
        defer { nextID += 1 }
        return nextID
    }

    private func openRawChannel() async throws -> OpaquePointer {
        guard let session, !closed else { throw SSHError.notConnected }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let raw = libssh2_channel_open_ex(
                session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) {
                return raw
            }
            guard libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN else {
                throw SSHError.channelFailed(lastError())
            }
            await breathe()
        }
        throw SSHError.timedOut
    }

    /// Run a libssh2 call that may report EAGAIN, waiting on the socket
    /// between attempts rather than spinning.
    private func retry(_ body: () -> Int32) async -> Int32 {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let rc = body()
            if rc != Int32(LIBSSH2_ERROR_EAGAIN) { return rc }
            await breathe()
        }
        return Int32(LIBSSH2_ERROR_TIMEOUT)
    }

    /// Give the socket a moment, off the actor, so the pump can run.
    private func breathe() async {
        guard let session else { return }
        let directions = libssh2_session_block_directions(session)
        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 || directions == 0 {
            events |= Int16(POLLIN)
        }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            events |= Int16(POLLOUT)
        }
        _ = await Self.wait(PollParams(fd: socket, wake: wakeRead,
                                       events: events, timeoutMS: 40))
    }

    private func discard(_ raw: OpaquePointer) {
        libssh2_channel_close(raw)
        libssh2_channel_free(raw)
    }

    private func lastError() -> String {
        guard let session else { return "not connected" }
        return Self.lastError(session)
    }

    private static func lastError(_ session: OpaquePointer) -> String {
        var buffer: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        let code = libssh2_session_last_error(session, &buffer, &length, 0)
        guard let buffer, length > 0 else { return "error \(code)" }
        return String(cString: buffer)
    }

    /// Resolve and connect, with a deadline.
    ///
    /// `Darwin.connect` on a blocking socket waits for the kernel's own
    /// timeout, which is over a minute — long enough that a mistyped hostname
    /// looks like a hung app. This connects non-blocking and gives each
    /// candidate address its own share of the budget, so a host with a dead
    /// AAAA record still reaches its A record quickly.
    private static func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(ai_flags: 0,
                             ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let head = result else {
            throw SSHError.connectionFailed(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(head) }

        var candidates: [UnsafeMutablePointer<addrinfo>] = []
        var walk: UnsafeMutablePointer<addrinfo>? = head
        while let info = walk { candidates.append(info); walk = info.pointee.ai_next }

        let share = max(timeout / Double(max(candidates.count, 1)), 3)
        var lastError = "no address answered"

        for info in candidates {
            let fd = Darwin.socket(info.pointee.ai_family,
                                   info.pointee.ai_socktype,
                                   info.pointee.ai_protocol)
            guard fd >= 0 else { continue }

            var on: Int32 = 1
            // Without these a dropped link hangs until the kernel gives up,
            // and every keystroke waits on Nagle.
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if rc == 0 {
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            guard errno == EINPROGRESS else {
                lastError = String(cString: strerror(errno))
                Darwin.close(fd)
                continue
            }

            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&poller, 1, Int32(share * 1000))
            if ready > 0 {
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                if soError == 0 {
                    // Back to blocking for the handshake; libssh2 drives that
                    // synchronously and there is nothing to interleave yet.
                    _ = fcntl(fd, F_SETFL, flags)
                    return fd
                }
                lastError = String(cString: strerror(soError))
            } else {
                lastError = ready == 0 ? "timed out" : String(cString: strerror(errno))
            }
            Darwin.close(fd)
        }
        throw SSHError.connectionFailed(lastError)
    }

    // MARK: - Channel state

    private final class Chan {
        enum Kind { case shell, command, stream }

        let id: SSHChannelID
        let raw: OpaquePointer
        let kind: Kind

        var outbound = Data()
        var stdout = Data()
        var stderr = Data()
        var wantsEOF = false
        var sentEOF = false
        /// When the far end stopped talking. The exit status arrives after
        /// this, so the channel is held open briefly to catch it.
        var eofAt: Date?
        var deadline: Date?
        var onData: (@Sendable (Data) -> Void)?
        var onClosed: (@Sendable (String?) -> Void)?
        var completion: CheckedContinuation<SSHExecResult, any Error>?

        init(id: SSHChannelID, raw: OpaquePointer, kind: Kind) {
            self.id = id
            self.raw = raw
            self.kind = kind
        }
    }
}
