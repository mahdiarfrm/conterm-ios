import Foundation
import Darwin
import os

/// SSH over libssh2.
///
/// libssh2 is not thread-safe across concurrent calls on one session, so
/// every call into it happens on this actor's executor, and the read pump
/// polls the socket rather than blocking inside libssh2 on another thread.
/// The session is put in non-blocking mode after the handshake for exactly
/// that reason: a blocking `libssh2_channel_read` would pin a thread and
/// deadlock against any write.
actor Libssh2Transport: SSHTransport {

    /// Bytes from the far end. Set before `openShell`.
    var onOutput: (@Sendable (Data) -> Void)?

    /// The connection dropped — remote hangup, network loss, or `exit`.
    var onClosed: (@Sendable (String?) -> Void)?

    /// Decides whether to trust a host key. Called once per connect, before
    /// authentication, so a mismatch is refused before any secret is sent.
    var verifyHostKey: (@Sendable (_ fingerprint: String, _ keyType: String) async -> Bool)?

    private var socket: Int32 = -1
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var pumpTask: Task<Void, Never>?
    private var connected = false

    private static let initialized: Bool = {
        libssh2_init(0) == 0
    }()

    private let log = Logger(subsystem: "dev.conterm.ios", category: "ssh")

    init() {}

    func setOnOutput(_ handler: @escaping @Sendable (Data) -> Void) { onOutput = handler }
    func setOnClosed(_ handler: @escaping @Sendable (String?) -> Void) { onClosed = handler }
    func setVerifyHostKey(_ handler: @escaping @Sendable (String, String) async -> Bool) {
        verifyHostKey = handler
    }

    // MARK: - Connect

    func connect(_ credentials: SSHCredentials) async throws {
        guard Self.initialized else {
            throw SSHError.connectionFailed("libssh2 failed to initialise")
        }
        let address = credentials.address

        socket = try Self.openSocket(host: address.hostname, port: address.port)
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            closeSocket()
            throw SSHError.connectionFailed("couldn't create an SSH session")
        }
        self.session = session

        // Blocking through the handshake and auth: those are request/response
        // exchanges with nothing to interleave, and the non-blocking versions
        // would just be a busy loop around EAGAIN.
        libssh2_session_set_blocking(session, 1)

        guard libssh2_session_handshake(session, socket) == 0 else {
            let message = Self.lastError(session)
            teardown()
            throw SSHError.connectionFailed(message)
        }

        try await verifyHostKey(session: session)
        try authenticate(credentials, session: session)

        connected = true
    }

    private func verifyHostKey(session: OpaquePointer) async throws {
        guard let verify = verifyHostKey else { return }

        guard let hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            teardown()
            throw SSHError.connectionFailed("the host offered no key")
        }
        // SHA256 fingerprints are shown base64 and unpadded, the way OpenSSH
        // prints them, so a user can compare against `ssh-keyscan` output by
        // eye without converting anything.
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

        guard await verify(fingerprint, keyType) else {
            teardown()
            throw SSHError.hostKeyUnknown(fingerprint: fingerprint)
        }
    }

    private func authenticate(_ credentials: SSHCredentials,
                              session: OpaquePointer) throws {
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

        guard rc == 0 else {
            let message = Self.lastError(session)
            teardown()
            throw SSHError.authenticationFailed(message)
        }
    }

    // MARK: - Shell

    func openShell(columns: Int, rows: Int) async throws {
        guard let session, connected else { throw SSHError.notConnected }

        guard let channel = libssh2_channel_open_ex(
            session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            throw SSHError.channelFailed(Self.lastError(session))
        }
        self.channel = channel

        // xterm-256color rather than xterm-ghostty: the terminfo entry that
        // matters lives on the *remote* machine, and almost no host has
        // Ghostty's. Conterm reached the same conclusion for SSH panes and
        // made it the default.
        let term = "xterm-256color"
        let rc = term.withCString { t in
            libssh2_channel_request_pty_ex(channel, t, UInt32(strlen(t)),
                                           nil, 0,
                                           Int32(columns), Int32(rows), 0, 0)
        }
        guard rc == 0 else {
            throw SSHError.channelFailed("the host refused a pty: \(Self.lastError(session))")
        }

        guard "shell".withCString({ s in
            libssh2_channel_process_startup(channel, s, 5, nil, 0)
        }) == 0 else {
            throw SSHError.channelFailed(Self.lastError(session))
        }

        // Everything from here interleaves reads and writes, so the session
        // goes non-blocking and the pump drives it.
        libssh2_session_set_blocking(session, 0)
        startPump()
    }

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.pumpOnce(&buffer)
                switch outcome {
                case .data:
                    continue                       // more may be waiting
                case .idle:
                    // Nothing pending. Wait on the socket rather than
                    // spinning — a terminal is idle almost all the time, and
                    // a busy loop here is a flat battery.
                    await self.waitForReadable(timeoutMS: 200)
                case .closed(let reason):
                    await self.finish(reason: reason)
                    return
                }
            }
        }
    }

    private enum PumpOutcome {
        case data
        case idle
        case closed(String?)
    }

    private func pumpOnce(_ buffer: inout [UInt8]) -> PumpOutcome {
        guard let channel else { return .closed(nil) }

        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            libssh2_channel_read_ex(channel, 0,
                                    raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                    raw.count)
        }

        if n > 0 {
            onOutput?(Data(buffer[0..<n]))
            return .data
        }
        if n == Int(LIBSSH2_ERROR_EAGAIN) { return .idle }
        if n == 0 {
            // Zero means no data *and* not EAGAIN, which for libssh2 means
            // the channel reached EOF.
            return libssh2_channel_eof(channel) == 1 ? .closed(nil) : .idle
        }
        return .closed(session.map { Self.lastError($0) })
    }

    /// Block on the socket, not on libssh2. `libssh2_session_block_directions`
    /// says which way it is waiting, which matters when a rekey means it
    /// wants to *write* before it can give us anything to read.
    private func waitForReadable(timeoutMS: Int32) async {
        guard socket >= 0, let session else { return }
        let directions = libssh2_session_block_directions(session)
        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 || directions == 0 {
            events |= Int16(POLLIN)
        }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            events |= Int16(POLLOUT)
        }
        var fd = pollfd(fd: socket, events: events, revents: 0)
        _ = poll(&fd, 1, timeoutMS)
    }

    // MARK: - Writing

    func send(_ data: Data) {
        guard let channel, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = libssh2_channel_write_ex(channel, 0, ptr, remaining)
                if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    // The window is full. Very rare for keystrokes; possible
                    // for a large paste.
                    continue
                }
                guard written > 0 else {
                    log.error("channel write failed: \(written)")
                    return
                }
                ptr += written
                remaining -= written
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard let channel else { return }
        _ = libssh2_channel_request_pty_size_ex(channel, Int32(columns), Int32(rows), 0, 0)
    }

    // MARK: - Exec

    /// Run one command and collect its stdout. This is the host probe's path:
    /// one round trip, no pty, no shell session left behind.
    func exec(_ command: String) async throws -> String {
        guard let session, connected else { throw SSHError.notConnected }

        libssh2_session_set_blocking(session, 1)
        defer { libssh2_session_set_blocking(session, 0) }

        guard let channel = libssh2_channel_open_ex(
            session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            throw SSHError.channelFailed(Self.lastError(session))
        }
        defer {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
        }

        let rc = command.withCString { c in
            "exec".withCString { e in
                libssh2_channel_process_startup(channel, e, 4, c, UInt32(strlen(c)))
            }
        }
        guard rc == 0 else { throw SSHError.channelFailed(Self.lastError(session)) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                libssh2_channel_read_ex(channel, 0,
                                        raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                        raw.count)
            }
            if n > 0 { output.append(contentsOf: buffer[0..<n]); continue }
            break
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - Teardown

    func disconnect() {
        finish(reason: nil)
    }

    private func finish(reason: String?) {
        guard connected || session != nil else { return }
        connected = false
        pumpTask?.cancel()
        pumpTask = nil
        teardown()
        onClosed?(reason)
    }

    private func teardown() {
        if let channel {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
            self.channel = nil
        }
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION,
                                          "bye", "")
            libssh2_session_free(session)
            self.session = nil
        }
        closeSocket()
    }

    private func closeSocket() {
        if socket >= 0 { Darwin.close(socket); socket = -1 }
    }

    // MARK: - Helpers

    private static func lastError(_ session: OpaquePointer) -> String {
        var buffer: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        let code = libssh2_session_last_error(session, &buffer, &length, 0)
        guard let buffer, length > 0 else { return "error \(code)" }
        return String(cString: buffer)
    }

    /// Resolve and connect a TCP socket. `getaddrinfo` rather than
    /// `Network.framework` because libssh2 wants a raw descriptor, and
    /// bridging an `NWConnection` into one buys nothing here.
    private static func openSocket(host: String, port: Int) throws -> Int32 {
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

        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let info = candidate {
            let fd = Darwin.socket(info.pointee.ai_family,
                                   info.pointee.ai_socktype,
                                   info.pointee.ai_protocol)
            if fd >= 0 {
                // Without this a dropped Wi-Fi link leaves the connection
                // hanging until the kernel's own timeout, which is minutes.
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            candidate = info.pointee.ai_next
        }
        throw SSHError.connectionFailed(String(cString: strerror(errno)))
    }
}
