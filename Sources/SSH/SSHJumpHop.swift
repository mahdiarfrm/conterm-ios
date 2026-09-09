import Foundation
import os

/// One `ProxyJump` hop: a whole SSH session to the bastion, carrying a single
/// `direct-tcpip` channel to the real target.
///
/// libssh2 talks to a socket. To reach a host that is only reachable through
/// another one, the second session has to be given a different transport, and
/// the only door libssh2 offers is `LIBSSH2_CALLBACK_SEND` / `_RECV` — two
/// synchronous C functions it calls instead of `send` and `recv`. Those
/// callbacks read and write the channel opened here.
///
/// The hop is owned outright by the connection that opened it and is touched
/// from exactly one thread: the target's pump. That is the whole reason it is
/// not an `SSHConnection` reused from the pool. A shared bastion would be two
/// pumps on one libssh2 session, and libssh2 sessions are not thread-safe, so
/// it would need a lock around every call on both sides. `ssh` opens a fresh
/// bastion connection per target too, unless you ask it for a control master.
final class SSHJumpHop: @unchecked Sendable {

    /// The bastion's own socket. The target session polls this, because it is
    /// where the bytes physically arrive.
    let socket: Int32
    private let session: OpaquePointer
    private let channel: OpaquePointer
    private var torn = false

    private static let log = Logger(subsystem: "dev.conterm.ios", category: "ssh.jump")

    private init(socket: Int32, session: OpaquePointer, channel: OpaquePointer) {
        self.socket = socket
        self.session = session
        self.channel = channel
    }

    /// A bastion that has finished its key exchange and is waiting to be
    /// judged. Split in two because the trust decision is asynchronous and
    /// the handshake is not: the fingerprint only exists after the exchange,
    /// and asking the user about it cannot happen on the blocking queue.
    struct Pending: @unchecked Sendable {
        let socket: Int32
        let session: OpaquePointer
        let fingerprint: String
        let keyType: String

        func discard() {
            libssh2_session_free(session)
            Darwin.close(socket)
        }
    }

    /// Dial the bastion and exchange keys. Blocking, and meant to be: the
    /// caller runs it on the same queue it runs its own handshake on.
    static func handshake(bastion: HostAddress) throws -> Pending {
        let socket = try SSHConnection.openSocket(host: bastion.hostname,
                                                  port: bastion.port,
                                                  timeout: 12)
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            Darwin.close(socket)
            throw SSHError.connectionFailed("couldn't create a session for \(bastion.hostname)")
        }
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 20_000)

        guard libssh2_session_handshake(session, socket) == 0 else {
            let message = SSHConnection.lastError(session)
            libssh2_session_free(session)
            Darwin.close(socket)
            throw SSHError.connectionFailed("\(bastion.hostname): \(message)")
        }

        do {
            let (fingerprint, keyType) = try SSHConnection.hostKey(session)
            return Pending(socket: socket, session: session,
                           fingerprint: fingerprint, keyType: keyType)
        } catch {
            libssh2_session_free(session)
            Darwin.close(socket)
            throw error
        }
    }

    /// Authenticate to a trusted bastion and open the channel to the target.
    ///
    /// The bastion is authenticated exactly like any other host, because it
    /// is one. A jump host whose key went unchecked would be the ideal place
    /// to sit and read everything behind it.
    static func finish(_ pending: Pending,
                       credentials: SSHCredentials,
                       bastion: HostAddress,
                       target: HostAddress) throws -> SSHJumpHop {
        let session = pending.session
        let socket = pending.socket

        func abandon(_ error: any Error) -> any Error {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
            Darwin.close(socket)
            return error
        }

        do {
            try SSHConnection.authenticateNow(credentials, session: session)
        } catch {
            throw abandon(error)
        }

        // The originator address is required by the protocol and ignored by
        // every server anyone runs; ssh sends a loopback for the same reason.
        guard let channel = libssh2_channel_direct_tcpip_ex(
            session, target.hostname, Int32(target.port), "127.0.0.1", 22)
        else {
            let message = SSHConnection.lastError(session)
            throw abandon(SSHError.connectionFailed(
                "\(bastion.hostname) would not open a route to \(target.hostname): \(message)"))
        }

        // Non-blocking from here: the target session's callbacks have to be
        // able to report "nothing yet" rather than parking the pump inside a
        // read that cannot complete.
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL, 0) | O_NONBLOCK)
        libssh2_session_set_blocking(session, 0)

        Self.log.info("""
            jump \(bastion.hostname, privacy: .public) → \
            \(target.hostname, privacy: .public) open
            """)
        return SSHJumpHop(socket: socket, session: session, channel: channel)
    }

    /// Install this hop as a session's transport.
    ///
    /// After this the session never touches its file descriptor: every byte
    /// goes through `send` and `recv` below. The descriptor still has to be a
    /// real one, because libssh2 stores it and the pump polls it.
    ///
    /// The hop reaches the callbacks through the session's abstract pointer,
    /// unretained: the connection that opened the hop owns it and outlives
    /// the session that reads through it.
    func attach(to session: OpaquePointer) {
        libssh2_session_abstract(session)?.pointee =
            Unmanaged.passUnretained(self).toOpaque()
        _ = libssh2_session_callback_set2(
            session, LIBSSH2_CALLBACK_SEND,
            unsafeBitCast(jumpSend, to: (@convention(c) () -> Void).self))
        _ = libssh2_session_callback_set2(
            session, LIBSSH2_CALLBACK_RECV,
            unsafeBitCast(jumpRecv, to: (@convention(c) () -> Void).self))
    }

    // MARK: - Transport

    /// Write to the bastion channel. Returns bytes written, or `-EAGAIN` when
    /// the channel's window is closed, which libssh2 understands and retries.
    func send(_ buffer: UnsafeRawPointer, _ length: Int) -> Int {
        guard !torn else { return Int(LIBSSH2_ERROR_SOCKET_SEND) }
        let written = libssh2_channel_write_ex(
            channel, 0, buffer.assumingMemoryBound(to: CChar.self), length)
        if written == Int(LIBSSH2_ERROR_EAGAIN) { return -Int(EAGAIN) }
        if written < 0 { return Int(LIBSSH2_ERROR_SOCKET_SEND) }
        return written
    }

    /// Read from the bastion channel.
    ///
    /// A zero-length read on a live channel means "nothing yet", not "closed",
    /// and returning 0 would tell libssh2 the peer hung up. Only
    /// `channel_eof` says that.
    func recv(_ buffer: UnsafeMutableRawPointer, _ length: Int) -> Int {
        guard !torn else { return Int(LIBSSH2_ERROR_SOCKET_RECV) }
        let read = libssh2_channel_read_ex(
            channel, 0, buffer.assumingMemoryBound(to: CChar.self), length)
        if read == Int(LIBSSH2_ERROR_EAGAIN) { return -Int(EAGAIN) }
        if read < 0 { return Int(LIBSSH2_ERROR_SOCKET_RECV) }
        if read == 0 {
            return libssh2_channel_eof(channel) == 1 ? 0 : -Int(EAGAIN)
        }
        return read
    }

    func close() {
        guard !torn else { return }
        torn = true
        libssh2_channel_free(channel)
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
        libssh2_session_free(session)
        Darwin.close(socket)
    }
}

private typealias JumpSendFn = @convention(c) (
    libssh2_socket_t, UnsafeRawPointer?, Int, Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int
private typealias JumpRecvFn = @convention(c) (
    libssh2_socket_t, UnsafeMutableRawPointer?, Int, Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int

/// libssh2 passes `void **abstract`, the session's own slot, so one
/// dereference gets back what `attach` put there.
private func hop(from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?)
    -> SSHJumpHop? {
    guard let context = abstract?.pointee else { return nil }
    return Unmanaged<SSHJumpHop>.fromOpaque(context).takeUnretainedValue()
}

private let jumpSend: JumpSendFn = { _, buffer, length, _, abstract in
    guard let hop = hop(from: abstract), let buffer else {
        return Int(LIBSSH2_ERROR_SOCKET_SEND)
    }
    return hop.send(buffer, length)
}

private let jumpRecv: JumpRecvFn = { _, buffer, length, _, abstract in
    guard let hop = hop(from: abstract), let buffer else {
        return Int(LIBSSH2_ERROR_SOCKET_RECV)
    }
    return hop.recv(buffer, length)
}
