import SwiftUI

/// A briefing on one machine, from a single SSH round trip.
///
/// Conterm's rule for this surface, kept: **no boxed sub-cards.** Information
/// sits directly on the glass as typographic bands separated by hairlines, and
/// a band the host has nothing to say about does not render at all. A machine
/// without systemd should look like a machine without systemd, not like one
/// with an empty systemd section.
struct HostOverviewView: View {
    let host: Host
    /// Handed in by whoever pushed this screen, so the briefing can lead into
    /// a terminal without owning session creation itself.
    var onOpenShell: ((Host) -> Void)?

    @State private var showingAgents = false

    @State private var probe: HostProbeModel?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let probe {
                    switch probe.phase {
                    case .loading:
                        loading
                    case .failed(let text):
                        errorMessage(text)
                    case .loaded(let info):
                        bands(info)
                    }
                } else if let failure {
                    errorMessage(failure)
                } else {
                    loading
                }
            }
            .padding(18)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .navigationTitle(host.alias)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(probe == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // "What is this box doing" and "what are my agents doing" are
                // the same question asked at two zoom levels.
                Button { showingAgents = true } label: {
                    Image(systemName: "sparkles")
                }
            }
        }
        // A briefing that finds a problem has to lead somewhere. Without
        // this you read "3 failed units", go back, find the host, and tap it
        // again — three steps to act on what the screen just told you.
        .safeAreaInset(edge: .bottom) { openShellBar }
        .navigationDestination(isPresented: $showingAgents) { AgentCenterView(host: host) }
        .refreshable { refresh() }
        .task { start() }
    }

    private func refresh() {
        Haptics.shared.fire(.light)
        probe?.refresh()
    }

    private var openShellBar: some View {
        Button {
            SoundEffects.shared.tap(.connect, haptic: .medium)
            onOpenShell?(host)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: Theme.ui(14), weight: .semibold))
                Text(SessionStore.shared.liveSession(for: host) == nil
                     ? "Open a shell" : "Back to the shell")
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Theme.accentOnDark)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.ui(48))
            .floatingGlass()
            .shadow(color: .black.opacity(0.45), radius: 18, y: 7)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .buttonStyle(PressablePill())
        .opacity(onOpenShell == nil ? 0 : 1)
        .disabled(onOpenShell == nil)
    }

    private func start() {
        guard probe == nil, failure == nil else { return }
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            failure = "This host has no saved password or key yet."
            return
        }
        probe = HostProbeModel(address: host.address,
                               runner: SSHCommandRunner(host: host, credentials: credentials))
    }

    // MARK: - Header

    private var header: some View {
        let health = currentHealth
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                HealthGem(health: health)
                Text(headline)
                    .font(.system(size: Theme.ui(21), weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                if probe?.refreshing == true {
                    ProgressView().controlSize(.small).tint(Theme.sshAccent)
                }
            }

            Text(subheadline)
                .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)

            // Alerts as chips, not as a `·`-joined run-on. The whole point of
            // this screen is that a problem should be countable at a glance,
            // and a sentence is not countable.
            if !alerts.isEmpty {
                FlowChips(alerts.map { ($0.1, $0.0.color) })
                    .padding(.top, 2)
            }

            if let stamp = ageStamp {
                Text(stamp)
                    .font(.system(size: Theme.ui(10), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .monospacedDigit()
            }
        }
        .padding(.bottom, 14)
    }

    private var alerts: [(HostHealth, String)] {
        guard let probe, case .loaded(let info) = probe.phase else { return [] }
        return HostHealth.alerts(info)
    }

    /// How old the numbers on screen are. A cached snapshot renders instantly
    /// while a fresh probe runs behind it, which is only honest if the screen
    /// says so.
    private var ageStamp: String? {
        guard let at = probe?.fetchedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(at))
        if probe?.refreshing == true { return "refreshing\u{2026}" }
        if seconds < 5 { return "just now" }
        if seconds < 90 { return "checked \(seconds)s ago" }
        return "checked \(seconds / 60)m ago"
    }

    private var currentHealth: HostHealth {
        guard let probe, case .loaded(let info) = probe.phase else { return .unknown }
        return HostHealth.of(info)
    }

    private var headline: String {
        if let probe, case .loaded(let info) = probe.phase, !info.hostname.isEmpty {
            return info.hostname
        }
        return host.alias
    }

    private var subheadline: String {
        guard let probe, case .loaded(let info) = probe.phase else {
            return host.displaySubtitle
        }
        let facts = [info.os, info.kernel].compactMap { $0 }
        return facts.isEmpty ? host.displaySubtitle : facts.joined(separator: " · ")
    }

    // MARK: - Bands

    @ViewBuilder
    private func bands(_ info: HostInfo) -> some View {
        Band("Vitals", reveal: 0) {
            if let uptime = info.uptime { Row("Uptime", uptime) }
            if let load = info.loadAvg {
                Row("Load", String(format: "%.2f  %.2f  %.2f", load.0, load.1, load.2),
                    tint: HostHealth.overloaded(info) ? Theme.Status.danger : nil)
            }
            if let cores = info.cores { Row("Cores", "\(cores)") }
            if let total = info.memTotalMB, let avail = info.memAvailMB, total > 0 {
                Meter(label: "Memory",
                      detail: "\(fmtMB(total - avail)) of \(fmtMB(total))",
                      fraction: Double(total - avail) / Double(total))
            }
        }

        if !info.disks.isEmpty {
            Band("Disks", reveal: 0.06) {
                ForEach(info.disks, id: \.mount) { disk in
                    Meter(label: disk.mount,
                          detail: "\(fmtKB(disk.usedKB)) of \(fmtKB(disk.totalKB))",
                          fraction: disk.pct)
                }
            }
        }

        if !info.ips.isEmpty || !info.listeningPorts.isEmpty {
            Band("Network", reveal: 0.12) {
                if !info.ips.isEmpty { Row("Addresses", info.ips.joined(separator: "  ")) }
                if !info.listeningPorts.isEmpty {
                    Row("Listening", info.listeningPorts.prefix(8).joined(separator: "  "))
                }
            }
        }

        if let containers = info.containers, !containers.isEmpty {
            Band(info.containerRuntime?.displayName ?? "Containers", reveal: 0.12) {
                ForEach(containers.prefix(10), id: \.name) { c in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(c.running ? Theme.Status.ready : Theme.textSecondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(c.name)
                            .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(c.status)
                            .font(.system(size: Theme.ui(11), design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if info.kubelet || info.kubeNodes != nil || (info.vms?.isEmpty == false) {
            Band("Workloads", reveal: 0.18) {
                if info.kubelet { Row("Kubelet", "active") }
                if let nodes = info.kubeNodes { Row("Cluster nodes", "\(nodes)") }
                if let vms = info.vms, !vms.isEmpty { Row("VMs", vms.joined(separator: "  ")) }
            }
        }

        if info.failedUnits != nil || info.cronEntries != nil
            || !info.timers.isEmpty || info.usersLoggedIn != nil {
            Band("Health", reveal: 0.24) {
                if let failed = info.failedUnits {
                    Row("Failed units", "\(failed)",
                        tint: failed > 0 ? Theme.Status.danger : nil)
                    if !info.failedNames.isEmpty {
                        Row("", info.failedNames.joined(separator: "  "))
                    }
                }
                if let crons = info.cronEntries { Row("Cron entries", "\(crons)") }
                if let users = info.usersLoggedIn { Row("Logged in", "\(users)") }
                if info.rebootRequired { Row("Reboot", "required", tint: Theme.warning) }
                if let updates = info.updatesAvailable {
                    Row("Updates", updates, tint: Theme.warning)
                }
            }
        }

        if !info.topProcs.isEmpty {
            Band("Busiest", reveal: 0.30) {
                ForEach(info.topProcs.prefix(5), id: \.name) { p in
                    HStack {
                        Text(p.name)
                            .font(.system(size: Theme.ui(12), weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(p.cpu)%  ·  \(p.mem)%")
                            .font(.system(size: Theme.ui(11), design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if !info.journalErrors.isEmpty || !info.kernelWarnings.isEmpty {
            Band("Recent errors", reveal: 0.36) {
                ForEach(Array((info.journalErrors + info.kernelWarnings).prefix(8).enumerated()),
                        id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: Theme.ui(10.5), design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - States

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

    private func errorMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
            .foregroundStyle(Theme.Status.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    private func fmtMB(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
    private func fmtKB(_ kb: Int) -> String {
        let gb = Double(kb) / 1024 / 1024
        return gb >= 1 ? String(format: "%.0f GB", gb) : String(format: "%.0f MB", Double(kb) / 1024)
    }
}

// MARK: - Primitives

/// A band: a small uppercase label, a hairline, and rows sitting directly on
/// the background. No card, no fill, no nesting.
private struct Band<Content: View>: View {
    let title: String
    var reveal: Double = 0
    @ViewBuilder var content: Content

    init(_ title: String, reveal: Double = 0, @ViewBuilder content: () -> Content) {
        self.title = title
        self.reveal = reveal
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: Theme.ui(10), weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
            content
        }
        .padding(.vertical, 12)
        .rollUp(delay: reveal)
    }
}

/// The status gem. Still when healthy; a slow pulse when not.
///
/// Driven by a `TimelineView` at 20fps rather than `repeatForever`, and
/// paused outright when there is nothing to say — an idle screen must not
/// hold a render loop open.
private struct HealthGem: View {
    let health: HostHealth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool {
        !reduceMotion && (health == .attention || health == .distress)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animates)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // Held mid-cycle when gated off, so the signal survives without
            // a clock — Conterm's rule for every pulse in the app.
            let pulse = animates ? 0.5 + 0.5 * sin(t * 3.0) : 0.5
            Circle()
                .fill(health.color)
                .frame(width: 9, height: 9)
                .shadow(color: health.color.opacity(0.55 + 0.35 * pulse), radius: 5)
                .shadow(color: health.color.opacity(0.25 + 0.25 * pulse), radius: 11)
        }
        .frame(width: 9, height: 9)
    }
}

private struct Row: View {
    let label: String
    let value: String
    var tint: Color?

    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 96, alignment: .leading)
            } else {
                Spacer().frame(width: 96)
            }
            Text(value)
                .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                .foregroundStyle(tint ?? Theme.textPrimary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// A labelled bar. Tints amber past 80% and red past 90%, so a full disk is
/// visible without reading the number.
private struct Meter: View {
    let label: String
    let detail: String
    let fraction: Double

    private var tint: Color {
        if fraction > 0.9 { return Theme.Status.danger }
        if fraction > 0.8 { return Theme.warning }
        return Theme.sshAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(detail)
                    .font(.system(size: Theme.ui(11), design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stroke).frame(height: 4)
                    Capsule().fill(tint)
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)),
                               height: 4)
                        .shadow(color: tint.opacity(0.5), radius: 3)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4)
    }
}

/// Alert chips that wrap. There is no `FlowLayout` in SwiftUI, and a
/// horizontal scroll view for two or three short words reads as broken — so
/// this is a real `Layout`, which is about twenty lines and behaves.
private struct FlowChips: View {
    let items: [(String, Color)]

    init(_ items: [(String, Color)]) { self.items = items }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0)
                    .font(.system(size: Theme.ui(10.5), weight: .semibold, design: .rounded))
                    .foregroundStyle(item.1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        Capsule(style: .continuous).fill(item.1.opacity(0.13))
                    }
                    .overlay {
                        Capsule(style: .continuous).stroke(item.1.opacity(0.35), lineWidth: 0.5)
                    }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
