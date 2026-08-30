import Foundation
import Observation

/// What we decided about a host key, before a secret is sent.
enum HostKeyVerdict: Sendable {
    case trust
    /// Never seen this host before. Carries the fingerprint to show.
    case unknown(fingerprint: String, keyType: String)
    /// Seen, and it changed. This is what a machine-in-the-middle looks like.
    case mismatch(expected: String, got: String)
}

/// One remembered host key.
struct KnownHost: Codable, Hashable, Sendable, Identifiable {
    var id: String { key }
    /// `hostname:port`, matching what OpenSSH keys `known_hosts` on — the
    /// same machine reached under two names is two entries, deliberately,
    /// because we have no way to know they are the same machine.
    var key: String
    var fingerprint: String
    var keyType: String
    var firstSeen: Date
    var lastSeen: Date

    static func identifier(for address: HostAddress) -> String {
        "\(address.hostname):\(address.port)"
    }
}

/// Trust-on-first-use for host keys.
///
/// Conterm on macOS never needed this: it shelled out to `/usr/bin/ssh`,
/// which has been doing it since 1999. Here nothing does it for us, and the
/// consequence of skipping it is not theoretical — an unverified key means
/// anyone between the phone and the server can offer their own, take the
/// password or a signature to relay, and read the session. On a laptop that
/// is a bad day; on a phone it is café wifi, which is the *default* case.
@Observable
@MainActor
final class KnownHostsStore {
    static let shared = KnownHostsStore()

    private(set) var entries: [String: KnownHost] = [:]
    private let url: URL

    init(filename: String = "known-hosts.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        load()
    }

    func entry(for address: HostAddress) -> KnownHost? {
        entries[KnownHost.identifier(for: address)]
    }

    /// Compare an offered key against what we remember. Pure — deciding what
    /// to *do* about `.unknown` is the caller's business, because a terminal
    /// can ask and a background refresh must not.
    func check(fingerprint: String, keyType: String, for address: HostAddress) -> HostKeyVerdict {
        guard let known = entries[KnownHost.identifier(for: address)] else {
            return .unknown(fingerprint: fingerprint, keyType: keyType)
        }
        guard known.fingerprint == fingerprint else {
            return .mismatch(expected: known.fingerprint, got: fingerprint)
        }
        return .trust
    }

    func remember(fingerprint: String, keyType: String, for address: HostAddress) {
        let key = KnownHost.identifier(for: address)
        if var existing = entries[key], existing.fingerprint == fingerprint {
            existing.lastSeen = Date()
            entries[key] = existing
        } else {
            entries[key] = KnownHost(key: key,
                                     fingerprint: fingerprint,
                                     keyType: keyType,
                                     firstSeen: Date(),
                                     lastSeen: Date())
        }
        save()
    }

    /// Deliberately not reachable from the mismatch wall. A rebuilt server
    /// and an attack are indistinguishable from the phone, so forgetting a
    /// key is something you go and do on purpose, in the host's own editor,
    /// after checking the new fingerprint against the machine some other way.
    func forget(_ address: HostAddress) {
        entries.removeValue(forKey: KnownHost.identifier(for: address))
        save()
    }

    func forget(key: String) {
        entries.removeValue(forKey: key)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: KnownHost].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Bridges the store to the connection, and to the user when there is one to ask.
///
/// Verification is deliberately *opt-out* rather than opt-in. The hole this
/// replaces was not a missing check — the check existed and was correct — it
/// was that installing it was the caller's job and no caller did it. A
/// security control that each new call site has to remember is a security
/// control that will be missing somewhere.
@Observable
@MainActor
final class HostKeyTrust {
    static let shared = HostKeyTrust()

    /// The prompt currently on screen, if any. `RootView` presents it.
    private(set) var pending: Request?

    struct Request: Identifiable {
        let id = UUID()
        let address: HostAddress
        let fingerprint: String
        let keyType: String
        fileprivate let answer: (Bool) -> Void
    }

    /// How a caller wants an unknown key handled.
    enum Policy: Sendable {
        /// Interactive: ask, and wait for the answer. Only for something the
        /// user just initiated and is watching.
        case ask
        /// Background: refuse. A host refresh or a poll must never be able to
        /// put a trust decision on screen — a prompt that appears without a
        /// gesture behind it is a prompt people learn to dismiss.
        case requireKnown
    }

    private init() {}

    func verdict(fingerprint: String,
                 keyType: String,
                 for address: HostAddress,
                 policy: Policy) async -> HostKeyVerdict {
        let verdict = KnownHostsStore.shared.check(
            fingerprint: fingerprint, keyType: keyType, for: address)

        switch verdict {
        case .trust:
            KnownHostsStore.shared.remember(
                fingerprint: fingerprint, keyType: keyType, for: address)
            return .trust
        case .mismatch:
            return verdict
        case .unknown:
            guard policy == .ask else { return verdict }
            let accepted = await ask(fingerprint: fingerprint,
                                     keyType: keyType,
                                     for: address)
            guard accepted else { return verdict }
            KnownHostsStore.shared.remember(
                fingerprint: fingerprint, keyType: keyType, for: address)
            return .trust
        }
    }

    private func ask(fingerprint: String, keyType: String, for address: HostAddress) async -> Bool {
        // One prompt at a time. Two hosts connecting at once would otherwise
        // race for the sheet and one would be lost.
        while pending != nil {
            try? await Task.sleep(for: .milliseconds(120))
        }
        return await withCheckedContinuation { continuation in
            pending = Request(address: address,
                              fingerprint: fingerprint,
                              keyType: keyType) { [weak self] accepted in
                self?.pending = nil
                continuation.resume(returning: accepted)
            }
        }
    }

    func resolve(_ request: Request, trust: Bool) {
        request.answer(trust)
    }
}
