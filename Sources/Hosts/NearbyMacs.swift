import Foundation
import Network
import Observation

/// Macs on this network running Conterm.
///
/// The companion's best feature — seeing your Mac's sessions and answering
/// the agents in them — was unreachable, because it needs the Mac's address
/// and getting it there meant typing a hostname into a form for a feature you
/// have not seen yet. The Mac advertises `_conterm._tcp` now; this finds it.
///
/// It browses only while the host list is on screen. A discovery browser is a
/// multicast listener, and one held open in the background is a slow leak of
/// battery for something nobody is looking at.
@Observable
@MainActor
final class NearbyMacs {
    struct Found: Identifiable, Equatable {
        var id: String { name }
        /// The Bonjour instance name, which is the Mac's sharing name.
        var name: String
        /// `something.local`, which is what actually resolves.
        var hostname: String
        var username: String
        var appVersion: String?
        /// Whether the Mac says sshd is accepting connections. When it isn't,
        /// the row explains rather than offering a host that will refuse.
        var sshEnabled: Bool
    }

    private(set) var found: [Found] = []
    /// Set when the local-network permission has been refused, which is
    /// otherwise indistinguishable from "no Macs here".
    private(set) var denied = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_conterm._tcp", domain: nil),
            using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .waiting(let error) = state {
                    // `NWError.dns(-65555)` is the local-network prompt being
                    // refused. Anything else is transient.
                    self?.denied = "\(error)".contains("PolicyDenied")
                }
                if case .ready = state { self?.denied = false }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.absorb(results) }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for resolver in resolvers.values { resolver.cancel() }
        resolvers.removeAll()
    }

    private func absorb(_ results: Set<NWBrowser.Result>) {
        var seen: [Found] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var record: [String: String] = [:]
            if case .bonjour(let txt) = result.metadata {
                for key in ["user", "host", "ssh", "version"] {
                    if let value = txt.getEntry(for: key),
                       case .string(let string) = value {
                        record[key] = string
                    }
                }
            }
            seen.append(Found(
                name: record["host"] ?? name,
                // Bonjour instance names map to `<name>.local` for the A
                // record, with spaces as hyphens — the same name Sharing shows
                // under "local hostname".
                hostname: name.replacingOccurrences(of: " ", with: "-") + ".local",
                username: record["user"] ?? "",
                appVersion: record["version"],
                sshEnabled: record["ssh"] != "off"))
        }
        found = seen.sorted { $0.name < $1.name }
    }
}
