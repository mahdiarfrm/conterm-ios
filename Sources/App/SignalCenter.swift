import Foundation
import Observation

/// Everything that wants a moment of your attention, in one place.
///
/// The widgets and the Dynamic Island already know how to draw a
/// `ContermSnapshot.Signal`, ranked, at every size — that was the point of
/// making signals a list of small uniform things rather than a set of named
/// fields. Until now nothing produced one. This is the other half: anything
/// that notices something worth telling you posts it here, and it appears
/// everywhere at once.
///
/// **Why it persists.** A widget is read when the app is closed, which is
/// exactly when nothing is running to notice anything. So the last thing each
/// source said is written to disk and survives until that source contradicts
/// it. A signal is stamped with when it was seen, and the faces show that age
/// — a stale "Claude needs you" is still useful, and pretending otherwise
/// would mean showing nothing at all in the case the widget exists for.
@Observable
@MainActor
final class SignalCenter {
    static let shared = SignalCenter()

    /// Signals by source. Keyed so a source replaces its own set wholesale
    /// rather than appending duplicates every refresh — an agent that has
    /// been waiting for ten minutes is one signal, not thirty.
    private var bySource: [String: [ContermSnapshot.Signal]] = [:]
    private let url: URL

    var all: [ContermSnapshot.Signal] {
        bySource.values.flatMap { $0 }
    }

    init(filename: String = "signals.json") {
        let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ContermSnapshotStore.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(filename)
        load()
    }

    /// Replace everything one source has to say.
    ///
    /// Sources report their whole current picture rather than individual
    /// events, because the interesting transition is usually a signal
    /// *ending* — the agent got its answer — and an append-only log cannot
    /// express that.
    func post(_ signals: [ContermSnapshot.Signal], from source: String) {
        let existing = bySource[source] ?? []
        guard existing != signals else { return }
        if signals.isEmpty {
            bySource.removeValue(forKey: source)
        } else {
            bySource[source] = signals
        }
        save()
        WidgetBridge.refresh()
    }

    func clear(source: String) { post([], from: source) }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        bySource = (try? decoder.decode([String: [ContermSnapshot.Signal]].self,
                                        from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(bySource) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension ContermState {
    /// The agents on this Mac that want something, as signals.
    ///
    /// Only `attention`. An agent that is working does not need you, and a
    /// widget that lights up for every running agent is one you stop reading
    /// — which costs you the one that mattered.
    func agentSignals(machine: String) -> [ContermSnapshot.Signal] {
        windows.flatMap(\.tabs).flatMap(\.panes)
            .filter { $0.agentPhase == "attention" }
            .map { pane in
                ContermSnapshot.Signal(
                    id: "mac.agent.\(pane.id)",
                    kind: .agentWaiting,
                    title: pane.agentLabel ?? "An agent needs you",
                    detail: pane.dirLabel ?? machine,
                    at: publishedAt)
            }
    }
}
