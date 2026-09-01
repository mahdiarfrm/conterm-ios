import Foundation
import Observation

/// A command you keep having to type.
///
/// The single largest cost of using a terminal on a phone is not the screen,
/// it is the keyboard: `docker compose logs -f --tail=100 web` is thirty-nine
/// characters of punctuation on a surface with no home row. A snippet is that
/// command, saved, one tap away.
///
/// Scoped to a host or global. Most useful commands are about a particular
/// machine — the service that runs there, the compose file's path — and a
/// list mixing every host's commands together is one you stop scrolling.
struct Snippet: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var command: String
    /// nil means it shows on every host.
    var hostID: UUID?
    /// Whether to press Return after typing it. Off for something you want to
    /// edit first — a `rm -rf` with the path left to fill in, or a command
    /// you keep as a starting point rather than a thing to fire.
    var submits: Bool = true
    var lastUsedAt: Date?
    var uses: Int = 0
}

@Observable
@MainActor
final class SnippetStore {
    static let shared = SnippetStore()

    private(set) var snippets: [Snippet] = []
    private let url: URL

    init(filename: String = "snippets.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        load()
        if snippets.isEmpty { snippets = Self.starters; save() }
    }

    /// What a given host should offer, most-used first.
    ///
    /// Frecency would be better and is already in this app for the palette,
    /// but a snippet list is short enough that plain use-count ordering is
    /// indistinguishable — and the one thing that would be visible is a
    /// list that reorders itself while you are looking for something.
    func snippets(for host: Host?) -> [Snippet] {
        let hostID = host?.id
        let mine = snippets.filter { $0.hostID == nil || $0.hostID == hostID }
        return mine.sorted { a, b in
            if a.uses != b.uses { return a.uses > b.uses }
            return a.title < b.title
        }
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[i] = snippet
        save()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func noteUsed(_ snippet: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[i].uses += 1
        snippets[i].lastUsedAt = Date()
        save()
    }

    /// A first list, so the feature is not an empty screen with a plus.
    ///
    /// Every one of these is something you would otherwise type on a phone
    /// keyboard, and none of them changes anything — a starter set that could
    /// restart a service would be a starter set that eventually did.
    private static let starters: [Snippet] = [
        .init(title: "Disk usage", command: "df -h"),
        .init(title: "What's running", command: "ps aux --sort=-%cpu | head -15"),
        .init(title: "Memory", command: "free -h"),
        .init(title: "Listening ports", command: "ss -tlnp 2>/dev/null || netstat -tlnp"),
        .init(title: "Containers", command: "docker ps"),
        .init(title: "Recent errors", command: "journalctl -p err -n 40 --no-pager"),
        .init(title: "Follow syslog", command: "tail -f /var/log/syslog"),
        .init(title: "Uptime and load", command: "uptime"),
    ]

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return }
        snippets = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
