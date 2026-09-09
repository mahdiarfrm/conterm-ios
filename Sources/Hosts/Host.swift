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
    /// The host to reach this one through, as `ProxyJump` names it: an
    /// alias of another saved host, or `user@host:port` written out. A chain
    /// is not supported, so only the first hop of a comma-separated
    /// `ProxyJump` survives an import.
    var proxyJump: String?
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
        // Only the first hop. A chain is rare and half-applying one would be
        // worse than declining it, since the connection would silently go to
        // the wrong machine.
        self.proxyJump = entry.proxyJump?
            .split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    init(alias: String = "",
         hostname: String = "",
         port: Int = 22,
         username: String = "",
         auth: AuthKind = .password,
         proxyJump: String? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.proxyJump = proxyJump
    }
}

/// Persists hosts as JSON in Application Support, following the shape
/// Conterm uses for its own stores.
@Observable
@MainActor
final class HostStore {
    /// The one the app uses. A second instance would keep its own array and
    /// quietly disagree with the first about what exists.
    static let shared = HostStore()

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

    /// The saved host a `proxyJump` names, if there is one.
    ///
    /// A bastion has to be a host you have saved, because reaching it needs
    /// its own credentials and its own trusted key, and neither can be
    /// invented from the `user@host` string a config writes. Matched on alias
    /// first, since that is what `ProxyJump` almost always carries, then on
    /// hostname for a config that spelled the address out.
    func jumpHost(for host: Host) -> Host? {
        guard let jump = host.proxyJump?.trimmingCharacters(in: .whitespaces),
              !jump.isEmpty else { return nil }
        // `user@host:port` — only the host part can match something saved.
        let withoutUser = jump.contains("@") ? String(jump.split(separator: "@").last!) : jump
        let name = String(withoutUser.split(separator: ":").first ?? "")
        return hosts.first { $0.alias == jump }
            ?? hosts.first { $0.alias == name }
            ?? hosts.first { $0.hostname == name }
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
        // The host count is on every widget face, so it travels with the
        // list rather than waiting for a session to change.
        WidgetBridge.refresh()
    }
}
