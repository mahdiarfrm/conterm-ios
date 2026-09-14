import Foundation

/// A shell, handed between the phone and the Mac.
///
/// Both directions use what already exists. The Mac publishes its panes
/// and watches an inbox; a pane that is an `ssh` somewhere carries the
/// host it is on, so the phone can open the same host itself. The other
/// way, the phone asks the Mac for a new tab and types the `ssh` line
/// into it, and the Mac does the connecting with its own keys.
enum Handoff {
    enum Failure: LocalizedError {
        case noCredentials(String)
        case notPublishing(String)
        case noPane(String)

        var errorDescription: String? {
            switch self {
            case .noCredentials(let mac):
                return "\(mac) has no saved password or key yet."
            case .notPublishing(let mac):
                return "Conterm isn't running on \(mac), or it's older than the version that listens."
            case .noPane(let mac):
                return "Asked \(mac) for a tab, but it never said which. Try again with Conterm in front."
            }
        }
    }

    /// The Macs among the saved hosts: the ones with a Conterm to hand to.
    @MainActor
    static var macs: [Host] {
        HostStore.shared.hosts.filter { $0.distro == Distro.macos.rawValue }
    }

    /// The line the Mac types to get where the phone was.
    static func command(for host: Host) -> String {
        var parts = ["ssh"]
        if host.port != 22 { parts += ["-p", "\(host.port)"] }
        if let jump = host.proxyJump?.trimmingCharacters(in: .whitespaces), !jump.isEmpty {
            parts += ["-J", jump]
        }
        parts.append("\(host.username)@\(host.hostname)")
        return parts.joined(separator: " ")
    }

    /// Open a tab on the Mac and put a shell to `target` in it.
    ///
    /// The Mac's inbox takes a pane to type into, and a tab that does not
    /// exist yet has none; so this asks for the tab, waits for the Mac
    /// to publish again, finds the pane that is new, and types there.
    @MainActor
    static func continueOnMac(_ target: Host, via mac: Host) async throws {
        guard let credentials = KeyStore.shared.credentials(for: mac) else {
            throw Failure.noCredentials(mac.alias)
        }
        let runner = SSHCommandRunner(host: mac, credentials: credentials,
                                      timeout: .seconds(20), policy: .ask)
        let before = try await state(runner)
        guard let before else { throw Failure.notPublishing(mac.alias) }
        let known = Set(before.windows.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } })

        try await post(.init(action: .newTab), runner)

        var pane: ContermState.Pane?
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(500))
            guard let now = try await state(runner) else { continue }
            let panes = now.windows.flatMap { $0.tabs.flatMap(\.panes) }
            if let fresh = panes.first(where: { !known.contains($0.id) }) {
                pane = fresh
                break
            }
        }
        guard let pane else { throw Failure.noPane(mac.alias) }

        try await post(.init(action: .sendText, paneID: pane.id,
                             text: command(for: target), submit: true), runner)
    }

    /// The host a Mac pane says it is on, among the saved ones: `user@host`,
    /// a hostname, or an alias, matched on the name and then the user.
    @MainActor
    static func host(matching remote: String) -> Host? {
        let trimmed = remote.trimmingCharacters(in: .whitespaces)
        var user: String?
        var name = trimmed
        if let at = trimmed.lastIndex(of: "@") {
            user = String(trimmed[..<at])
            name = String(trimmed[trimmed.index(after: at)...])
        }
        if let colon = name.lastIndex(of: ":") { name = String(name[..<colon]) }
        let candidates = HostStore.shared.hosts.filter {
            $0.hostname.caseInsensitiveCompare(name) == .orderedSame
                || $0.alias.caseInsensitiveCompare(name) == .orderedSame
        }
        if let user, let exact = candidates.first(where: { $0.username == user }) { return exact }
        return candidates.first
    }

    // MARK: - Plumbing

    private static func state(_ runner: SSHCommandRunner) async throws -> ContermState? {
        let result = try await runner.run("cat \"\(ContermRemoteLink.stateFile)\" 2>/dev/null || true")
        guard !result.data.isEmpty else { return nil }
        return try? ContermRemoteLink.decoder.decode(ContermState.self, from: result.data)
    }

    private static func post(_ command: ContermRemoteLink.Command, _ runner: SSHCommandRunner) async throws {
        guard let script = ContermRemoteLink.inboxScript(for: command) else { return }
        let result = try await runner.run(script)
        guard result.exitStatus == 0 else {
            throw RemoteFileError.failed(SSHFileTransport.message(result.errorOutput,
                                                                  status: result.exitStatus))
        }
    }
}
