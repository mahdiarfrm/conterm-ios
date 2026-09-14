import CryptoKit
import Network
import SwiftUI
import UIKit
import os

/// Pair this phone with a Mac running Conterm, once, on the local network.
///
/// The phone makes an SSH key, sends the public half to the Mac's pairing
/// port, and shows a six-digit code computed from that key. The Mac shows
/// the same code and a person clicks Allow there; the key lands in the
/// Mac's `authorized_keys` and the reply carries the username, the port
/// and the Mac's host key fingerprints. From then on the Mac is a saved
/// host that signs in with the key, here or from anywhere the Mac is
/// reachable, and its host key is trusted on the first connection because
/// the Mac said what it would be.
@MainActor
@Observable
final class MacPairing {
    enum Phase {
        case connecting
        case waiting(code: String)
        case done(Host, sshOn: Bool)
        case failed(String)
    }

    let mac: NearbyMacs.Found
    private(set) var phase: Phase = .connecting
    private var task: Task<Void, Never>?

    init(mac: NearbyMacs.Found) {
        self.mac = mac
    }

    struct Reply: Decodable {
        var ok: Bool
        var error: String?
        var user: String?
        var port: Int?
        var lhost: String?
        var sshOn: Bool?
        var hostKeys: [HostKey]?

        struct HostKey: Decodable {
            var type: String
            var fingerprint: String
        }
    }

    enum Failure: LocalizedError {
        case noPairing, declined(String), unreachable(String), timedOut

        var errorDescription: String? {
            switch self {
            case .noPairing:
                return "That Mac's Conterm is older than pairing. Update it, or add the Mac with a password."
            case .declined(let why):
                return why
            case .unreachable(let why):
                return "Couldn't reach the Mac: \(why)"
            case .timedOut:
                return "The Mac didn't answer. Is Conterm in front over there?"
            }
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    private func run() async {
        guard let port = mac.pairPort else {
            phase = .failed(Failure.noPairing.localizedDescription)
            return
        }
        let comment = "conterm-ios"
        let generated = SSHKeyGen.ed25519(comment: comment)
        phase = .waiting(code: Self.code(for: generated.publicBlob))

        do {
            let request: [String: Any] = ["v": 1, "name": UIDevice.current.name, "key": generated.publicLine]
            let payload = try JSONSerialization.data(withJSONObject: request) + Data([0x0A])
            let answer = try await Self.exchange(payload, host: mac.hostname, port: port)
            let reply = try JSONDecoder().decode(Reply.self, from: answer)
            guard reply.ok else { throw Failure.declined(reply.error ?? "Declined on the Mac.") }

            let key = try KeyLibrary.shared.add(text: generated.privateKey,
                                                name: "\(mac.name) · this iPhone")
            var host = Host(alias: mac.name,
                            hostname: reply.lhost.flatMap { $0.isEmpty ? nil : $0 + ".local" } ?? mac.hostname,
                            port: reply.port ?? 22,
                            username: reply.user ?? mac.username,
                            auth: .privateKey)
            host.keyID = key.id
            host.distro = Distro.macos.rawValue
            HostStore.shared.add(host)
            HostKeyTrust.shared.pretrust(
                (reply.hostKeys ?? []).map { (type: $0.type, fingerprint: $0.fingerprint) },
                for: host.address)
            Haptics.shared.fire(.success)
            phase = .done(host, sshOn: reply.sshOn ?? true)
        } catch is CancellationError {
            phase = .failed("Cancelled.")
        } catch {
            Haptics.shared.fire(.warning)
            phase = .failed(error.localizedDescription)
        }
    }

    /// The same six digits the Mac computes from the key it received.
    static func code(for keyBlob: Data) -> String {
        let bytes = Array(SHA256.hash(data: keyBlob).prefix(4))
        let value = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            % 1_000_000
        let digits = String(format: "%06d", value)
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    /// One line out, one line back, over TCP. Waits as long as a person
    /// needs to read a code and click a button.
    private static func exchange(_ payload: Data, host: String, port: UInt16) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw Failure.noPairing }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The state handler keeps firing after the first answer; the
            // continuation may only be resumed once.
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: Failure.unreachable(error.localizedDescription))
                    }
                case .waiting(let error):
                    if once.claim() {
                        continuation.resume(throwing: Failure.unreachable(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Failure.unreachable(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    try Task.checkCancellation()
                    let (chunk, complete) = try await receive(connection)
                    if let chunk { buffer.append(chunk) }
                    if buffer.contains(0x0A) || complete { break }
                }
                if let newline = buffer.firstIndex(of: 0x0A) { return Data(buffer[..<newline]) }
                return buffer
            }
            group.addTask {
                try await Task.sleep(for: .seconds(240))
                throw Failure.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: Failure.unreachable(error.localizedDescription)) }
                else { continuation.resume(returning: (data, complete)) }
            }
        }
    }
}

/// The pairing, on screen: the code large while the Mac is asked, then
/// what happened.
struct PairSheet: View {
    @State private var pairing: MacPairing
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeRouter.self) private var router

    init(mac: NearbyMacs.Found) {
        _pairing = State(initialValue: MacPairing(mac: mac))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                PanelLabel("Pair with \(pairing.mac.name)", symbol: "laptopcomputer.and.iphone")
                Spacer()
                Button {
                    pairing.cancel()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.ui(13), weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accentSoft))
                }
                .buttonStyle(PressablePill(scale: 0.9))
            }

            switch pairing.phase {
            case .connecting:
                Text("Reaching the Mac…")
                    .font(Theme.font(Theme.ui(22), .bold))
                    .foregroundStyle(Theme.textPrimary)
                ProgressView().tint(Theme.accent)

            case .waiting(let code):
                Text(code)
                    .font(Theme.font(Theme.ui(64), .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .rollUp()
                Text("Conterm on the Mac is showing a code. Click Allow there only if it is this one.")
                    .font(Theme.font(Theme.ui(15), .medium))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Waiting for the Mac")
                        .font(Theme.font(Theme.ui(13), .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }

            case .done(let host, let sshOn):
                Text("Paired")
                    .font(Theme.font(Theme.ui(34), .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .rollUp()
                Text(sshOn
                     ? "\(host.alias) is a host now and signs in with a key this phone made. It works here and from anywhere the Mac is reachable."
                     : "\(host.alias) is a host now, but Remote Login is off on it. System Settings opened there: switch on Remote Login and this works.")
                    .font(Theme.font(Theme.ui(15), .medium))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    Button {
                        dismiss()
                        router.afterDismiss { router.contermOn = host }
                    } label: {
                        Bubble("Open Conterm on \(host.alias)", symbol: "macwindow", lit: true)
                    }
                    .buttonStyle(PressablePill(scale: 0.94))
                    .disabled(!sshOn)
                    Button { dismiss() } label: { Bubble("Done") }
                        .buttonStyle(PressablePill(scale: 0.94))
                }

            case .failed(let why):
                Text("Not paired")
                    .font(Theme.font(Theme.ui(34), .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text(why)
                    .font(Theme.font(Theme.ui(15), .medium))
                    .foregroundStyle(Theme.textSecondary)
                Button { dismiss() } label: { Bubble("Close") }
                    .buttonStyle(PressablePill(scale: 0.94))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .creamSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .animation(Theme.Spring.morph, value: phaseKey)
        .task { pairing.start() }
        .onDisappear { pairing.cancel() }
        // The harness: say how it went, then walk into the Mac.
        .onChange(of: phaseKey) {
            guard ProcessInfo.processInfo.environment["CONTERM_PAIR"] != nil else { return }
            let log = Logger(subsystem: "dev.conterm.ios", category: "tour")
            switch pairing.phase {
            case .waiting(let code): log.notice("tour: pair code \(code, privacy: .public)")
            case .failed(let why): log.notice("tour: pair failed \(why, privacy: .public)")
            case .done(let host, _):
                log.notice("tour: paired")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    dismiss()
                    router.afterDismiss { router.contermOn = host }
                }
            case .connecting: break
            }
        }
    }

    private var phaseKey: String {
        switch pairing.phase {
        case .connecting: return "connecting"
        case .waiting: return "waiting"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// A flag that flips once, from any thread.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
