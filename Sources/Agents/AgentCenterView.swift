import SwiftUI

/// What every agent on one host is doing.
///
/// Conterm's roster on the Mac sits in a sidebar you glance at while you
/// work. On a phone it is the opposite: you open this precisely because you
/// are *not* at the machine, so the first question — is anything waiting on
/// me — has to be answered before you read a single row. Hence the count at
/// the top and the needs-you-first ordering, both straight from the Mac.
struct AgentCenterView: View {
    let host: Host
    /// Injected for previews and tests; nil means build one from the host's
    /// stored credentials.
    var injected: RemoteAgentCenter?

    @State private var center: RemoteAgentCenter?
    @State private var failure: String?
    @State private var replyingTo: RemoteAgent?
    @State private var replyText = ""
    @State private var replyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let center {
                    switch center.phase {
                    case .loading where center.agents.isEmpty:
                        loading
                    case .failed(let text) where center.agents.isEmpty:
                        message(text, tint: Theme.Status.danger)
                    default:
                        if center.agents.isEmpty {
                            message("No agents have run here in the last "
                                  + "\(AgentCollector.staleDays) days.",
                                    tint: Theme.textSecondary)
                        } else {
                            ForEach(Array(center.agents.enumerated()), id: \.element.id) { i, agent in
                                AgentRow(agent: agent,
                                         pane: center.pane(for: agent),
                                         onReply: { replyingTo = agent })
                                    .revealCascade(i)
                            }
                        }
                    }
                } else if let failure {
                    message(failure, tint: Theme.Status.danger)
                } else {
                    loading
                }
            }
            .padding(18)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.shared.fire(.light)
                    Task { await center?.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(center == nil)
            }
        }
        .refreshable { await center?.refresh() }
        .task { start() }
        .onDisappear { center?.stop() }
        .sheet(item: $replyingTo) { agent in
            replySheet(for: agent)
        }
        .tint(Theme.accentOnDark)
    }

    private func start() {
        guard center == nil, failure == nil else { return }
        if let injected {
            center = injected
            Task { await injected.refresh() }
            return
        }
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            failure = "This host has no saved password or key yet."
            return
        }
        let model = RemoteAgentCenter(address: host.address,
                                      runner: SSHCommandRunner(host: host, credentials: credentials,
                                                               policy: .ask))
        center = model
        model.start()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(headline)
                    .font(.system(size: Theme.ui(21), weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)
                if center?.refreshing == true {
                    ProgressView().controlSize(.small).tint(Theme.sshAccent)
                }
            }
            Text(host.displaySubtitle)
                .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            if let stamp = ageStamp {
                Text(stamp)
                    .font(.system(size: Theme.ui(10), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .monospacedDigit()
            }
        }
        .padding(.bottom, 14)
    }

    /// The one sentence worth reading before anything else.
    private var headline: String {
        guard let center, !center.agents.isEmpty else { return "Agents" }
        let waiting = center.needsYouCount
        if waiting > 0 { return "\(waiting) need\(waiting == 1 ? "s" : "") you" }
        let working = center.agents.filter { $0.phase == .working }.count
        if working > 0 { return "\(working) working" }
        return "All quiet"
    }

    private var ageStamp: String? {
        guard let at = center?.fetchedAt else { return nil }
        if center?.refreshing == true { return "refreshing…" }
        let seconds = Int(Date().timeIntervalSince(at))
        if seconds < 5 { return "just now" }
        if seconds < 90 { return "checked \(seconds)s ago" }
        return "checked \(seconds / 60)m ago"
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.sshAccent)
            Text("Asking \(host.hostname)…")
                .font(.system(size: Theme.ui(13), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 30)
    }

    private func message(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    // MARK: - Reply

    private func replySheet(for agent: RemoteAgent) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(agent.task ?? agent.projectLabel)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)

                TextEditor(text: $replyText)
                    .font(.system(size: Theme.ui(15), design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 140)
                    .glassPanel(cornerRadius: 14)

                if let replyError {
                    Text(replyError)
                        .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.Status.danger)
                }
                Spacer()
            }
            .padding(18)
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { replyingTo = nil; replyText = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(to: agent) }
                        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Theme.accentOnDark)
    }

    private func send(to agent: RemoteAgent) {
        let text = replyText
        Task {
            do {
                try await center?.reply(to: agent, text: text)
                replyText = ""
                replyingTo = nil
                SoundEffects.shared.play(.notify)
                Haptics.shared.fire(.success)
            } catch {
                replyError = error.localizedDescription
                Haptics.shared.fire(.failure)
            }
        }
    }
}

/// One agent, as a band rather than a card — the same rule Host Overview
/// follows, and for the same reason.
private struct AgentRow: View {
    let agent: RemoteAgent
    var pane: AgentCollector.Pane?
    var onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                PhaseGem(phase: agent.phase)
                Text(agent.projectLabel)
                    .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if let branch = agent.branch, branch != "HEAD" {
                    Text(branch)
                        .font(.system(size: Theme.ui(10), weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.sshAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .glassPill(tone: .dark)
                }
                Spacer(minLength: 6)
                Text(agent.phase.label)
                    .font(.system(size: Theme.ui(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }

            if let task = agent.task {
                Text(task)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                stat(shortModel, "model")
                // The usage pass lands a beat after the roster, so until it
                // does these are unknown rather than zero — and printing
                // "0 turns · $0.00" next to a live agent is a lie.
                stat(agent.turns > 0 ? "\(agent.turns)" : "—", "turns")
                stat(agent.turns > 0 ? tokens : "—", "tokens")
                stat(agent.turns > 0 ? String(format: "$%.2f", agent.estimatedCost) : "—", "cost")
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                if let at = agent.lastActivity {
                    Text(Self.relative(at))
                        .font(.system(size: Theme.ui(10), weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                }
                Spacer(minLength: 0)
                if pane != nil {
                    Button(action: onReply) {
                        Text(agent.phase == .attention ? "Reply" : "Send a message")
                            .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accentOnDark)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassPill(tone: .dark)
                    }
                    .buttonStyle(PressablePill(scale: 0.94))
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 0.5)
        }
    }

    private var tint: Color {
        switch agent.phase {
        case .attention: return Theme.Status.attention
        case .working: return Theme.Status.working
        case .interrupted: return Theme.warning
        case .ready: return Theme.Status.ready
        case .idle: return Theme.Status.neutral
        }
    }

    /// `claude-opus-5` reads as `opus-5` once you know they're all Claude.
    private var shortModel: String {
        guard let model = agent.model else { return "—" }
        return model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    private var tokens: String {
        let t = agent.totalTokens
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fk", Double(t) / 1_000) }
        return "\(t)"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: Theme.ui(12), weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: Theme.ui(9), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "active just now" }
        if seconds < 3600 { return "active \(seconds / 60)m ago" }
        if seconds < 86400 { return "active \(seconds / 3600)h ago" }
        return "active \(seconds / 86400)d ago"
    }
}

/// The phase gem. Pulses only when something is happening, held at mid-cycle
/// when gated off so the signal survives without a clock — the same discipline
/// as the health gem on Host Overview.
private struct PhaseGem: View {
    let phase: AgentPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool {
        !reduceMotion && (phase == .attention || phase == .working)
    }

    private var color: Color {
        switch phase {
        case .attention: return Theme.Status.attention
        case .working: return Theme.Status.working
        case .interrupted: return Theme.warning
        case .ready: return Theme.Status.ready
        case .idle: return Theme.Status.neutral
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animates)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = animates ? 0.5 + 0.5 * sin(t * (phase == .attention ? 3.4 : 1.8)) : 0.5
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.5 + 0.35 * pulse), radius: 5)
        }
        .frame(width: 8, height: 8)
    }
}
