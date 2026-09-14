import SwiftUI

/// A panel, opened. The number the panel was about, enormous, with its
/// unit small beside it and the facts around it small; then a cream card
/// with the picture drawn large and the rows the panel had no room for.
/// The big-and-small grammar the whole app uses, at its biggest.
struct PanelDetail<Facts: View, Card: View>: View {
    let title: String
    let symbol: String
    let value: String
    var unit: String?
    let caption: String
    /// The bed the panel had: the detail is the panel, grown to the
    /// screen, so it keeps the panel's colour under everything.
    var bed: PanelBed = .ink
    @ViewBuilder let facts: Facts
    @ViewBuilder let card: Card

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelLabel(title, symbol: symbol)
                    .padding(.horizontal, 4)
                    .rollUp()

                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(value)
                        .font(Theme.font(Theme.ui(96), .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .morph(on: value, alignment: .leading)
                    if let unit {
                        Text(unit)
                            .font(Theme.font(Theme.ui(28), .bold))
                            .foregroundStyle(Theme.textPrimary.opacity(0.85))
                            .morph(on: unit, alignment: .leading)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 2)
                .rollUp(delay: 0.05)

                Text(caption)
                    .font(Theme.font(Theme.ui(16), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
                    .morph(on: caption, alignment: .leading)
                    .rollUp(delay: 0.1)

                // The facts as columns under a hairline, each a word over a
                // number, every column starting at the same edge.
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                    .padding(.top, 22)
                HStack(alignment: .top, spacing: 16) {
                    facts
                }
                .padding(.top, 16)
                .padding(.horizontal, 4)
                .rollUp(delay: 0.14)

                VStack(alignment: .leading, spacing: 18) {
                    card
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(DetailCard(onCream: bed.isLight))
                .padding(.top, 28)
                .arrive(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .contermReadableColumn()
        }
        .softTopEdge()
        .background((bed.fill ?? Theme.inkBed).ignoresSafeArea())
        .environment(\.colorScheme, bed.isLight ? .light : .dark)
        .tint(bed.isLight ? Theme.Brand.crimson : Theme.Brand.cream)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// The card inside a detail: cream on a coloured detail, white on a cream
/// one, so the two never blend.
private struct DetailCard: ViewModifier {
    var onCream: Bool

    func body(content: Content) -> some View {
        if onCream {
            content
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.sheetCorner, style: .continuous))
                .environment(\.colorScheme, .light)
                .tint(Theme.Brand.ink)
                .shadow(color: .black.opacity(0.10), radius: 24, y: 10)
        } else {
            content.creamCard(cornerRadius: Theme.sheetCorner)
        }
    }
}

/// One of the facts under the big number: a word over a value, both from
/// the same left edge, in a column that shares the row equally.
struct DetailFact: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.font(Theme.ui(13), .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(Theme.font(Theme.ui(24), .bold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .morph(on: value, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row inside a detail's cream card: a name, a note, a number.
struct DetailRow: View {
    let title: String
    var note: String?
    var value: String?
    var dot: Color?

    var body: some View {
        HStack(spacing: 10) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font(Theme.ui(15), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(Theme.font(Theme.ui(12), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .morph(on: value, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The traffic, opened: the rate now, enormous; the peak and the window's
/// totals; the line drawn large; every open shell with what has passed
/// through it.
struct ActivityDetail: View {
    let traffic: TrafficMeter
    @Environment(HomeRouter.self) private var router
    private var sessions: SessionStore { SessionStore.shared }

    var body: some View {
        let now = formatRate(traffic.now)
        let peak = formatRate(traffic.peak)
        let samples = traffic.samples
        let top = max(traffic.peak, 1)
        let padding = max(TrafficMeter.capacity - samples.count, 0)
        let totals = Array(repeating: 0.0, count: padding) + samples.map { $0.total / top }
        let outs = Array(repeating: 0.0, count: padding) + samples.map { $0.outPerSec / top }
        let live = sessions.live

        PanelDetail(title: "Activity", symbol: HomePanelKind.activity.symbol,
                    value: now.value, unit: now.unit,
                    caption: live.isEmpty ? "through no shells, right now"
                        : "through \(live.count) shell\(live.count == 1 ? "" : "s"), right now",
                    bed: .azure) {
            HStack(alignment: .top, spacing: 16) {
                DetailFact(value: "\(peak.value) \(peak.unit)", label: "Peak")
                DetailFact(value: formatBytes(traffic.windowIn), label: "In, 2 min")
                DetailFact(value: formatBytes(traffic.windowOut), label: "Out, 2 min")
            }
        } card: {
            HStack(alignment: .firstTextBaseline) {
                Text("Last two minutes")
                    .font(Theme.font(Theme.ui(18), .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                HStack(spacing: 12) {
                    legend("in", strong: true)
                    legend("out", strong: false)
                }
            }
            LineChart(values: totals, secondary: outs, height: 170, lineWidth: 3)
            HStack {
                Text("2m ago"); Spacer(); Text("1m"); Spacer(); Text("now")
            }
            .font(Theme.font(Theme.ui(11), .medium))
            .foregroundStyle(Theme.textSecondary)

            if !live.isEmpty {
                Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.top, 4)
                Text("Open shells")
                    .font(Theme.font(Theme.ui(13), .bold))
                    .foregroundStyle(Theme.textSecondary)
                VStack(spacing: 2) {
                    ForEach(Array(live.enumerated()), id: \.element.id) { index, shell in
                        Button {
                            router.resume(shell)
                        } label: {
                            DetailRow(title: shell.title ?? shell.host.alias,
                                      note: shell.host.displaySubtitle,
                                      value: "↓ \(formatBytes(Double(shell.bytesIn)))  ↑ \(formatBytes(Double(shell.bytesOut)))",
                                      dot: Theme.Status.ready)
                        }
                        .buttonStyle(PressableRow())
                        .popIn(index, base: 0.35)
                    }
                }
            } else {
                Text("Open a shell and every byte through it is drawn here, in and out.")
                    .font(Theme.font(Theme.ui(13), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ text: String, strong: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(Theme.meter.opacity(strong ? 1 : 0.45)).frame(width: 14, height: 3)
            Text(text)
                .font(Theme.font(Theme.ui(11), .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// The fleet, opened: how many hosts, enormous; the groups as bars, the
/// groups as rows, the keys and the Macs nearby.
struct FleetDetail: View {
    let store: HostStore
    let groups: HostGroupStore
    let nearby: NearbyMacs
    @Environment(HomeRouter.self) private var router
    private var sessions: SessionStore { SessionStore.shared }

    private var bars: [CapsuleBars.Bar] {
        var out = groups.ordered.map { group in
            CapsuleBars.Bar(id: group.id.uuidString, label: group.name,
                            value: Double(store.hosts.filter { $0.groupID == group.id }.count))
        }
        .filter { $0.value > 0 }
        let loose = store.hosts.filter { $0.groupID == nil || groups.group(id: $0.groupID) == nil }
        if !loose.isEmpty {
            out.append(.init(id: "loose", label: "Ungrouped", value: Double(loose.count)))
        }
        return out.sorted { $0.value > $1.value }
    }

    var body: some View {
        let withKey = store.hosts.filter { KeyStore.shared.hasSecret(for: $0) }.count
        PanelDetail(title: "Fleet", symbol: HomePanelKind.fleet.symbol,
                    value: "\(store.hosts.count)",
                    unit: store.hosts.count == 1 ? "host" : "hosts",
                    caption: "saved on this phone", bed: .cream) {
            HStack(alignment: .top, spacing: 16) {
                DetailFact(value: "\(sessions.live.count)", label: "Live now")
                DetailFact(value: "\(groups.groups.count)", label: "Groups")
                DetailFact(value: "\(KeyLibrary.shared.keys.count)", label: "Keys")
            }
        } card: {
            HStack(alignment: .firstTextBaseline) {
                Text("By group")
                    .font(Theme.font(Theme.ui(18), .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(withKey) of \(store.hosts.count) can connect")
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            if bars.isEmpty {
                Text("No hosts yet.")
                    .font(Theme.font(Theme.ui(13), .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                CapsuleBars(bars: bars, highlight: bars.first?.id, height: 110,
                            barWidth: 16, spacing: 12, labels: .legend, alignment: .leading)
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                VStack(spacing: 2) {
                    ForEach(Array(groups.ordered.enumerated()), id: \.element.id) { index, group in
                        let members = store.hosts.filter { $0.groupID == group.id }
                        DetailRow(title: group.name,
                                  note: members.map(\.alias).prefix(4).joined(separator: ", ")
                                      + (members.count > 4 ? ", …" : ""),
                                  value: "\(members.count)",
                                  dot: group.color)
                            .popIn(index, base: 0.35)
                    }
                    let loose = store.hosts.filter { $0.groupID == nil || groups.group(id: $0.groupID) == nil }
                    if !loose.isEmpty {
                        DetailRow(title: "Ungrouped",
                                  note: loose.map(\.alias).prefix(4).joined(separator: ", ")
                                      + (loose.count > 4 ? ", …" : ""),
                                  value: "\(loose.count)",
                                  dot: Theme.Status.neutral)
                            .popIn(groups.ordered.count, base: 0.35)
                    }
                }
            }
            if !nearby.found.isEmpty {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                DetailRow(title: "Nearby", note: "Macs running Conterm on this network",
                          value: "\(nearby.found.count)", dot: Theme.Status.working)
            }
            HStack(spacing: 8) {
                Button("Add host") { router.route = .newHost }
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .filledPill(height: Theme.ui(40))
                    .buttonStyle(PressablePill())
                Button("Import ssh config") { router.importing = true }
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .softPill(height: Theme.ui(40))
                    .buttonStyle(PressablePill())
            }
            .padding(.top, 4)
        }
    }
}

/// Bytes, the way a person says them.
func formatBytes(_ bytes: Double) -> String {
    let b = max(bytes, 0)
    if b < 1024 { return "\(Int(b)) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / 1024 / 1024) }
    return String(format: "%.2f GB", b / 1024 / 1024 / 1024)
}

/// The world, opened: the map large, then every placed host with its local
/// time and how far it is from here.
struct WorldDetail: View {
    let store: HostStore
    @State private var now = Date()

    var body: some View {
        let pins = WorldPins.pins(for: store.hosts, at: now)
        let placed = store.hosts.filter { HostProbeModel.cachedInfo(for: $0)?.info.utcOffsetMinutes != nil }
        let zones = Set(placed.compactMap { HostProbeModel.cachedInfo(for: $0)?.info.utcOffsetMinutes }).count
        PanelDetail(title: "World", symbol: HomePanelKind.world.symbol,
                    value: "\(placed.count)", unit: placed.count == 1 ? "host" : "hosts",
                    caption: zones == 0 ? "nowhere yet"
                        : "in \(zones) time zone\(zones == 1 ? "" : "s"), right now",
                    bed: .teal) {
            HStack(alignment: .top, spacing: 16) {
                DetailFact(value: now.formatted(.dateTime.hour().minute()), label: "Here")
                DetailFact(value: "\(store.hosts.count)", label: "Saved")
            }
        } card: {
            HStack(alignment: .firstTextBaseline) {
                Text("Day and night")
                    .font(Theme.font(Theme.ui(18), .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("the sun, right now")
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            WorldMap(pins: pins, dot: Theme.Brand.ink.opacity(0.55),
                     night: Theme.Brand.ink.opacity(0.18), date: now)
            if !placed.isEmpty {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                VStack(spacing: 2) {
                    ForEach(Array(placed.enumerated()), id: \.element.id) { index, host in
                        let info = HostProbeModel.cachedInfo(for: host)?.info
                        DetailRow(title: host.alias,
                                  note: info?.timeZoneID ?? "by its clock",
                                  value: info.flatMap { WorldPins.localTime($0, at: now) } ?? "—",
                                  dot: info.map { HostHealth.of($0).color })
                            .popIn(index, base: 0.35)
                    }
                }
            } else {
                Text("Open a host's overview once and it takes its place on the map, with its own clock.")
                    .font(Theme.font(Theme.ui(13), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }
}

/// The heartbeat, opened: every beating host in a tall lane with its own
/// axis, its CPU and memory now.
struct HeartbeatDetail: View {
    let store: HostStore

    private var lanes: [(host: Host, model: HostProbeModel)] {
        HostProbeModel.active.compactMap { entry in
            guard let host = store.hosts.first(where: { $0.id == entry.hostID }),
                  !entry.model.pulse.samples.isEmpty else { return nil }
            return (host, entry.model)
        }
        .sorted { $0.host.alias < $1.host.alias }
    }

    var body: some View {
        let lanes = lanes
        let busiest = lanes.compactMap { $0.model.pulse.latest?.cpu }.max()
        PanelDetail(title: "Heartbeat", symbol: HomePanelKind.heartbeat.symbol,
                    value: "\(lanes.count)", unit: lanes.count == 1 ? "host" : "hosts",
                    caption: lanes.isEmpty ? "no hearts beating"
                        : "beating, every few seconds",
                    bed: .grass) {
            HStack(alignment: .top, spacing: 16) {
                DetailFact(value: busiest.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                           label: "Busiest now")
                DetailFact(value: "\(Int(HostPulse.linger.components.seconds / 60))m",
                           label: "Kept after leaving")
            }
        } card: {
            if lanes.isEmpty {
                Text("Open a host's overview and its sampler starts. It keeps going for five minutes after you leave, and every beating host is drawn here.")
                    .font(Theme.font(Theme.ui(13), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 22) {
                    ForEach(Array(lanes.enumerated()), id: \.element.host.id) { index, lane in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(lane.host.alias)
                                    .font(Theme.font(Theme.ui(18), .bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if let mem = lane.model.pulse.latest?.memory {
                                    Text("memory \(Int(mem * 100))%")
                                        .font(Theme.font(Theme.ui(12), .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .monospacedDigit()
                                }
                            }
                            HeartbeatLane(host: lane.host, pulse: lane.model.pulse,
                                          height: 110, labelled: true)
                        }
                        .popIn(index, base: 0.3)
                        if index < lanes.count - 1 {
                            Rectangle().fill(Theme.stroke).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }
}
