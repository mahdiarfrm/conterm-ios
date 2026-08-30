import Foundation

/// What Conterm knows, in the shape a widget can read it.
///
/// This is the contract between the app and everything that draws outside it
/// — home screen, lock screen, Dynamic Island. It is deliberately a *flat
/// summary* rather than a view of the app's model: a widget process gets a
/// few milliseconds and no network, so everything it needs must already be
/// decided by the time it is written.
///
/// **How a new feature reaches the widgets.** It emits a `Signal`. Every
/// widget size already knows how to draw one, ranked by weight, so a feature
/// that wants a presence on the home screen adds a case to `Signal.Kind` and
/// a line where it is produced — and nothing in the design has to change.
/// That is the whole reason signals are a list of small uniform things rather
/// than a set of named fields.
struct ContermSnapshot: Codable, Sendable, Equatable {
    var updatedAt: Date
    var sessions: [Session]
    var signals: [Signal]
    /// Hosts saved but not currently connected, for the "nothing running"
    /// state to say something more useful than nothing.
    var hostCount: Int

    static let empty = ContermSnapshot(
        updatedAt: .distantPast, sessions: [], signals: [], hostCount: 0)

    struct Session: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var alias: String
        var target: String
        var startedAt: Date
        var phase: Phase
        /// Which shell on this host, shown only when there is more than one.
        var ordinal: Int
        var bytesIn: Int
    }

    enum Phase: String, Codable, Sendable {
        case connecting, connected, closed, failed

        var label: String {
            switch self {
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .closed: return "closed"
            case .failed: return "failed"
            }
        }
    }

    /// Something that wants a moment of your attention.
    struct Signal: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var kind: Kind
        var title: String
        var detail: String?
        var at: Date

        enum Kind: String, Codable, Sendable {
            case agentWaiting
            case hostDown
            case sessionLost
            case note

            /// Higher sorts first. A widget shows the top few, so this is
            /// what decides which ones earn the room.
            var weight: Int {
                switch self {
                case .agentWaiting: return 30
                case .hostDown: return 20
                case .sessionLost: return 10
                case .note: return 0
                }
            }

            var symbol: String {
                switch self {
                case .agentWaiting: return "sparkles"
                case .hostDown: return "exclamationmark.triangle.fill"
                case .sessionLost: return "bolt.horizontal"
                case .note: return "circle.fill"
                }
            }
        }
    }

    var live: [Session] {
        sessions.filter { $0.phase == .connected || $0.phase == .connecting }
    }

    var ranked: [Signal] {
        signals.sorted {
            $0.kind.weight != $1.kind.weight
                ? $0.kind.weight > $1.kind.weight
                : $0.at > $1.at
        }
    }

    /// The one session a small widget should show: the newest live one.
    var headline: Session? {
        live.max { $0.startedAt < $1.startedAt }
    }
}

/// Where the app leaves the snapshot and the widget picks it up.
///
/// A file in a shared container, not `UserDefaults(suiteName:)`: the payload
/// is a document, it is written whole, and an atomic replace means a widget
/// reading mid-write gets the old one rather than half of the new one.
///
/// If the App Group is not configured the store degrades to the app's own
/// container — the app still writes, the widget still runs, and it shows its
/// placeholder rather than crashing or lying.
enum ContermSnapshotStore {
    static let appGroup = "group.dev.conterm.ios"

    static var url: URL? {
        let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory.appendingPathComponent("widget-snapshot.json")
    }

    /// True when the shared container actually exists — i.e. the App Group
    /// capability is in the signed entitlements. Worth knowing, because
    /// without it the widget can only ever show its placeholder.
    static var isShared: Bool {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    static func write(_ snapshot: ContermSnapshot) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> ContermSnapshot {
        guard let url, let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ContermSnapshot.self, from: data)) ?? .empty
    }
}

extension ContermSnapshot {
    /// What the widget gallery and the system's own preview show. Chosen to
    /// exercise the layouts honestly: more sessions than fit, one of them a
    /// second shell, and a signal outranking a quieter one.
    static let preview = ContermSnapshot(
        updatedAt: Date(),
        sessions: [
            .init(id: "1", alias: "sibche-prod", target: "root@sibche-mobin-prod",
                  startedAt: Date().addingTimeInterval(-8_142), phase: .connected,
                  ordinal: 1, bytesIn: 2_431_002),
            .init(id: "2", alias: "sibche-prod", target: "root@sibche-mobin-prod",
                  startedAt: Date().addingTimeInterval(-612), phase: .connected,
                  ordinal: 2, bytesIn: 18_204),
            .init(id: "3", alias: "build-01", target: "ci@build-01.internal",
                  startedAt: Date().addingTimeInterval(-96), phase: .connecting,
                  ordinal: 1, bytesIn: 340),
            .init(id: "4", alias: "orbit", target: "mahdiar@orbit.local",
                  startedAt: Date().addingTimeInterval(-51_233), phase: .connected,
                  ordinal: 1, bytesIn: 88_120),
        ],
        signals: [
            .init(id: "s1", kind: .agentWaiting, title: "Claude needs you",
                  detail: "sibche-prod", at: Date().addingTimeInterval(-40)),
            .init(id: "s2", kind: .hostDown, title: "db-02 not answering",
                  detail: "3m", at: Date().addingTimeInterval(-180)),
        ],
        hostCount: 9)
}
