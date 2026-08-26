import Foundation
import Observation

/// A remote view of Conterm running on a Mac.
///
/// **Why a file over SSH and not a socket.** The obvious design is a small
/// server in the Mac app and a client here. It is also the wrong one: it
/// means a listening port on a laptop, a firewall prompt, an authentication
/// scheme invented from scratch, and a feature that only works on the same
/// network. Publishing a file that this app reads over the SSH connection it
/// already has costs the Mac nothing, adds no attack surface, authenticates
/// by the same key you already trust, and works from anywhere you can reach
/// the machine — including through a jump host.
///
/// The Mac writes `~/.config/conterm/remote-state.json`, beside the
/// `tab-groups.json` it already keeps there. If Conterm isn't running the
/// file is simply stale, and staleness is a fact worth showing rather than
/// an error worth hiding.
struct ContermState: Codable, Sendable {
    /// Bumped when the shape changes incompatibly. A phone newer than the Mac
    /// says so rather than decoding half a file.
    static let supportedVersion = 1

    var version: Int
    var publishedAt: Date
    var hostName: String?
    var appVersion: String?
    var windows: [Window]

    struct Window: Codable, Sendable, Identifiable {
        var index: Int
        var title: String?
        var isKey: Bool
        var tabs: [Tab]

        var id: Int { index }
    }

    struct Tab: Codable, Sendable, Identifiable {
        var index: Int
        var title: String
        var isSelected: Bool
        var groupName: String?
        var groupColorKey: String?
        var panes: [Pane]

        var id: String { "\(index)-\(title)" }
    }

    struct Pane: Codable, Sendable, Identifiable {
        var id: String
        var index: Int
        var title: String?
        var cwd: String?
        var dirLabel: String?
        /// Set when the pane is SSH'd somewhere — a Mac tab that is really a
        /// window onto another machine.
        var remoteHost: String?
        var isActive: Bool
        var agentPhase: String?
        var agentTool: String?
        var agentLabel: String?
    }

    /// How stale this snapshot is. The Mac republishes on a timer, so a
    /// snapshot much older than that cadence means Conterm has quit — which
    /// is exactly what you want to know before you trust what's on screen.
    var age: TimeInterval { Date().timeIntervalSince(publishedAt) }
    var looksLive: Bool { age < 90 }

    var paneCount: Int {
        windows.reduce(0) { $0 + $1.tabs.reduce(0) { $0 + $1.panes.count } }
    }

    var agentsNeedingYou: Int {
        windows.reduce(0) { w, window in
            w + window.tabs.reduce(0) { t, tab in
                t + tab.panes.filter { $0.agentPhase == "attention" }.count
            }
        }
    }
}

/// Reads the Mac's published state over SSH.
@MainActor
@Observable
final class ContermRemoteReader {
    enum Phase: Equatable {
        case loading
        case loaded
        /// Conterm has never published here — either it isn't installed, or
        /// it predates the version that does.
        case notPublishing
        case failed(String)
    }

    private(set) var state: ContermState?
    private(set) var phase: Phase = .loading
    private(set) var refreshing = false

    let address: HostAddress
    private let runner: any HostCommandRunner
    // nonisolated(unsafe): deinit runs outside the actor and must cancel it.
    private nonisolated(unsafe) var poller: Task<Void, Never>?
    private var generation = 0

    /// The path the Mac app writes, and this reads. One constant, two apps.
    static let statePath = "$HOME/.config/conterm/remote-state.json"

    init(address: HostAddress, runner: any HostCommandRunner) {
        self.address = address
        self.runner = runner
    }

    deinit { poller?.cancel() }

    func start(interval: Duration = .seconds(15)) {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func refresh() async {
        generation += 1
        let gen = generation
        if state != nil { refreshing = true }
        defer { if gen == generation { refreshing = false } }

        // The marker makes a missing file distinguishable from an empty
        // reply, a login banner, or a shell that printed something helpful.
        let script = """
        if [ -f "\(Self.statePath)" ]; then
          printf '===conterm:state===\\n'
          cat "\(Self.statePath)"
        else
          printf '===conterm:none===\\n'
        fi
        """

        let raw: String
        do {
            raw = try await runner.runShell(script, on: address)
        } catch {
            guard gen == generation else { return }
            if state == nil { phase = .failed(error.localizedDescription) }
            return
        }
        guard gen == generation else { return }

        if raw.contains("===conterm:none===") {
            phase = .notPublishing
            return
        }
        guard let start = raw.range(of: "===conterm:state===") else {
            if state == nil {
                phase = .failed("The Mac answered, but not with a state file. "
                              + "Check that the login shell is quiet.")
            }
            return
        }

        let json = raw[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let decoded = try? decoder.decode(ContermState.self, from: data) else {
            if state == nil {
                phase = .failed("Couldn't read the state Conterm published. "
                              + "It may be newer than this app.")
            }
            return
        }
        guard decoded.version <= ContermState.supportedVersion else {
            phase = .failed("That Mac is running a newer Conterm than this app "
                          + "understands (format \(decoded.version)).")
            return
        }
        state = decoded
        phase = .loaded
    }
}
