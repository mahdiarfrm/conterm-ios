import SwiftUI

/// A briefing on one machine.
///
/// The machine's name, large, with anything that needs saying beside it;
/// then a column of panels, each arriving after the last: the vitals with a
/// live chart of the cores, the load as three capsules, four tiles for the
/// rest of the glance, and below those the disks, the network, the
/// containers as bubbles, the workloads, the health, the busiest processes
/// and the recent errors. A panel the host has nothing to say about does
/// not render at all. A machine without systemd should look like a machine
/// without systemd, not like one with an empty systemd section.
///
/// Two sources feed it: the one-shot probe, which says what the machine
/// is, and the pulse, which samples what it is doing every few seconds
/// while this screen is up and draws the chart line by line.
struct HostOverviewView: View {
    let host: Host
    /// Handed in by whoever pushed this screen, so the briefing can lead into
    /// a terminal without owning session creation itself.
    var onOpenShell: ((Host) -> Void)?
    /// The host's files, and a shell on it handed to a Mac. Both from
    /// whoever owns navigation; nil leaves the chip out.
    var onFiles: ((Host) -> Void)?
    var onHandoff: ((Host) -> Void)?

    /// Injected for previews and for the design harness; nil builds one from
    /// stored credentials.
    var injected: HostProbeModel?

    @State private var showingMac = false
    @State private var detail: OverviewDetail?
    @Namespace private var zoom
    @State private var probe: HostProbeModel?
    @State private var containers: ContainerControl?
    /// A disruptive action waiting on a confirmation. The tuple is the
    /// container and what is about to happen to it, which is exactly what the
    /// alert has to name.
    @State private var pendingAction: (name: String, action: ContainerControl.Action)?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                if let probe {
                    switch probe.phase {
                    case .loading:
                        loading
                    case .failed(let text):
                        errorMessage(text)
                    case .loaded(let info):
                        panels(info, pulse: probe.pulse)
                    }
                } else if let failure {
                    errorMessage(failure)
                } else {
                    loading
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
            .contermReadableColumn()
            // The loading row goes out of focus as the panels rise into
            // place — one event, not a redraw.
            .animation(Theme.Spring.morph, value: phaseKey)
        }
        .softTopEdge()
        .brandGround()
        // The hero carries the name; a second copy in the bar is clutter.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(probe == nil)
            }
        }
        // A briefing that finds a problem has to lead somewhere. Without
        // this you read "3 failed units", go back, find the host, and tap it
        // again — three steps to act on what the screen just told you.
        .safeAreaInset(edge: .bottom) { openShellBar }
        .navigationDestination(isPresented: $showingMac) {
            ContermRemoteView(host: host, onOpenHere: onOpenShell)
        }
        .navigationDestination(item: $detail) { which in
            Group {
                if let probe, case .loaded(let info) = probe.phase {
                    switch which {
                    case .vitals: VitalsDetail(info: info, pulse: probe.pulse)
                    case .network: NetworkDetail(info: info, pulse: probe.pulse)
                    }
                }
            }
            .navigationTransition(.zoom(sourceID: which.zoomID, in: zoom))
            // The sampler keeps running behind a detail of its own numbers.
            .onAppear { probe?.pulse.start() }
            .onDisappear { probe?.pulse.release() }
        }
        .refreshable { refresh() }
        // Named, not "Continue". A confirmation whose button says the act is
        // one you read; a confirmation whose button says "OK" is one you tap.
        .alert(pendingAction.map { "\($0.action.title) \($0.name)?" } ?? "",
               isPresented: Binding(get: { pendingAction != nil },
                                    set: { if !$0 { pendingAction = nil } })) {
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button(pendingAction?.action.title ?? "OK", role: .destructive) {
                guard let pending = pendingAction, let containers else { return }
                pendingAction = nil
                Haptics.shared.fire(.warning)
                Task { await containers.perform(pending.action, on: pending.name) }
            }
        } message: {
            if containers?.isProduction == true {
                Text("This host looks like production.")
            }
        }
        .alert("Container", isPresented: Binding(
            get: { containers?.failure != nil },
            set: { if !$0 { containers?.clearFailure() } })) {
            Button("OK") { containers?.clearFailure() }
        } message: {
            Text(containers?.failure ?? "")
        }
        .task { start() }
        // The pulse runs while this is on screen and for a few minutes
        // after, so coming back finds the chart full and the connection
        // warm; then it stops on its own.
        .onAppear { probe?.pulse.start() }
        .onDisappear { probe?.pulse.release() }
        // What the host runs, learned once and kept on the record, so its
        // mark is on the row before it is ever opened again.
        .onChange(of: currentDistro) { _, distro in
            guard let distro, host.distro != distro.rawValue,
                  HostStore.shared.hosts.contains(where: { $0.id == host.id }) else { return }
            var updated = host
            updated.distro = distro.rawValue
            HostStore.shared.update(updated)
        }
    }

    private var currentDistro: Distro? {
        if let probe, case .loaded(let info) = probe.phase, let d = info.distro { return d }
        return host.distro.flatMap(Distro.init(rawValue:))
    }

    private func refresh() {
        Haptics.shared.fire(.light)
        probe?.refresh()
    }

    /// The one action on the screen, solid: cream on the ground.
    private var openShellBar: some View {
        Button {
            SoundEffects.shared.tap(.connect, haptic: .medium)
            onOpenShell?(host)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: Theme.ui(15), weight: .semibold))
                Text(SessionStore.shared.liveSession(for: host) == nil
                     ? "Open a shell" : "Back to the shell")
                    .font(Theme.font(Theme.ui(15), .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.ui(54))
            .background(Capsule(style: .continuous).fill(Theme.accent))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .buttonStyle(PressablePill())
        .opacity(onOpenShell == nil ? 0 : 1)
        .disabled(onOpenShell == nil)
    }

    private func start() {
        guard probe == nil, failure == nil else { return }
        if let injected {
            probe = injected
            HostProbeModel.adopt(injected, for: host.id)
            injected.pulse.start()
            return
        }
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            failure = "This host has no saved password or key yet."
            return
        }
        // One model per host for the app's lifetime: the sampler's history
        // is still here when the screen is opened again.
        let shared = HostProbeModel.shared(
            for: host,
            runner: SSHCommandRunner(host: host, credentials: credentials, policy: .ask))
        probe = shared
        shared.pulse.start()
    }

    /// Whether the far end is a Mac, which is the one host Conterm can
    /// reach into: its panes, its tabs, the agents waiting in them.
    private var isMac: Bool {
        if host.distro == "macos" { return true }
        guard let probe, case .loaded(let info) = probe.phase else { return false }
        return info.os?.localizedCaseInsensitiveContains("macOS") == true
            || info.kernel?.hasPrefix("Darwin") == true
    }

    /// The controller, built lazily and only when there is something to
    /// control — most hosts have no container runtime at all.
    private func control(for runtime: ContainerRuntime?) -> ContainerControl? {
        guard let runtime else { return nil }
        if let containers { return containers }
        guard let credentials = KeyStore.shared.credentials(for: host) else { return nil }
        let made = ContainerControl(host: host, credentials: credentials, runtime: runtime)
        Task { @MainActor in containers = made }
        return made
    }

    // MARK: - Hero

    /// The machine's identity, drawn rather than listed: a monogram on a
    /// bed the colour of its health, the name beside it, what it runs
    /// beneath, and how it is doing in a word. Anything that needs saying
    /// follows as chips. On a Mac, the way into Conterm running there.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Mark(name: headline, distro: currentDistro, health: currentHealth)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(Theme.font(Theme.ui(30), .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .morph(on: headline, alignment: .leading)
                    Text(subheadline)
                        .font(Theme.font(Theme.ui(12.5), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .morph(on: subheadline, alignment: .leading)
                }
                Spacer(minLength: 0)
                if probe?.refreshing == true {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                        .transition(.morph)
                }
            }

            HStack(spacing: 8) {
                Text(currentHealth.summary)
                    .font(Theme.font(Theme.ui(13), .bold))
                    .foregroundStyle(currentHealth.color)
                    .morph(on: currentHealth.summary, alignment: .leading)
                if let stamp = ageStamp {
                    Text("·")
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    Text(stamp)
                        .font(Theme.font(Theme.ui(12), .medium))
                        .foregroundStyle(Theme.textSecondary.opacity(0.85))
                        .monospacedDigit()
                        .morph(on: stamp, alignment: .leading)
                }
            }

            let handoff = onHandoff != nil && !isMac && !Handoff.macs.isEmpty
            if !alerts.isEmpty || isMac || onFiles != nil || handoff {
                FlowLayout(spacing: 6) {
                    ForEach(Array(alerts.enumerated()), id: \.offset) { index, alert in
                        Bubble(alert.1, dot: alert.0.color)
                            .popIn(index, base: 0.15)
                    }
                    if isMac {
                        Button {
                            Haptics.shared.fire(.light)
                            showingMac = true
                        } label: {
                            Bubble("Conterm on this Mac", symbol: "macwindow", lit: true)
                        }
                        .buttonStyle(PressablePill(scale: 0.94))
                        .popIn(alerts.count, base: 0.15)
                    }
                    if let onFiles {
                        Button {
                            onFiles(host)
                        } label: {
                            Bubble("Files", symbol: "folder.fill", lit: true)
                        }
                        .buttonStyle(PressablePill(scale: 0.94))
                        .popIn(alerts.count + 1, base: 0.15)
                    }
                    if handoff, let onHandoff {
                        Button {
                            onHandoff(host)
                        } label: {
                            Bubble("Continue on Mac", symbol: "macbook.and.iphone")
                        }
                        .buttonStyle(PressablePill(scale: 0.94))
                        .popIn(alerts.count + 2, base: 0.15)
                    }
                }
                .transition(.morph)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .animation(Theme.Spring.morph, value: probe?.refreshing)
        .animation(Theme.Spring.morph, value: alerts.map { $0.1 })
        .rollUp()
    }

    // MARK: - Panels

    @ViewBuilder
    private func panels(_ info: HostInfo, pulse: HostPulse) -> some View {
        vitals(info, pulse: pulse).arrive(0).scrollMorph()
        if let triplet = info.loadAvg {
            loadPanel(triplet, cores: info.cores).arrive(1).scrollMorph()
        }
        systemPanel(info, pulse: pulse).arrive(2).scrollMorph()
        if !info.disks.isEmpty { disksPanel(info).arrive(3).scrollMorph() }
        if !info.ips.isEmpty || !info.listeningPorts.isEmpty {
            networkPanel(info, pulse: pulse).arrive(4).scrollMorph()
        }
        if let containers = info.containers, !containers.isEmpty {
            containersPanel(containers, info: info).arrive(5).scrollMorph()
        }
        if info.kubelet || info.kubeNodes != nil || (info.vms?.isEmpty == false) {
            workloadsPanel(info).arrive(6).scrollMorph()
        }
        if info.failedUnits != nil || info.cronEntries != nil
            || !info.timers.isEmpty || info.usersLoggedIn != nil
            || info.rebootRequired || info.updatesAvailable != nil {
            healthPanel(info).arrive(7).scrollMorph()
        }
        if !info.topProcs.isEmpty { busiestPanel(info).arrive(8).scrollMorph() }
        if !info.journalErrors.isEmpty || !info.kernelWarnings.isEmpty {
            errorsPanel(info).arrive(9).scrollMorph()
        }
    }

    /// The two numbers that decide whether the machine is fine, and under
    /// them the chart: every few seconds a line from the least busy core to
    /// the busiest, so a machine with one hot core and seven idle ones
    /// looks different from one that is evenly loaded.
    private func vitals(_ info: HostInfo, pulse: HostPulse) -> some View {
        let latest = pulse.latest
        let memory: Double? = latest?.memory ?? {
            guard let total = info.memTotalMB, let avail = info.memAvailMB, total > 0
            else { return nil }
            return Double(total - avail) / Double(total)
        }()
        let cpu = latest?.cpu
        let spread = pulse.samples.compactMap { s -> PulseChart.Sample? in
            guard let lo = s.coreLow, let hi = s.coreHigh else { return nil }
            return PulseChart.Sample(low: lo, high: hi)
        }
        let oneNumber = latest.map { $0.coreLow == $0.coreHigh } ?? false

        return Button {
            open(.vitals)
        } label: {
            vitalsCard(info, pulse: pulse, cpu: cpu, memory: memory, spread: spread,
                       oneNumber: oneNumber)
        }
        .buttonStyle(PressablePill(scale: 0.98))
        .matchedTransitionSource(id: OverviewDetail.vitals.zoomID, in: zoom) {
            $0.clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    private func open(_ which: OverviewDetail) {
        Haptics.shared.fire(.light)
        detail = which
    }

    /// The glyph on a panel that opens into more: a small glass circle.
    private var expandGlyph: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: Theme.ui(10), weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Theme.ui(26), height: Theme.ui(26))
            .glassPill()
    }

    private func vitalsCard(_ info: HostInfo, pulse: HostPulse, cpu: Double?, memory: Double?,
                            spread: [PulseChart.Sample], oneNumber: Bool) -> some View {
        Panel("Vitals", symbol: "waveform.path.ecg", bed: .ink) {
            HStack(alignment: .top, spacing: 18) {
                Readout(value: cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                        label: "CPU",
                        symbol: "cpu",
                        detail: info.cores.map { "\($0) core\($0 == 1 ? "" : "s")" }
                            ?? (cpu == nil ? "sampling\u{2026}" : " "),
                        fraction: cpu ?? 0,
                        tint: vitalTint(cpu, overload: HostHealth.overloaded(info)),
                        size: 44,
                        muted: cpu == nil)
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 70).padding(.top, 8)
                Readout(value: memory.map { "\(Int($0 * 100))%" } ?? "—",
                        label: "Memory",
                        symbol: "memorychip",
                        detail: info.memTotalMB.map { fmtMB($0) } ?? " ",
                        fraction: memory ?? 0,
                        tint: vitalTint(memory),
                        size: 44,
                        muted: memory == nil)
            }
            PulseChart(samples: spread,
                       capacity: HostPulse.capacity,
                       height: 110,
                       topLabel: "100%",
                       bottomLabel: "0",
                       timeLabels: ["4m ago", "3m", "2m", "1m", "now"])
                .padding(.top, 4)
            HStack {
                Text(oneNumber ? "whole machine" : "least and busiest core")
                    .morph(on: oneNumber, alignment: .leading)
                Spacer()
                Text(pulse.failed ? "no answer" : "every few seconds")
                    .morph(on: pulse.failed, alignment: .trailing)
            }
            .font(Theme.font(Theme.ui(10.5), .medium))
            .foregroundStyle(Theme.textSecondary.opacity(0.85))
        } accessory: {
            HStack(spacing: 8) {
                if pulse.samples.isEmpty {
                    ProgressView().controlSize(.mini).tint(Theme.textSecondary)
                        .transition(.morph)
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.Status.ready).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(Theme.font(Theme.ui(10), .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .transition(.morph)
                }
                expandGlyph
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .animation(Theme.Spring.morph, value: pulse.samples.isEmpty)
    }

    /// The load triplet as three capsules: one, five and fifteen minutes,
    /// the current minute solid. Full height is one core per unit of load,
    /// so a bar that reaches the top is a machine with no headroom. This is
    /// the one number on the screen with a direction, and three bars say
    /// "climbing" or "settling" faster than three decimals do.
    private func loadPanel(_ load: (Double, Double, Double), cores: Int?) -> some View {
        let top = Double(max(cores ?? 1, 1))
        return Panel("Load", symbol: "gauge.with.dots.needle.33percent", bed: .cream) {
            HStack(alignment: .top, spacing: 18) {
                Readout(value: String(format: "%.2f", load.0), label: "1 min",
                        symbol: "gauge.with.dots.needle.33percent",
                        detail: cores.map { "of \($0) core\($0 == 1 ? "" : "s")" } ?? " ",
                        fraction: min(load.0 / top, 1),
                        tint: vitalTint(min(load.0 / top, 1), overload: load.0 > top),
                        size: 44)
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 70).padding(.top, 8)
                Readout(value: String(format: "%.2f", load.2), label: "15 min",
                        symbol: "clock",
                        detail: load.2 > load.0 ? "settling" : (load.2 < load.0 ? "climbing" : "steady"),
                        fraction: min(load.2 / top, 1),
                        tint: vitalTint(min(load.2 / top, 1)),
                        size: 44)
            }
            CapsuleBars(bars: [.init(id: "1", label: "1m", value: load.0),
                               .init(id: "5", label: "5m", value: load.1),
                               .init(id: "15", label: "15m", value: load.2)],
                        highlight: "1",
                        maximum: top,
                        height: 72,
                        barWidth: 14,
                        spacing: 12,
                        alignment: .leading)
                .padding(.top, 4)
            HStack {
                Text(cores.map { "full bar = \($0) core\($0 == 1 ? "" : "s")" } ?? "full bar = one core")
                Spacer()
                Text(String(format: "5 min %.2f", load.1))
                    .monospacedDigit()
            }
            .font(Theme.font(Theme.ui(10.5), .medium))
            .foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
    }

    /// The machine as one panel: its three shares as concentric rings —
    /// disk, memory, CPU — and beside them the facts that are numbers but
    /// not shares: how long it has been up, who is on it, what is broken,
    /// what is listening.
    private func systemPanel(_ info: HostInfo, pulse: HostPulse) -> some View {
        let disk = info.disks.max { $0.pct < $1.pct }
        let memory: Double? = pulse.latest?.memory ?? {
            guard let total = info.memTotalMB, let avail = info.memAvailMB, total > 0
            else { return nil }
            return Double(total - avail) / Double(total)
        }()
        let cpu = pulse.latest?.cpu
        var slices: [RingStack.Slice] = []
        if let disk {
            slices.append(.init(id: "disk", label: "Disk", fraction: disk.pct,
                                tint: Color(red: 0.14, green: 0.47, blue: 0.98),
                                text: "\(Int(disk.pct * 100))%"))
        }
        if let memory {
            slices.append(.init(id: "memory", label: "Memory", fraction: memory,
                                tint: Color(red: 0.52, green: 0.33, blue: 0.95),
                                text: "\(Int(memory * 100))%"))
        }
        if let cpu {
            slices.append(.init(id: "cpu", label: "CPU", fraction: cpu,
                                tint: Color(red: 0.03, green: 0.58, blue: 0.64),
                                text: "\(Int((cpu * 100).rounded()))%"))
        }
        var facts: [(String, String, String)] = []
        if let uptime = info.uptime { facts.append(("clock", "Up", Self.shortUptime(uptime))) }
        if let users = info.usersLoggedIn { facts.append(("person.2", "Logged in", "\(users)")) }
        if let failed = info.failedUnits {
            facts.append(("exclamationmark.triangle", "Failed units", "\(failed)"))
        }
        if !info.listeningPorts.isEmpty {
            facts.append(("antenna.radiowaves.left.and.right", "Listening", "\(info.listeningPorts.count)"))
        }
        if let crons = info.cronEntries { facts.append(("calendar", "Cron entries", "\(crons)")) }
        if let containers = info.containers, !containers.isEmpty {
            facts.append(("shippingbox", "Running", "\(containers.filter(\.running).count)"))
        }

        return Panel("System", symbol: "cpu", bed: .cream) {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    RingStack(slices: slices, size: 150, lineWidth: 13, gap: 5)
                    if let first = slices.first {
                        VStack(spacing: 0) {
                            Text(first.text ?? "")
                                .font(Theme.font(Theme.ui(22), .heavy))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                                .morph(on: first.text ?? "")
                            Text(first.label)
                                .font(Theme.font(Theme.ui(10), .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(slices) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.tint).frame(width: 8, height: 8)
                            Text(slice.label)
                                .font(Theme.font(Theme.ui(12.5), .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 4)
                            Text(slice.text ?? "")
                                .font(Theme.font(Theme.ui(14), .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                                .morph(on: slice.text ?? "", alignment: .trailing)
                        }
                    }
                }
            }
            if !facts.isEmpty {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                        HStack(spacing: 8) {
                            Image(systemName: fact.0)
                                .font(.system(size: Theme.ui(11), weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fact.2)
                                    .font(Theme.font(Theme.ui(17), .heavy))
                                    .foregroundStyle(Theme.textPrimary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .morph(on: fact.2, alignment: .leading)
                                Text(fact.1)
                                    .font(Theme.font(Theme.ui(10.5), .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .popIn(index, base: 0.3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(disk.map { "fullest disk \($0.mount)" } ?? "the machine")
                Spacer()
                Text("rings are shares of the whole")
            }
            .font(Theme.font(Theme.ui(10.5), .medium))
            .foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
    }

    private func disksPanel(_ info: HostInfo) -> some View {
        Panel("Disks", symbol: "internaldrive", bed: .azure) {
            VStack(spacing: 18) {
                ForEach(Array(info.disks.enumerated()), id: \.element.mount) { index, disk in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(disk.mount)
                                .font(Theme.font(Theme.ui(14), .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(fmtKB(disk.usedKB)) of \(fmtKB(disk.totalKB))")
                                .font(Theme.font(Theme.ui(11), .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }
                        CapsuleRamp(fraction: disk.pct, count: 18, maxHeight: 30,
                                    tint: disk.pct > 0.9 ? Theme.Status.danger
                                        : disk.pct > 0.8 ? Theme.Status.attention : Theme.meter,
                                    labels: index == info.disks.count - 1
                                        ? ["0", "25%", "50%", "75%", "100%"] : [])
                    }
                    .popIn(index, base: 0.3)
                }
            }
        } accessory: {
            if let worst = info.disks.max(by: { $0.pct < $1.pct }) {
                Text("\(Int(worst.pct * 100))% at most")
                    .font(Theme.font(Theme.ui(10.5), .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    /// Addresses and ports from the probe; traffic from the pulse, as a
    /// line, once there is any.
    private func networkPanel(_ info: HostInfo, pulse: HostPulse) -> some View {
        let rates = pulse.samples.compactMap { s -> (rx: Double, tx: Double)? in
            guard let rx = s.rxPerSec, let tx = s.txPerSec else { return nil }
            return (rx, tx)
        }
        let peak = max(rates.map { max($0.rx, $0.tx) }.max() ?? 0, 1)
        let padding = max(HostPulse.capacity - rates.count, 0)
        let rx = Array(repeating: 0.0, count: padding) + rates.map { $0.rx / peak }
        let tx = Array(repeating: 0.0, count: padding) + rates.map { $0.tx / peak }
        let down = formatRate(rates.last?.rx ?? 0)
        let up = formatRate(rates.last?.tx ?? 0)

        return Button {
            open(.network)
        } label: {
            networkCard(info, rates: rates, rx: rx, tx: tx, down: down, up: up)
        }
        .buttonStyle(PressablePill(scale: 0.98))
        .matchedTransitionSource(id: OverviewDetail.network.zoomID, in: zoom) {
            $0.clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    private func networkCard(_ info: HostInfo, rates: [(rx: Double, tx: Double)],
                             rx: [Double], tx: [Double],
                             down: (value: String, unit: String),
                             up: (value: String, unit: String)) -> some View {
        let peak = max(rates.map { max($0.rx, $0.tx) }.max() ?? 0, 1)
        return Panel("Network", symbol: "antenna.radiowaves.left.and.right", bed: .teal) {
            HStack(alignment: .top, spacing: 18) {
                Readout(value: down.value, label: "In", symbol: "arrow.down",
                        detail: down.unit, fraction: (rates.last?.rx ?? 0) / peak,
                        size: 44, muted: rates.isEmpty)
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 70).padding(.top, 8)
                Readout(value: up.value, label: "Out", symbol: "arrow.up",
                        detail: up.unit, fraction: (rates.last?.tx ?? 0) / peak,
                        size: 44, muted: rates.isEmpty)
            }
            LineChart(values: rx, secondary: tx, height: 72)
                .padding(.top, 4)
            HStack {
                Text(rates.isEmpty ? "sampling\u{2026}" : "in, and out, every interface")
                Spacer()
                Text("\(info.ips.count) address\(info.ips.count == 1 ? "" : "es") · \(info.listeningPorts.count) listening")
                    .monospacedDigit()
            }
            .font(Theme.font(Theme.ui(10.5), .medium))
            .foregroundStyle(Theme.textSecondary.opacity(0.85))
        } accessory: {
            expandGlyph
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .animation(Theme.Spring.morph, value: rates.isEmpty)
    }

    /// Containers as bubbles: the running ones lit, the stopped ones dim,
    /// each a tap away from the two or three things you would do to it.
    private func containersPanel(_ containers: [HostInfo.Container], info: HostInfo) -> some View {
        let running = containers.filter(\.running).count
        return Panel(info.containerRuntime?.displayName ?? "Containers", symbol: "shippingbox",
                     bed: .violet) {
            FlowLayout(spacing: 8) {
                ForEach(Array(containers.prefix(40).enumerated()), id: \.element.name) { index, c in
                    ContainerBubble(container: c,
                                    control: control(for: info.containerRuntime),
                                    onAsk: { action in pendingAction = (c.name, action) })
                        .popIn(index, base: 0.3)
                }
                if containers.count > 40 {
                    Bubble("+\(containers.count - 40) more")
                }
            }
        } accessory: {
            Text("\(running) of \(containers.count) up")
                .font(Theme.font(Theme.ui(10.5), .semibold))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .rollingDigits(on: running)
        }
    }

    private func workloadsPanel(_ info: HostInfo) -> some View {
        Panel("Workloads", symbol: "square.stack.3d.up", bed: .grass) {
            if info.kubelet { Row("Kubelet", "active") }
            if let nodes = info.kubeNodes { Row("Cluster nodes", "\(nodes)") }
            if let vms = info.vms, !vms.isEmpty { Row("VMs", vms.joined(separator: "  ")) }
        }
    }

    private func healthPanel(_ info: HostInfo) -> some View {
        let worried = (info.failedUnits ?? 0) > 0 || info.rebootRequired || info.updatesAvailable != nil
        return Panel("Health", symbol: "heart.text.square", bed: worried ? .amber : .grass) {
            if let failed = info.failedUnits, !info.failedNames.isEmpty {
                Row("Failed units", "\(failed)", tint: Theme.Status.danger)
                Row("", info.failedNames.joined(separator: "  "))
            }
            if let crons = info.cronEntries { Row("Cron entries", "\(crons)") }
            if let users = info.usersLoggedIn { Row("Logged in", "\(users)") }
            if info.rebootRequired { Row("Reboot", "required", tint: Theme.Status.attention) }
            if let updates = info.updatesAvailable {
                Row("Updates", updates, tint: Theme.Status.attention)
            }
        }
    }

    /// The five busiest processes: the hungriest as a number, then every
    /// one as a bar the length of its share, ranked.
    private func busiestPanel(_ info: HostInfo) -> some View {
        let procs = Array(info.topProcs.prefix(5))
        let top = procs.first
        let hungriestMemory = info.topProcs.max { (Double($0.mem) ?? 0) < (Double($1.mem) ?? 0) }
        return Panel("Busiest", symbol: "flame", bed: .cream) {
            HStack(alignment: .top, spacing: 18) {
                Readout(value: top.map { "\($0.cpu)%" } ?? "—", label: "CPU", symbol: "flame",
                        detail: top?.name ?? " ",
                        fraction: (top.flatMap { Double($0.cpu) } ?? 0) / 100, size: 44)
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 70).padding(.top, 8)
                Readout(value: hungriestMemory.map { "\($0.mem)%" } ?? "—", label: "Memory",
                        symbol: "memorychip",
                        detail: hungriestMemory?.name ?? " ",
                        fraction: (hungriestMemory.flatMap { Double($0.mem) } ?? 0) / 100, size: 44)
            }
            RankBars(rows: procs.enumerated().map { index, p in
                RankBars.Row(id: "\(index)-\(p.name)", label: p.name,
                             value: Double(p.cpu) ?? 0, text: "\(p.cpu)%")
            }, maximum: 100)
                .padding(.top, 4)
            HStack {
                Text("by cpu, right now")
                Spacer()
                Text("\(procs.count) of the busiest")
            }
            .font(Theme.font(Theme.ui(10.5), .medium))
            .foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
    }

    private func errorsPanel(_ info: HostInfo) -> some View {
        Panel("Recent errors", symbol: "exclamationmark.bubble", bed: .ink) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((info.journalErrors + info.kernelWarnings).prefix(8).enumerated()),
                        id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: Theme.ui(10.5), design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .popIn(index, base: 0.3)
                }
            }
        }
    }

    /// "2 days, 15:53" reads as a sentence; "2d 15h" reads as a number,
    /// which is what a tile wants. Anything the pattern doesn't match is
    /// shown as it came.
    static func shortUptime(_ raw: String) -> String {
        let scanner = raw.trimmingCharacters(in: .whitespaces)
        if let m = scanner.firstMatch(of: /(\d+) days?, (\d+):(\d+)/) {
            return "\(m.1)d \(m.2)h"
        }
        if let m = scanner.firstMatch(of: /^(\d+):(\d+)$/) {
            return "\(m.1)h \(m.2)m"
        }
        return scanner
    }

    /// Amber past 80%, red past 90% or when the load says so — visible
    /// without reading the number.
    private func vitalTint(_ fraction: Double?, overload: Bool = false) -> Color {
        if overload { return Theme.Status.danger }
        guard let fraction else { return Theme.textSecondary }
        if fraction > 0.9 { return Theme.Status.danger }
        if fraction > 0.8 { return Theme.Status.attention }
        return Theme.meter
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

    /// Which of the three states the body is showing. A refresh that lands
    /// on the same state morphs the values, not the screen.
    private var phaseKey: Int {
        guard let probe else { return failure == nil ? 0 : 1 }
        switch probe.phase {
        case .loading: return 0
        case .failed: return 1
        case .loaded: return 2
        }
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

    // MARK: - States

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.accent)
            Text("Asking \(host.hostname)…")
                .font(Theme.font(Theme.ui(13), .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 30)
        .transition(.morph)
    }

    private func errorMessage(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(Theme.ui(12), .medium))
            .foregroundStyle(Theme.Status.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 24)
            .transition(.morph)
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

/// Content scrolls under the bar at the top, and the bar's buttons float
/// over it. This softens what passes beneath them: a progressive blur in
/// the top inset, so the name never collides with the back button.
private struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.black, .black, .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: 34)
                    .padding(.top, -34)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func softTopEdge() -> some View { modifier(SoftTopEdge()) }
}

/// The mark of what the host runs, monochrome and plain, with the health
/// gem on its corner; the host's initial where the distribution is unknown.
private struct Mark: View {
    let name: String
    var distro: Distro?
    let health: HostHealth

    var body: some View {
        Group {
            if let distro {
                DistroMark(distro: distro, size: Theme.ui(46))
            } else {
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(Theme.font(Theme.ui(40), .heavy))
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(width: Theme.ui(54), height: Theme.ui(54))
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(health.color)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Theme.Ground.top, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
        .morph(on: distro?.rawValue ?? name)
        .animation(Theme.Spring.morph, value: health)
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
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 96, alignment: .leading)
            } else {
                Spacer().frame(width: 96)
            }
            Text(value)
                .font(Theme.font(Theme.ui(12), .medium))
                .foregroundStyle(tint ?? Theme.textPrimary)
                .monospacedDigit()
                .morph(on: value, alignment: .leading)
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
        if fraction > 0.8 { return Theme.Status.attention }
        return Theme.meter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(detail)
                    .font(Theme.font(Theme.ui(11)))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            MeterBar(fraction: fraction, tint: tint)
        }
        .padding(.vertical, 4)
    }
}

/// Alert chips that wrap: a translucent tile with the status as a dot, so
/// they read on the ground whatever colour the status is.
private struct FlowChips: View {
    let items: [(String, Color)]

    init(_ items: [(String, Color)]) { self.items = items }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Bubble(item.0, dot: item.1)
                    .popIn(index, base: 0.15)
            }
        }
    }
}

/// One container as a bubble, with the two or three things you would do
/// to it behind a tap.
///
/// Start is immediate; stop and restart ask first. A running container is
/// serving something, and on a phone the targets are small and one-handed —
/// a confirmation there is not politeness, it is the only thing between a
/// mis-scroll and an outage.
private struct ContainerBubble: View {
    let container: HostInfo.Container
    let control: ContainerControl?
    let onAsk: (ContainerControl.Action) -> Void

    private var busy: Bool { control?.busy.contains(container.name) == true }

    var body: some View {
        Group {
            if let control {
                Menu {
                    ForEach(available, id: \.self) { action in
                        Button(action.title, systemImage: action.symbol,
                               role: action.isDisruptive ? .destructive : nil) {
                            if action.isDisruptive {
                                onAsk(action)
                            } else {
                                Haptics.shared.fire(.light)
                                Task { await control.perform(action, on: container.name) }
                            }
                        }
                    }
                } label: {
                    label
                }
                .buttonStyle(PressablePill(scale: 0.92))
            } else {
                label
            }
        }
        .animation(Theme.Spring.morph, value: busy)
    }

    private var label: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(container.running ? Theme.Status.ready : Theme.textSecondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(container.name)
                .font(Theme.font(Theme.ui(13), .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if busy {
                ProgressView().controlSize(.mini).tint(Theme.textSecondary)
                    .transition(.morph)
            } else {
                Text(Self.shortStatus(container.status))
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .morph(on: container.status, alignment: .leading)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .glassPill(selected: container.running)
        .contentShape(Capsule(style: .continuous))
    }

    /// Offering "start" for something already running is an invitation to
    /// find out what happens, which is not what this screen is for.
    private var available: [ContainerControl.Action] {
        container.running ? [.restart, .stop] : [.start]
    }

    /// "Up 3 hours" is a sentence; "3h" is a bubble. "Exited (0) 2 days ago"
    /// becomes "exited 2d".
    static func shortStatus(_ status: String) -> String {
        var s = status.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("up ") { s = String(s.dropFirst(3)) }
        else if s.lowercased().hasPrefix("exited") {
            s = "exited " + s.replacingOccurrences(of: #"Exited \(\d+\) "#, with: "",
                                                   options: .regularExpression)
                .replacingOccurrences(of: " ago", with: "")
        }
        s = s.replacingOccurrences(of: "About ", with: "")
             .replacingOccurrences(of: "about ", with: "")
             .replacingOccurrences(of: "Less than a second", with: "0s")
        let units: [(String, String)] = [(" seconds", "s"), (" second", "s"),
                                         (" minutes", "m"), (" minute", "m"),
                                         (" hours", "h"), (" hour", "h"),
                                         (" days", "d"), (" day", "d"),
                                         (" weeks", "w"), (" week", "w"),
                                         (" months", "mo"), (" month", "mo")]
        for (long, short) in units { s = s.replacingOccurrences(of: long, with: short) }
        return s.replacingOccurrences(of: " (healthy)", with: " ✓")
    }
}
