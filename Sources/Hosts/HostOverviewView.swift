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
        .background(Theme.backdropDark.ignoresSafeArea())
        .navigationTitle(host.alias)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { probe?.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(probe == nil)
            }
        }
        .task { start() }
    }

    private func start() {
        guard probe == nil, failure == nil else { return }
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            failure = "This host has no saved password or key yet."
            return
        }
        probe = HostProbeModel(address: host.address,
                               runner: SSHCommandRunner(credentials: credentials))
    }

    // MARK: - Header

    private var header: some View {
        let health = currentHealth
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Circle()
                    .fill(health.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: health.color.opacity(0.85), radius: 5)
                    .shadow(color: health.color.opacity(0.4), radius: 10)
                Text(headline)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if probe?.refreshing == true {
                    ProgressView().controlSize(.small)
                }
            }
            Text(subheadline)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 14)
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
        let alerts = HostHealth.alerts(info)
        if alerts.isEmpty {
            return [info.os, info.kernel].compactMap { $0 }.joined(separator: " · ")
        }
        return alerts.map(\.1).joined(separator: " · ")
    }

    // MARK: - Bands

    @ViewBuilder
    private func bands(_ info: HostInfo) -> some View {
        Band("Vitals") {
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
            Band("Disks") {
                ForEach(info.disks, id: \.mount) { disk in
                    Meter(label: disk.mount,
                          detail: "\(fmtKB(disk.usedKB)) of \(fmtKB(disk.totalKB))",
                          fraction: disk.pct)
                }
            }
        }

        if !info.ips.isEmpty || !info.listeningPorts.isEmpty {
            Band("Network") {
                if !info.ips.isEmpty { Row("Addresses", info.ips.joined(separator: "  ")) }
                if !info.listeningPorts.isEmpty {
                    Row("Listening", info.listeningPorts.prefix(8).joined(separator: "  "))
                }
            }
        }

        if let containers = info.containers, !containers.isEmpty {
            Band(info.containerRuntime?.displayName ?? "Containers") {
                ForEach(containers.prefix(10), id: \.name) { c in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(c.running ? Theme.Status.ready : Theme.textSecondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(c.name)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(c.status)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if info.kubelet || info.kubeNodes != nil || (info.vms?.isEmpty == false) {
            Band("Workloads") {
                if info.kubelet { Row("Kubelet", "active") }
                if let nodes = info.kubeNodes { Row("Cluster nodes", "\(nodes)") }
                if let vms = info.vms, !vms.isEmpty { Row("VMs", vms.joined(separator: "  ")) }
            }
        }

        if info.failedUnits != nil || info.cronEntries != nil
            || !info.timers.isEmpty || info.usersLoggedIn != nil {
            Band("Health") {
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
            Band("Busiest") {
                ForEach(info.topProcs.prefix(5), id: \.name) { p in
                    HStack {
                        Text(p.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(p.cpu)%  ·  \(p.mem)%")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if !info.journalErrors.isEmpty || !info.kernelWarnings.isEmpty {
            Band("Recent errors") {
                ForEach(Array((info.journalErrors + info.kernelWarnings).prefix(8).enumerated()),
                        id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
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
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 30)
    }

    private func errorMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
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
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
            content
        }
        .padding(.vertical, 12)
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
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 96, alignment: .leading)
            } else {
                Spacer().frame(width: 96)
            }
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
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
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(detail)
                    .font(.system(size: 11, design: .rounded))
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
