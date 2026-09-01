import Foundation
import Observation

/// Start, stop and restart containers on a host.
///
/// Host Overview has always *listed* containers across four runtimes; this is
/// the small step from reading to acting, and it is the one that turns "is
/// that box OK" into "and now it is". Restarting a wedged container is the
/// single most common thing anyone does from a phone.
///
/// **Guarded, because it changes things.** Every other remote call in this app
/// reads. These write, so the runtime name is never taken from a string, the
/// container name is quoted, and a production host asks first.
@Observable
@MainActor
final class ContainerControl {
    enum Action: String, CaseIterable {
        case start, stop, restart

        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .start: return "play.fill"
            case .stop: return "stop.fill"
            case .restart: return "arrow.clockwise"
            }
        }

        /// Restarting something that is serving traffic is a visible outage,
        /// however short. Stopping it is a longer one.
        var isDisruptive: Bool { self != .start }
    }

    private(set) var busy: Set<String> = []
    private(set) var failure: String?

    private let host: Host
    private let credentials: SSHCredentials
    private let runtime: ContainerRuntime

    init(host: Host, credentials: SSHCredentials, runtime: ContainerRuntime) {
        self.host = host
        self.credentials = credentials
        self.runtime = runtime
    }

    /// Whether this host's name looks like production.
    ///
    /// The same single-substring rule Conterm uses on the Mac, and for the
    /// same reason: on a phone the targets are small and one-handed, so a
    /// confirmation is not politeness, it is the only thing between a scroll
    /// and an outage.
    var isProduction: Bool {
        let text = (host.alias + " " + host.hostname).lowercased()
        return ["prod", "production", "live"].contains { text.contains($0) }
    }

    func perform(_ action: Action, on container: String) async {
        guard !busy.contains(container) else { return }
        busy.insert(container)
        failure = nil
        defer { busy.remove(container) }

        // The container name is the only part that comes from the far end, so
        // it is the only part that gets quoted. Single quotes with the
        // embedded-quote escape, rather than trusting that a container name
        // cannot contain one.
        let safe = "'" + container.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "\(runtime.tool) \(action.rawValue) \(safe) 2>&1"

        do {
            let result = try await SSHConnectionPool.shared.withConnection(
                for: host, credentials: credentials, policy: .requireKnown
            ) { connection in
                try await connection.exec(command, timeout: .seconds(45))
            }
            if result.exitStatus != 0 {
                failure = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n").last.map(String.init)
                    ?? "\(action.title) failed."
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    func clearFailure() { failure = nil }
}
