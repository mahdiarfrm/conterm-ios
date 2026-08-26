import SwiftUI

/// Conterm on a Mac, seen from the phone.
///
/// The framing matters: this is not a remote control, it is a window. You
/// open it to find out what that machine is in the middle of — which tabs are
/// open, which are SSH'd somewhere, which have an agent waiting on you — from
/// somewhere else entirely. Acting on any of it is a different feature with a
/// different threat model, and this screen deliberately doesn't grow into one.
struct ContermRemoteView: View {
    let host: Host
    /// Injected for previews and tests; nil builds one from stored credentials.
    var injected: ContermRemoteReader?

    @State private var reader: ContermRemoteReader?
    @State private var failure: String?

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
                    Task { await reader?.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(reader == nil)
            }
        }
        .refreshable { await reader?.refresh() }
        .task { start() }
        .onDisappear { reader?.stop() }
        .tint(Theme.accentOnDark)
    }

    private func start() {
        guard reader == nil, failure == nil else { return }
        if let injected {
            reader = injected
            Task { await injected.refresh() }
            return
        }
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            failure = "This host has no saved password or key yet."
            return
        }
        let model = ContermRemoteReader(address: host.address,
                                        runner: SSHCommandRunner(credentials: credentials))
        reader = model
        model.start()
    }

    @ViewBuilder
    private var content: some View {
        if let reader {
            switch reader.phase {
            case .loading where reader.state == nil:
                loading
            case .notPublishing:
                explain("Conterm isn't publishing on this Mac.",
                        detail: "Either it isn't running, or it's older than the "
                              + "version that shares its state. Nothing to fix here — "
                              + "open Conterm on that machine and this fills in.")
            case .failed(let text) where reader.state == nil:
                explain(text, detail: nil, tint: Theme.Status.danger)
            default:
                if let state = reader.state {
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(headline)
                    .font(.system(size: Theme.ui(21), weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)
                if reader?.refreshing == true {
                    ProgressView().controlSize(.small).tint(Theme.sshAccent)
                }
            }
            Text(subheadline)
                .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            if let state = reader?.state, !state.looksLive {
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
        guard let state = reader?.state else { return "Conterm" }
        let waiting = state.agentsNeedingYou
        if waiting > 0 {
            return waiting == 1 ? "1 agent needs you" : "\(waiting) agents need you"
        }
        let panes = state.paneCount
        return "\(panes) pane\(panes == 1 ? "" : "s") open"
    }

    private var subheadline: String {
        guard let state = reader?.state else { return host.displaySubtitle }
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

    var body: some View {
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
