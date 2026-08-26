import Foundation
import Observation

/// One agent running on a remote host.
struct RemoteAgent: Identifiable, Sendable {
    /// The transcript path, which is also Claude Code's session identity.
    var id: String
    var projectDir: String
    var model: String?
    var branch: String?
    var task: String?
    var lastActivity: Date?
    var lastKind: String = ""
    /// The agent's real working directory, when the transcript reported it.
    var cwd: String?
    var turns = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreateTokens = 0
    var cacheReadTokens = 0

    /// Cache reads are excluded on purpose. A long session re-reads the same
    /// context every turn, so counting them makes the number balloon into
    /// meaninglessness — while cost still bills them, below.
    var totalTokens: Int { inputTokens + outputTokens + cacheCreateTokens }

    var estimatedCost: Double {
        let rate = AgentPricing.rate(for: model)
        return (Double(inputTokens) * rate.input
              + Double(outputTokens) * rate.output
              + Double(cacheCreateTokens) * rate.cacheWrite
              + Double(cacheReadTokens) * rate.cacheRead) / 1_000_000
    }

    var phase: AgentPhase {
        // Whatever it was doing, an agent silent for an hour is not doing it.
        if let last = lastActivity, Date().timeIntervalSince(last) > 3600 { return .idle }
        switch lastKind {
        case "tool_use", "tool_result", "user": return .working
        case "assistant": return .attention
        default: return .idle
        }
    }

    /// The project name, recovered from Claude Code's directory encoding.
    ///
    /// That encoding replaces every `/` and `.` in the absolute path with
    /// `-`, which is lossy and not invertible, so this is a label rather than
    /// a path: the last segment is nearly always the repo name, which is what
    /// you actually want to read on a phone.
    var projectLabel: String {
        // The transcript's own `cwd` when we have it, because the project
        // directory name cannot be decoded: Claude Code replaces every `/`
        // and `.` in the path with `-`, so `conterm-ios` and `conterm/ios`
        // encode identically and the last dash-segment of the real answer is
        // "ios". Falling back to that guess is better than nothing, but only
        // just.
        if let cwd, let name = cwd.split(separator: "/").last { return String(name) }
        let segment = projectDir.split(separator: "/").last.map(String.init) ?? projectDir
        let trimmed = segment.hasPrefix("-") ? String(segment.dropFirst()) : segment
        return trimmed.split(separator: "-").last.map(String.init) ?? trimmed
    }
}

/// Watches the agents on one host.
///
/// Polling rather than streaming: a phone that holds an SSH channel open to
/// tail a file wakes its radio constantly and is the fastest way to flatten a
/// battery. A poll on a slow cadence, over a connection that is already up,
/// costs almost nothing — and the collector only ever reads bytes that are
/// new, so a quiet host is a near-empty round trip.
@MainActor
@Observable
final class RemoteAgentCenter {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var agents: [RemoteAgent] = []
    private(set) var panes: [AgentCollector.Pane] = []
    private(set) var phase: Phase = .loading
    private(set) var refreshing = false
    private(set) var fetchedAt: Date?

    let address: HostAddress
    private let runner: any HostCommandRunner

    /// Per transcript: bytes consumed, and the per-message usage map.
    ///
    /// The map is the whole reason this is stateful. Claude Code re-logs an
    /// assistant message while it streams, so the same id arrives repeatedly
    /// with growing counts; keying by id and overwriting counts it once.
    /// Summing what arrives would multiply tokens, and cost, several-fold.
    private var offsets: [String: Int] = [:]
    private var messages: [String: [String: AgentCollector.Usage]] = [:]
    private var meta: [String: RemoteAgent] = [:]

    private var generation = 0
    // nonisolated(unsafe): deinit runs outside the actor and must cancel
    // this. Only ever assigned on the main actor, which is where a
    // @MainActor type's deinit runs in practice too.
    private nonisolated(unsafe) var poller: Task<Void, Never>?

    init(address: HostAddress, runner: any HostCommandRunner) {
        self.address = address
        self.runner = runner
    }

    deinit { poller?.cancel() }

    /// Poll until stopped. The cadence is deliberately slow — this is ambient
    /// awareness, not a debugger.
    func start(interval: Duration = .seconds(20)) {
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

    /// One poll, in two passes.
    ///
    /// The roster comes first because it is bounded — a tail read per
    /// transcript — and it is the answer to the only urgent question: is
    /// anything waiting on me. The usage pass follows and fills in the
    /// numbers. On a host with a few hundred megabytes of transcripts that is
    /// the difference between a screen in under a second and one in twenty.
    func refresh() async {
        generation += 1
        let gen = generation
        if case .loaded = phase { refreshing = true }
        defer { if gen == generation { refreshing = false } }

        do {
            let known = Set(meta.compactMap { $0.value.task == nil ? nil : $0.key })
            let summary = try await runner.runShell(
                AgentCollector.summaryScript(knownTasks: known), on: address)
            guard gen == generation else { return }
            guard summary.contains(AgentCollector.marker) else {
                if agents.isEmpty {
                    phase = .failed("The host answered, but not with a result. "
                                  + "Check that the login shell is quiet.")
                }
                return
            }
            let parsed = AgentCollector.parse(summary)
            panes = parsed.panes
            apply(parsed.deltas, countingUsage: false)
            phase = .loaded
            fetchedAt = Date()
        } catch {
            // Keep whatever is on screen; a dropped poll is not news.
            if agents.isEmpty { phase = .failed(error.localizedDescription) }
            return
        }

        // Numbers second. A failure here leaves the roster standing, which is
        // the more important half.
        guard let usage = try? await runner.runShell(
            AgentCollector.script(offsets: offsets), on: address),
              gen == generation,
              usage.contains(AgentCollector.marker) else { return }
        apply(AgentCollector.parse(usage).deltas, countingUsage: true)
    }

    /// - Parameter countingUsage: whether this pass carried token records.
    ///   The roster pass reads only a tail, so it must not advance the byte
    ///   offsets — doing so would make the usage pass skip everything before
    ///   that tail and undercount the session forever.
    private func apply(_ deltas: [AgentCollector.Delta], countingUsage: Bool) {
        var seen = Set<String>()

        for delta in deltas {
            seen.insert(delta.path)

            // A shrunk file was rotated; the accumulated map describes bytes
            // that no longer exist.
            if delta.size < (offsets[delta.path] ?? 0) {
                messages[delta.path] = [:]
                meta[delta.path] = nil
            }
            if countingUsage { offsets[delta.path] = delta.size }

            var map = messages[delta.path] ?? [:]
            for (id, usage) in delta.messages { map[id] = usage }
            messages[delta.path] = map

            var agent = meta[delta.path]
                ?? RemoteAgent(id: delta.path, projectDir: delta.projectDir)
            agent.projectDir = delta.projectDir
            if let v = delta.model { agent.model = v }
            if let v = delta.branch { agent.branch = v }
            if let v = delta.task { agent.task = v }
            if let v = delta.lastActivity { agent.lastActivity = v }
            if let v = delta.lastKind { agent.lastKind = v }
            if let v = delta.cwd { agent.cwd = v }

            agent.inputTokens = 0
            agent.outputTokens = 0
            agent.cacheCreateTokens = 0
            agent.cacheReadTokens = 0
            for usage in map.values {
                agent.inputTokens += usage.input
                agent.outputTokens += usage.output
                agent.cacheCreateTokens += usage.cacheCreate
                agent.cacheReadTokens += usage.cacheRead
            }
            agent.turns = map.count
            meta[delta.path] = agent
        }

        // Transcripts the host stopped reporting have aged past the window.
        for path in meta.keys where !seen.contains(path) {
            meta[path] = nil
            messages[path] = nil
            offsets[path] = nil
        }

        agents = meta.values.sorted {
            if $0.phase.rank != $1.phase.rank { return $0.phase.rank < $1.phase.rank }
            let a = $0.lastActivity ?? .distantPast
            let b = $1.lastActivity ?? .distantPast
            if a != b { return a > b }
            return $0.projectLabel.lowercased() < $1.projectLabel.lowercased()
        }
    }

    /// How many agents are waiting on a human. The number the app exists to
    /// put on a phone.
    var needsYouCount: Int { agents.filter { $0.phase == .attention }.count }

    // MARK: - Replying

    /// The tmux pane this agent is running in, if it is running in one.
    ///
    /// Exact, not fuzzy: Claude Code names its project directory by replacing
    /// every `/` and `.` in the absolute cwd with `-`, and the collector
    /// encodes each pane's cwd the same way, so this is a string comparison
    /// rather than a guess.
    func pane(for agent: RemoteAgent) -> AgentCollector.Pane? {
        let key = agent.projectDir.split(separator: "/").last.map(String.init) ?? ""
        guard !key.isEmpty else { return nil }
        return panes.first { $0.encodedPath == key }
    }

    /// Answer an agent that is waiting on you.
    ///
    /// The text and the Return go as two separate `send-keys`, which is the
    /// same thing Conterm does on the Mac and for the same reason: a trailing
    /// newline inside the text is pasted, not submitted, and the agent sits
    /// there with your message typed but unsent.
    func reply(to agent: RemoteAgent, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let pane = pane(for: agent) else { throw ReplyError.noPane }

        let quoted = "'" + trimmed.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "tmux send-keys -t \(pane.id) -l -- \(quoted) && tmux send-keys -t \(pane.id) Enter"
        _ = try await runner.runShell(command, on: address)
        await refresh()
    }

    enum ReplyError: LocalizedError {
        case noPane

        var errorDescription: String? {
            switch self {
            case .noPane:
                return "This agent isn't running inside tmux, so there's no "
                     + "terminal to type into from here."
            }
        }
    }
}
