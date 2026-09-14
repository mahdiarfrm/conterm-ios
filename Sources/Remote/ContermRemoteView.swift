import SwiftUI
import os

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
    /// A pane's host, opened on the phone. From whoever owns navigation.
    var onOpenHere: ((Host) -> Void)?
    /// Injected for previews and tests; nil builds one from stored credentials.
    var injected: ContermRemoteLink?

    @State private var link: ContermRemoteLink?
    @State private var failure: String?
    @State private var replyingTo: ContermState.Pane?
    @State private var unmatched: String?
    /// The pane open on the phone.
    @State private var attached: ContermState.Pane?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(18)
            .contermReadableColumn()
        }
        .softTopEdge()
        .brandGround()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await link?.refresh() }
        .task { start() }
        // A pane pushed on top of this screen takes this off screen too,
        // but the pane speaks through this link; it stops only when the
        // screen is really left.
        .onDisappear { if attached == nil { link?.stop() } }
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
            },
            open: { pane in
                Haptics.shared.fire(.light)
                attached = pane
            },
            openHere: { pane in
                guard let remote = pane.remoteHost else { return }
                if let match = Handoff.host(matching: remote) {
                    Haptics.shared.fire(.light)
                    onOpenHere?(match)
                } else {
                    Haptics.shared.fire(.warning)
                    unmatched = remote
                }
            }))
        .navigationDestination(item: $attached) { pane in
            if let link { MacPaneView(link: link, pane: pane) }
        }
        // `CONTERM_PANE=1`: open the first pane as soon as the Mac's state
        // lands, for the harness.
        .onChange(of: link?.state?.paneCount ?? 0) {
            guard ProcessInfo.processInfo.environment["CONTERM_PANE"] != nil,
                  attached == nil,
                  let pane = link?.state?.windows.first?.tabs.first?.panes.first else { return }
            Logger(subsystem: "dev.conterm.ios", category: "tour").notice("tour: pane open")
            attached = pane
        }
        .alert("No saved host for \(unmatched ?? "")",
               isPresented: Binding(get: { unmatched != nil },
                                    set: { if !$0 { unmatched = nil } })) {
            Button("OK") { unmatched = nil }
        } message: {
            Text("Add it in Hosts and it opens from here.")
        }
    }

    private func start() {
        // Back from a pane, or back to a screen whose link was stopped:
        // the same link picks up again.
        if let link { link.start(); return }
        guard failure == nil else { return }
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
                    .font(Theme.font(Theme.ui(10), .bold))
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

    /// The head: the Mac by name, what it is doing in numbers, and whether
    /// what is shown is still live.
    private var header: some View {
        let state = link?.state
        let groups = Set(state?.windows.flatMap { $0.tabs.compactMap(\.groupName) } ?? []).count
        let tabs = state?.windows.reduce(0) { $0 + $1.tabs.count } ?? 0
        let panes = state?.paneCount ?? 0
        let waiting = state?.agentsNeedingYou ?? 0
        let agents = state?.windows.reduce(0) { w, window in
            w + window.tabs.reduce(0) { t, tab in t + tab.panes.filter { $0.agentPhase != nil }.count }
        } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                PanelLabel("Conterm on this Mac", symbol: "macwindow")
                Spacer(minLength: 6)
                if link?.refreshing == true {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                }
                Button {
                    Haptics.shared.fire(.light)
                    Task { await link?.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: Theme.ui(12), weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.accentSoft))
                }
                .buttonStyle(PressablePill(scale: 0.9))
                .disabled(link == nil)
            }
            Text(host.alias)
                .font(Theme.font(Theme.ui(30), .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(headline == "Conterm" ? subheadline : headline)
                .font(Theme.font(Theme.ui(13), .medium))
                .foregroundStyle(Theme.textSecondary)
                .morph(on: headline, alignment: .leading)
            if state != nil {
                FlowLayout(spacing: 6) {
                    Bubble("\(groups)", symbol: "rectangle.3.group", detail: groups == 1 ? "group" : "groups")
                        .popIn(0, base: 0.1)
                    Bubble("\(tabs)", symbol: "rectangle.stack", detail: tabs == 1 ? "tab" : "tabs")
                        .popIn(1, base: 0.1)
                    Bubble("\(panes)", symbol: "rectangle.split.2x1", detail: panes == 1 ? "pane" : "panes")
                        .popIn(2, base: 0.1)
                    Bubble("\(agents)", dot: waiting > 0 ? Theme.Status.attention : nil, symbol: "sparkles",
                           detail: waiting > 0 ? "\(waiting) waiting" : (agents == 1 ? "agent" : "agents"))
                        .popIn(3, base: 0.1)
                }
                .transition(.morph)
            }
            if let state, !state.looksLive {
                // A snapshot that stopped updating is the single most
                // misleading thing this screen can show, so it says so
                // instead of quietly presenting stale tabs as live ones.
                Text("Conterm has stopped updating — this is what it looked like \(Self.ago(state.age)).")
                    .font(Theme.font(Theme.ui(11), .semibold))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
        .animation(Theme.Spring.morph, value: panes)
        .rollUp()
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
                .font(Theme.font(Theme.ui(13), .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 30)
    }

    private func explain(_ text: String, detail: String?,
                         tint: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(Theme.font(Theme.ui(14), .semibold))
                .foregroundStyle(tint)
            if let detail {
                Text(detail)
                    .font(Theme.font(Theme.ui(12), .medium))
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
                    .font(Theme.font(Theme.ui(11), .bold))
                    .tracking(1.1)
                    .lineLimit(1)
                if window.isKey {
                    Text("front")
                        .font(Theme.font(Theme.ui(9), .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentOnDark))
                }
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, reveal == 0 ? 0 : 18)
            .padding(.bottom, 8)

            ForEach(Self.runs(window.tabs), id: \.id) { run in
                if let name = run.group {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(run.colorKey.map { HostGroup.color(forKey: $0) } ?? Theme.textSecondary)
                            .frame(width: 8, height: 8)
                        Text(name.uppercased())
                            .font(Theme.font(Theme.ui(10.5), .bold))
                            .tracking(1.0)
                            .foregroundStyle(run.colorKey.map { HostGroup.color(forKey: $0) } ?? Theme.textSecondary)
                        Text("\(run.tabs.count)")
                            .font(Theme.font(Theme.ui(10), .bold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                }
                ForEach(run.tabs, id: \.index) { tab in
                    TabBand(tab: tab, grouped: run.group != nil)
                }
            }
        }
        .rollUp(delay: Double(reveal) * 0.05)
    }

    /// Tabs in the order the Mac has them, cut wherever the group changes,
    /// so a group reads as a heading over its tabs the way it does in the
    /// Mac's tab bar.
    private struct Run: Identifiable {
        var group: String?
        var colorKey: String?
        var tabs: [ContermState.Tab]
        var id: String { "\(group ?? "-")-\(tabs.first?.index ?? 0)" }
    }

    private static func runs(_ tabs: [ContermState.Tab]) -> [Run] {
        var out: [Run] = []
        for tab in tabs {
            if var last = out.last, last.group == tab.groupName {
                last.tabs.append(tab)
                out[out.count - 1] = last
            } else {
                out.append(Run(group: tab.groupName, colorKey: tab.groupColorKey, tabs: [tab]))
            }
        }
        return out
    }
}

/// One tab and its panes, as a band. No card — same rule as Host Overview.
private struct TabBand: View {
    let tab: ContermState.Tab
    /// Under a group heading: the group's colour marks the tab, the name
    /// is already above it.
    var grouped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let key = tab.groupColorKey {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(HostGroup.color(forKey: key))
                        .frame(width: 3, height: 14)
                }
                Text(tab.title)
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .foregroundStyle(tab.isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if let group = tab.groupName, !grouped {
                    Text(group)
                        .font(Theme.font(Theme.ui(9), .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 6)
                if tab.isSelected {
                    Text("current")
                        .font(Theme.font(Theme.ui(9), .semibold))
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
        HStack(spacing: 8) {
            Button {
                actions.open(pane)
            } label: {
                row
            }
            .buttonStyle(.plain)
            // The pane, picked up here: its screen and a keyboard into it.
            Button {
                actions.open(pane)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: Theme.ui(11), weight: .bold))
                    Text("Continue")
                        .font(Theme.font(Theme.ui(11.5), .bold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: Theme.ui(30))
                .background(Capsule(style: .continuous).fill(Theme.accentSoft))
            }
            .buttonStyle(PressablePill(scale: 0.9))
            // A pane that is a window onto another machine can be opened
            // on this one: the shell picked up where the Mac left it.
            if let remote = pane.remoteHost {
                Button {
                    actions.openHere(pane)
                } label: {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: Theme.ui(12), weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: Theme.ui(32), height: Theme.ui(32))
                        .background(Circle().fill(Theme.accentSoft))
                }
                .buttonStyle(PressablePill(scale: 0.9))
                .accessibilityLabel("Open \(remote) here")
            }
        }
        // Tapping a pane opens it here: its screen, and keys into it. The
        // Mac's own window comes forward from the menu.
        .contextMenu {
            Button("Open here", systemImage: "iphone") {
                actions.open(pane)
            }
            Button("Bring to front on the Mac", systemImage: "macwindow.on.rectangle") {
                actions.focus(pane)
            }
            if let remote = pane.remoteHost {
                Button("Open \(remote) as a shell here", systemImage: "iphone.and.arrow.forward") {
                    actions.openHere(pane)
                }
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
                            .font(Theme.font(Theme.ui(11), .semibold))
                            .foregroundStyle(Theme.sshAccent)
                    } else if let dir = pane.dirLabel {
                        Text(dir)
                            .font(.system(size: Theme.ui(11), weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    if pane.isActive {
                        Text("focused")
                            .font(Theme.font(Theme.ui(9), .medium))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    }
                }

                if let label = pane.agentLabel {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agentTint)
                            .frame(width: 5, height: 5)
                        Text(label)
                            .font(Theme.font(Theme.ui(11), .semibold))
                            .foregroundStyle(agentTint)
                        Spacer(minLength: 4)
                        // Only where it is the obvious next move. An agent
                        // that is working doesn't need an answer, and a row
                        // of buttons on every pane would bury the one that
                        // does.
                        if pane.agentPhase == "attention" {
                            Button("Reply") { actions.reply(pane) }
                                .font(Theme.font(Theme.ui(10.5), .bold))
                                .foregroundStyle(Theme.onAccent)
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
    /// The pane itself, mirrored on the phone.
    var open: @MainActor (ContermState.Pane) -> Void = { _ in }
    /// A pane that is an `ssh` somewhere, opened on the phone.
    var openHere: @MainActor (ContermState.Pane) -> Void = { _ in }
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
                        .font(Theme.font(Theme.ui(13), .semibold))
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
                    .font(Theme.font(Theme.ui(15), .medium))
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
                    .font(Theme.font(Theme.ui(13), .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .glassPill()
                    .buttonStyle(.plain)

                    Button("Send") {
                        onSend(text, true)
                        dismiss()
                    }
                    .font(Theme.font(Theme.ui(13), .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(Theme.accentOnDark))
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .brandGround()
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
                    .font(Theme.font(Theme.ui(14), .semibold))
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
                .font(Theme.font(Theme.ui(12), .bold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.Status.attention))
                .buttonStyle(.plain)
        }
    }
}
