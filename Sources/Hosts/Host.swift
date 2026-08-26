import Foundation

/// A saved host.
///
/// Conterm on macOS has no equivalent: it derives a list from `~/.ssh/config`
/// and scraped shell history and hands the alias to `/usr/bin/ssh`, which
/// resolves everything else. Here nothing else will do that, so a host is a
/// real record — and secrets never live in it. Those go to the Keychain,
/// referenced by `id`.
struct Host: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var alias: String
    var hostname: String
    var port: Int = 22
    var username: String
    var auth: AuthKind = .password
    /// Which imported key to use, when `auth == .privateKey`. Keys live in
    /// the library so one id_rsa can serve twelve hosts.
    var keyID: UUID?
    /// Group membership, mirroring Conterm's colour-coded tab groups.
    var groupID: UUID?
    /// Learned from a probe, used for the distro mark on the row.
    var distro: String?
    /// When this host was last connected to, for frecency ordering.
    var lastConnectedAt: Date?

    enum AuthKind: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey

        var label: String {
            switch self {
            case .password: return "Password"
            case .privateKey: return "Private key"
            }
        }
    }

    var address: HostAddress {
        HostAddress(hostname: hostname, port: port, username: username, credentialID: id)
    }

    /// `user@host`, with the port only when it isn't the default — a list
    /// where every row says ":22" has spent its width on nothing.
    var displaySubtitle: String {
        var s = "\(username)@\(hostname)"
        if port != 22 { s += ":\(port)" }
        return s
    }

    /// Build a host from an imported ssh_config entry. `User` is often absent
    /// there because ssh falls back to the local username — which on a phone
    /// is meaningless, so the caller has to supply one.
    init(from entry: SSHConfigHost, defaultUsername: String) {
        self.id = UUID()
        self.alias = entry.alias
        self.hostname = entry.hostname ?? entry.alias
        self.port = entry.port ?? 22
        self.username = entry.user ?? defaultUsername
        // An IdentityFile in the config names a key on the machine that wrote
        // it, which is not this one. It is a hint that the host expects a key,
        // not a key we can use.
        self.auth = entry.identityFiles.isEmpty ? .password : .privateKey
    }

    init(alias: String = "",
         hostname: String = "",
         port: Int = 22,
         username: String = "",
         auth: AuthKind = .password) {
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
    }
}

/// Persists hosts as JSON in Application Support, following the shape
/// Conterm uses for its own stores.
@Observable
@MainActor
final class HostStore {
    private(set) var hosts: [Host] = []

    private let url: URL

    init(filename: String = "hosts.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        load()
    }

    func add(_ host: Host) {
        hosts.append(host)
        save()
    }

    func update(_ host: Host) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[i] = host
        save()
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        // A deleted host must not leave its password behind in the Keychain.
        try? KeyStore.shared.delete(for: host.id)
        save()
    }

    func noteConnected(_ host: Host) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[i].lastConnectedAt = Date()
        save()
    }

    /// Merge imported entries, skipping aliases already present so a re-import
    /// updates nothing and duplicates nothing.
    @discardableResult
    func merge(_ entries: [SSHConfigHost], defaultUsername: String) -> Int {
        let existing = Set(hosts.map(\.alias))
        let fresh = entries
            .filter { !existing.contains($0.alias) }
            .map { Host(from: $0, defaultUsername: defaultUsername) }
        hosts.append(contentsOf: fresh)
        save()
        return fresh.count
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Host].self, from: data)
        else { return }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
