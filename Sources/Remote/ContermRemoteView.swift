import SwiftUI

/// Conterm on a Mac, from the phone — and now a way to act on it.
///
/// This began as a window: open it to find out what that machine is in the
/// middle of, which tabs are SSH'd where, which have an agent waiting on you.
/// It stays that first, because that is what you actually want from a pocket.
/// But the moment you can see an agent waiting, not being able to answer it
/// is the wrong kind of restraint.
///
/// The threat model that held control back turned out to be a misreading: the
/// phone is already on this Mac over SSH, and anything that can drop a file
/// in the inbox can already run anything as that user. So the honest limit is
/// not "don't act", it is "act only in ways the keyboard could" — a closed
/// set of commands, no arbitrary shell, listed in one place on each side.
struct ContermRemoteView: View {
    let host: Host
    /// Injected for previews and tests; nil builds one from stored credentials.
    var injected: ContermRemoteLink?

    @State private var link: ContermRemoteLink?
    @State private var failure: String?
    @State private var replyingTo: ContermState.Pane?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(18)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .navigationTitle("Conterm")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.shared.fire(.light)
                    Task { await link?.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(link == nil)
            }
        }
        .refreshable { await link?.refresh() }
        .task { start() }
        .onDisappear { link?.stop() }
        .tint(Theme.accentOnDark)
        .sheet(item: $replyingTo) { pane in
            AgentReplySheet(pane: pane) { text, submit in
                Task { await link?.send(.init(action: .sendText,
                                              paneID: pane.id,
                                              text: text,
                                              submit: submit)) }
            }
        }
        .environment(\.contermRemoteActions, ContermRemoteActions(
            focus: { pane in
                Haptics.shared.fire(.light)
                Task { await link?.send(.init(action: .focusPane, paneID: pane.id)) }
            },
            reply: { pane in replyingTo = pane },
            interrupt: { pane in
                Haptics.shared.fire(.warning)
                Task { await link?.send(.init(action: .interrupt, paneID: pane.id)) }
            }))
    }

    private func start() {
        guard link == nil, failure == nil else { return }
        if let injected {
            link = injected
            injected.start()
            return
        }
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            failure = "This host has no saved password or key yet."
            return
        }
        let model = ContermRemoteLink(host: host, credentials: credentials)
        link = model
        model.start()
    }

    @ViewBuilder
    private var content: some View {
        if let link {
            switch link.phase {
            case .loading where link.state == nil:
                loading
            case .notPublishing:
                explain("Conterm isn't publishing on this Mac.",
                        detail: "Either it isn't running, or it's older than the "
                              + "version that shares its state. Nothing to fix here — "
                              + "open Conterm on that machine and this fills in.")
            case .failed(let text) where link.state == nil:
                explain(text, detail: nil, tint: Theme.Status.danger)
            default:
                if let state = link.state {
                    // Agents first, always. The rest of this screen is a
                    // description of a machine; this part is a list of things
                    // waiting on you, and burying them inside the pane rows
                    // of the tab they happen to live in was exactly backwards
                    // for the way people actually use their laptop.
                    waiting(state)
                    if state.windows.isEmpty {
                        explain("Conterm is running with no windows open.", detail: nil)
                    } else {
                        ForEach(Array(state.windows.enumerated()), id: \.element.index) { i, window in
                            windowSection(window, reveal: i)
                        }
                    }
                }
            }
        } else if let failure {
            explain(failure, detail: nil, tint: Theme.Status.danger)
        } else {
            loading
        }
    }

    /// The agents that want something, lifted out of the tree.
    @ViewBuilder
    private func waiting(_ state: ContermState) -> some View {
        let panes = state.windows.flatMap(\.tabs).flatMap(\.panes)
            .filter { $0.agentPhase == "attention" }
        if !panes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("WAITING ON YOU")
                    .font(.system(size: Theme.ui(10), weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.Status.attention)
                ForEach(panes, id: \.id) { pane in
                    WaitingRow(pane: pane)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.Status.attention.opacity(0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.Status.attention.opacity(0.28), lineWidth: 0.5)
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(headline)
                    .font(.system(size: Theme.ui(21), weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)
                if link?.refreshing == true {
                    ProgressView().controlSize(.small).tint(Theme.sshAccent)
                }
            }
            Text(subheadline)
                .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            if let state = link?.state, !state.looksLive {
                // A snapshot that stopped updating is the single most
                // misleading thing this screen can show, so it says so
                // instead of quietly presenting stale tabs as live ones.
                Text("Conterm has stopped updating — this is what it looked like "
                   + "\(Self.ago(state.age)).")
                    .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 14)
    }

    private var headline: String {
        guard let state = link?.state else { return "Conterm" }
        let waiting = state.agentsNeedingYou
        if waiting > 0 {
            return waiting == 1 ? "1 agent needs you" : "\(waiting) agents need you"
        }
        let panes = state.paneCount
        return "\(panes) pane\(panes == 1 ? "" : "s") open"
    }

    private var subheadline: String {
        guard let state = link?.state else { return host.displaySubtitle }
        var parts: [String] = []
        if let name = state.hostName { parts.append(name) }
        if let version = state.appVersion { parts.append("Conterm \(version)") }
        if parts.isEmpty { parts.append(host.displaySubtitle) }
        return parts.joined(separator: " · ")
    }

    private static func ago(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s < 90 { return "\(s)s ago" }
        if s < 5400 { return "\(s / 60)m ago" }
        if s < 172_800 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
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

    private func explain(_ text: String, detail: String?,
                         tint: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            if let detail {
                Text(detail)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    // MARK: - Windows

    private func windowSection(_ window: ContermState.Window, reveal: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((window.title ?? "Window \(window.index)").uppercased())
                    .font(.system(size: Theme.ui(11), weight: .bold))
                    .tracking(1.1)
                    .lineLimit(1)
                if window.isKey {
                    Text("front")
                        .font(.system(size: Theme.ui(9), weight: .bold))
                        .foregroundStyle(Theme.appBackground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentOnDark))
                }
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, reveal == 0 ? 0 : 18)
            .padding(.bottom, 8)

            ForEach(window.tabs, id: \.index) { tab in
                TabBand(tab: tab)
            }
        }
        .rollUp(delay: Double(reveal) * 0.05)
    }
}

/// One tab and its panes, as a band. No card — same rule as Host Overview.
private struct TabBand: View {
    let tab: ContermState.Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let key = tab.groupColorKey {
                    Circle()
                        .fill(HostGroup.color(forKey: key))
                        .frame(width: 6, height: 6)
                        .shadow(color: HostGroup.color(forKey: key).opacity(0.7), radius: 3)
                }
                Text(tab.title)
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(tab.isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if let group = tab.groupName {
                    Text(group)
                        .font(.system(size: Theme.ui(9), weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 6)
                if tab.isSelected {
                    Text("current")
                        .font(.system(size: Theme.ui(9), weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.sshAccent)
                }
            }

            ForEach(tab.panes, id: \.id) { pane in
                PaneRow(pane: pane, showIndex: tab.panes.count > 1)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 0.5)
        }
    }
}

private struct PaneRow: View {
    let pane: ContermState.Pane
    var showIndex: Bool
    @Environment(\.contermRemoteActions) private var actions

    var body: some View {
        Button {
            actions.focus(pane)
        } label: {
            row
        }
        .buttonStyle(.plain)
        // Tapping a pane brings it forward on the Mac. This is the whole
        // feature in one gesture: you are looking at a list of what that
        // machine is doing, and the obvious thing to want is to be *there*.
        .contextMenu {
            Button("Bring to front", systemImage: "macwindow.on.rectangle") {
                actions.focus(pane)
            }
            if pane.agentPhase != nil {
                Button("Reply to the agent", systemImage: "text.bubble") {
                    actions.reply(pane)
                }
                Button("Interrupt", systemImage: "stop.circle", role: .destructive) {
                    actions.interrupt(pane)
                }
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            if showIndex {
                Text("\(pane.index)")
                    .font(.system(size: Theme.ui(9), weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .frame(width: 12, alignment: .leading)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let remote = pane.remoteHost {
                        // A Mac tab that is really a window onto another
                        // machine. Worth its own colour: it is the difference
                        // between "on my laptop" and "on production".
                        Label(remote, systemImage: "arrow.turn.up.right")
                            .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.sshAccent)
                    } else if let dir = pane.dirLabel {
                        Text(dir)
                            .font(.system(size: Theme.ui(11), weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    if pane.isActive {
                        Text("focused")
                            .font(.system(size: Theme.ui(9), weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    }
                }

                if let label = pane.agentLabel {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agentTint)
                            .frame(width: 5, height: 5)
                            .shadow(color: agentTint.opacity(0.7), radius: 3)
                        Text(label)
                            .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                            .foregroundStyle(agentTint)
                        Spacer(minLength: 4)
                        // Only where it is the obvious next move. An agent
                        // that is working doesn't need an answer, and a row
                        // of buttons on every pane would bury the one that
                        // does.
                        if pane.agentPhase == "attention" {
                            Button("Reply") { actions.reply(pane) }
                                .font(.system(size: Theme.ui(10.5), weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.appBackground)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.Status.attention))
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var agentTint: Color {
        switch pane.agentPhase {
        case "attention": return Theme.Status.attention
        case "working": return Theme.Status.working
        case "interrupted": return Theme.warning
        case "ready": return Theme.Status.ready
        default: return Theme.Status.neutral
        }
    }
}


// MARK: - Acting on the Mac

/// The three things this screen can do to the far machine, passed down the
/// tree rather than threaded through every row.
struct ContermRemoteActions: Sendable {
    var focus: @MainActor (ContermState.Pane) -> Void = { _ in }
    var reply: @MainActor (ContermState.Pane) -> Void = { _ in }
    var interrupt: @MainActor (ContermState.Pane) -> Void = { _ in }
}

private struct ContermRemoteActionsKey: EnvironmentKey {
    static let defaultValue = ContermRemoteActions()
}

extension EnvironmentValues {
    var contermRemoteActions: ContermRemoteActions {
        get { self[ContermRemoteActionsKey.self] }
        set { self[ContermRemoteActionsKey.self] = newValue }
    }
}

/// Answer an agent that is waiting on the Mac.
///
/// This is the payoff for the whole remote feature. Claude Code on your
/// laptop asks a question at 11pm; the phone in your hand can answer it. The
/// send button submits with a real Return on the far side, because a pasted
/// newline doesn't — the same lesson Agent Center learned locally.
struct AgentReplySheet: View {
    let pane: ContermState.Pane
    let onSend: (String, Bool) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let label = pane.agentLabel {
                    Text(label)
                        .font(.system(size: Theme.ui(13), weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Status.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let dir = pane.dirLabel {
                    Text(dir)
                        .font(.system(size: Theme.ui(11), weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }

                TextField("Your answer", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.ui(15), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.paneTile)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1)))
                    .focused($focused)

                // Two ways to answer, because agents ask two kinds of
                // question. "Just Return" accepts a default prompt without
                // typing anything, which is most of what an agent is waiting
                // for at 11pm.
                HStack(spacing: 10) {
                    Button("Just Return") {
                        onSend("", true)
                        dismiss()
                    }
                    .font(.system(size: Theme.ui(13), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .glassPill()
                    .buttonStyle(.plain)

                    Button("Send") {
                        onSend(text, true)
                        dismiss()
                    }
                    .font(.system(size: Theme.ui(13), weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.appBackground)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(Theme.accentOnDark))
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(340)])
        .onAppear { focused = true }
    }
}

/// One waiting agent, with the two things you would do about it.
private struct WaitingRow: View {
    let pane: ContermState.Pane
    @Environment(\.contermRemoteActions) private var actions

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.ui(13), weight: .bold))
                .foregroundStyle(Theme.Status.attention)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(pane.agentLabel ?? "An agent needs you")
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let dir = pane.dirLabel {
                    Text(dir)
                        .font(.system(size: Theme.ui(11), weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 6)

            Button("Reply") { actions.reply(pane) }
                .font(.system(size: Theme.ui(12), weight: .bold, design: .rounded))
                .foregroundStyle(Theme.appBackground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.Status.attention))
                .buttonStyle(.plain)
        }
    }
}
