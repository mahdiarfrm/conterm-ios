import SwiftUI

/// The home tab: the shell deck, then the panels the user has chosen, in
/// their order, each arriving after the last. Every panel follows the same
/// grammar as the overview's vitals: a small label with a glyph, one or two
/// numbers large with a meter beneath each, the picture, and a caption row.
struct HomePanelsView: View {
    let store: HostStore
    let groups: HostGroupStore
    let nearby: NearbyMacs
    let traffic: TrafficMeter
    let zoom: Namespace.ID
    /// Room left at the top for the bar the panels scroll under.
    var topInset: CGFloat = 0
    /// How far the column has scrolled under the bar, reported up so the
    /// bar's scrim can come in with it.
    var scrolled: Binding<CGFloat>?

    @Environment(HomeRouter.self) private var router
    @State private var prefs = Preferences.shared
    /// The clock the world map and the local times read; a minute is
    /// enough, and it only ticks while the home is on screen.
    @State private var now = Date()
    private var sessions: SessionStore { SessionStore.shared }

    private var kinds: [HomePanelKind] {
        prefs.homePanels.compactMap(HomePanelKind.init(rawValue:))
    }

    /// The panels with something to show. Nearby is an offer, not a
    /// status: with no Mac found it says nothing rather than saying so.
    private var visibleKinds: [HomePanelKind] {
        kinds.filter { $0 != .nearby || !unsavedNearby.isEmpty || nearby.denied }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 14) {
                // What is running, first and always: the one thing on this
                // screen that is yours to get back to.
                ShellDeck(zoom: zoom)
                    .arrive(0)
                    .id("deck")
                ForEach(Array(visibleKinds.enumerated()), id: \.element) { index, kind in
                    panel(kind)
                        .arrive(index + 1)
                        .scrollMorph()
                        .transition(.morphPanel)
                        .id(kind)
                }
                Button {
                    Haptics.shared.fire(.light)
                    router.route = .panels
                } label: {
                    Label("Edit panels", systemImage: "slider.horizontal.3")
                        .font(Theme.font(Theme.ui(13), .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16)
                        .frame(height: Theme.ui(38))
                        .glassPill()
                }
                .buttonStyle(PressablePill())
                .padding(.top, 6)
                .arrive(kinds.count + 1)
                .id("edit")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .contermReadableColumn()
            .animation(Theme.Spring.morph, value: visibleKinds)
        }
        .onChange(of: router.scrollRequest) { _, count in
            withAnimation(Theme.Spring.soft) {
                if count % 2 == 1 {
                    proxy.scrollTo("edit", anchor: .bottom)
                } else {
                    proxy.scrollTo("deck", anchor: .top)
                }
            }
        }
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            scrolled?.wrappedValue = offset
        }
        .scrollDismissesKeyboard(.immediately)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    /// The glyph on a panel that opens into more: a small glass circle.
    private var expandGlyph: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: Theme.ui(10), weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Theme.ui(26), height: Theme.ui(26))
            .glassPill()
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 70).padding(.top, 8)
    }

    /// The caption row at the foot of a panel: what it is, and how often.
    private func caption(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left).morph(on: left, alignment: .leading)
            Spacer()
            Text(right).morph(on: right, alignment: .trailing)
        }
        .font(Theme.font(Theme.ui(10.5), .medium))
        .foregroundStyle(Theme.textSecondary.opacity(0.85))
    }

    @ViewBuilder
    private func panel(_ kind: HomePanelKind) -> some View {
        switch kind {
        case .activity: activityPanel
        case .heartbeat: heartbeatPanel
        case .world: worldPanel
        case .fleet: fleetPanel
        case .wantsYou: wantsYouPanel
        case .uptime: uptimePanel
        case .recent: recentPanel
        case .nearby: nearbyPanel
        }
    }

    // MARK: - Activity

    private var activityPanel: some View {
        let samples = traffic.samples
        let peak = max(traffic.peak, 1)
        let padding = max(TrafficMeter.capacity - samples.count, 0)
        let totals = Array(repeating: 0.0, count: padding) + samples.map { $0.total / peak }
        let outs = Array(repeating: 0.0, count: padding) + samples.map { $0.outPerSec / peak }
        let now = formatRate(traffic.now)
        let top = formatRate(traffic.peak)
        return Button {
            router.expand(.activity)
        } label: {
            Panel(HomePanelKind.activity.title, symbol: HomePanelKind.activity.symbol,
                  bed: .azure) {
                HStack(alignment: .top, spacing: 18) {
                    Readout(value: now.value, label: "Now", symbol: "arrow.left.arrow.right",
                            detail: now.unit, fraction: traffic.now / peak, size: 44)
                    divider
                    Readout(value: top.value, label: "Peak", symbol: "arrow.up.to.line",
                            detail: top.unit, fraction: traffic.peak > 0 ? 1 : 0, size: 44,
                            muted: traffic.peak == 0)
                }
                LineChart(values: totals, secondary: outs, height: 96, glow: true)
                    .padding(.top, 4)
                caption(sessions.live.isEmpty ? "no shells open" : "in, and out, every open shell",
                        "every two seconds")
            } accessory: {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.Status.ready).frame(width: 6, height: 6)
                            .opacity(sessions.live.isEmpty ? 0.3 : 1)
                        Text(sessions.live.isEmpty ? "IDLE" : "LIVE")
                            .font(Theme.font(Theme.ui(10), .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .morph(on: sessions.live.isEmpty)
                    }
                    expandGlyph
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
        .buttonStyle(PressablePill(scale: 0.98))
        .matchedTransitionSource(id: HomeDetail.activity.zoomID, in: zoom) {
            $0.clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    // MARK: - Heartbeat

    /// One lane per host whose sampler is beating: its name, its CPU now,
    /// and the spread between its cores over the last minutes.
    private var lanes: [(host: Host, model: HostProbeModel)] {
        HostProbeModel.active.compactMap { entry in
            guard let host = store.hosts.first(where: { $0.id == entry.hostID }),
                  !entry.model.pulse.samples.isEmpty else { return nil }
            return (host, entry.model)
        }
        .sorted { $0.host.alias < $1.host.alias }
    }

    private var heartbeatPanel: some View {
        let lanes = lanes
        return Button {
            router.expand(.heartbeat)
        } label: {
            Panel(HomePanelKind.heartbeat.title, symbol: HomePanelKind.heartbeat.symbol, bed: .grass) {
                if lanes.isEmpty {
                    Text("Open a host's overview once and its heart keeps beating here for a few minutes after.")
                        .font(Theme.font(Theme.ui(13), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(lanes.enumerated()), id: \.element.host.id) { index, lane in
                            HeartbeatLane(host: lane.host, pulse: lane.model.pulse, height: 40)
                                .popIn(index, base: 0.2)
                            if index < lanes.count - 1 { PanelRule() }
                        }
                    }
                    caption("least and busiest core", "every few seconds")
                }
            } accessory: {
                HStack(spacing: 8) {
                    if !lanes.isEmpty {
                        Text("\(lanes.count)")
                            .font(Theme.font(Theme.ui(11), .bold))
                            .badgePill(tint: Theme.textPrimary)
                            .rollingDigits(on: lanes.count)
                    }
                    expandGlyph
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
        .buttonStyle(PressablePill(scale: 0.98))
        .matchedTransitionSource(id: HomeDetail.heartbeat.zoomID, in: zoom) {
            $0.clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    // MARK: - World

    private var pins: [WorldMap.Pin] {
        WorldPins.pins(for: store.hosts, at: now)
    }

    private var worldPanel: some View {
        let pins = pins
        let placed = pins.count
        return Button {
            router.expand(.world)
        } label: {
            Panel(HomePanelKind.world.title, symbol: HomePanelKind.world.symbol, bed: .teal) {
                WorldMap(pins: pins, date: now)
                    .padding(.top, 2)
                caption(placed == 0 ? "open a host's overview once to place it"
                            : "\(placed) of \(store.hosts.count) host\(store.hosts.count == 1 ? "" : "s") placed",
                        "night side dimmed")
            } accessory: {
                Text(now, format: .dateTime.hour().minute())
                    .font(Theme.font(Theme.ui(11), .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
        .buttonStyle(PressablePill(scale: 0.98))
        .matchedTransitionSource(id: HomeDetail.world.zoomID, in: zoom) {
            $0.clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    // MARK: - Fleet

    private var fleetPanel: some View {
        let withKey = store.hosts.filter { KeyStore.shared.hasSecret(for: $0) }.count
        let total = max(store.hosts.count, 1)
        return Panel(HomePanelKind.fleet.title, symbol: HomePanelKind.fleet.symbol, bed: .cream) {
            if store.hosts.isEmpty {
                FleetEmpty()
            } else {
                HStack(alignment: .top, spacing: 18) {
                    Readout(value: "\(store.hosts.count)", label: "Hosts", symbol: "server.rack",
                            detail: "\(withKey) with a key", fraction: Double(withKey) / Double(total),
                            size: 44)
                    divider
                    Readout(value: "\(sessions.live.count)", label: "Live", symbol: "bolt.horizontal.fill",
                            detail: sessions.live.isEmpty ? "no shells open" : "shell\(sessions.live.count == 1 ? "" : "s") open",
                            fraction: Double(sessions.live.count) / Double(total),
                            tint: sessions.live.isEmpty ? Theme.meter : Theme.Status.ready,
                            size: 44)
                }
                if !groups.groups.isEmpty {
                    CapsuleBars(bars: groupBars, highlight: groupBars.first?.id,
                                height: 64, barWidth: 14, spacing: 10, labels: .legend,
                                alignment: .leading)
                        .padding(.top, 4)
                }
                caption("\(groups.groups.count) group\(groups.groups.count == 1 ? "" : "s")",
                        "\(KeyLibrary.shared.keys.count) key\(KeyLibrary.shared.keys.count == 1 ? "" : "s")")
            }
        } accessory: {
            if !store.hosts.isEmpty {
                HStack(spacing: 6) {
                    Button {
                        Haptics.shared.fire(.light)
                        router.route = .newHost
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: Theme.ui(12), weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: Theme.ui(26), height: Theme.ui(26))
                            .glassPill()
                    }
                    .buttonStyle(PressablePill(scale: 0.86))
                    .accessibilityLabel("New host")
                    Button {
                        router.expand(.fleet)
                    } label: { expandGlyph }
                    .buttonStyle(PressablePill(scale: 0.86))
                    .accessibilityLabel("Fleet detail")
                    .matchedTransitionSource(id: HomeDetail.fleet.zoomID, in: zoom) {
                        $0.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
            }
        }
    }

    /// Hosts per group, biggest first, the loose ones last.
    private var groupBars: [CapsuleBars.Bar] {
        var bars = groups.ordered.map { group in
            CapsuleBars.Bar(id: group.id.uuidString, label: group.name,
                            value: Double(store.hosts.filter { $0.groupID == group.id }.count))
        }
        .filter { $0.value > 0 }
        .sorted { $0.value > $1.value }
        let loose = store.hosts.filter { $0.groupID == nil || groups.group(id: $0.groupID) == nil }
        if !loose.isEmpty {
            bars.append(.init(id: "loose", label: "Ungrouped", value: Double(loose.count)))
        }
        return Array(bars.prefix(6))
    }

    // MARK: - Wants you

    private var signals: [ContermSnapshot.Signal] {
        SignalCenter.shared.all.sorted {
            $0.kind.weight != $1.kind.weight ? $0.kind.weight > $1.kind.weight : $0.at > $1.at
        }
    }

    private var wantsYouPanel: some View {
        let signals = signals
        return Panel(HomePanelKind.wantsYou.title, symbol: HomePanelKind.wantsYou.symbol,
                     bed: signals.isEmpty ? .violet : .amber) {
            if signals.isEmpty {
                Text("Nothing wants you.")
                    .font(Theme.font(Theme.ui(20), .heavy))
                    .foregroundStyle(Theme.textPrimary)
                caption("agents on your Mac, hosts that stopped answering, lost shells", "")
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(signals.prefix(4).enumerated()), id: \.element.id) { index, signal in
                        // A signal from a Mac opens that Mac's panes, where
                        // the agent can be answered.
                        let mac = macBehind(signal)
                        Button {
                            if let mac { router.showPanes(mac) }
                        } label: {
                            SignalRow(signal: signal, now: now, opens: mac != nil)
                        }
                        .buttonStyle(PressableRow())
                        .disabled(mac == nil)
                        .popIn(index, base: 0.2)
                        if index < min(signals.count, 4) - 1 { PanelRule() }
                    }
                }
            }
        } accessory: {
            if !signals.isEmpty {
                Text("\(signals.count)")
                    .font(Theme.font(Theme.ui(11), .bold))
                    .badgePill(tint: Theme.textPrimary)
                    .rollingDigits(on: signals.count)
            }
        }
    }

    /// The Mac a signal came from, when it came from one.
    private func macBehind(_ signal: ContermSnapshot.Signal) -> Host? {
        guard let source = SignalCenter.shared.source(of: signal.id),
              source.hasPrefix("mac."),
              let id = UUID(uuidString: String(source.dropFirst(4))) else { return nil }
        return store.hosts.first { $0.id == id }
    }

    // MARK: - Uptime

    private var standings: [(host: Host, seconds: Int, label: String)] {
        store.hosts.compactMap { host in
            guard let info = HostProbeModel.cachedInfo(for: host)?.info,
                  let uptime = info.uptime, let seconds = Uptime.seconds(uptime) else { return nil }
            return (host, seconds, HostOverviewView.shortUptime(uptime))
        }
        .sorted { $0.seconds > $1.seconds }
    }

    private var uptimePanel: some View {
        let standings = standings
        return Panel(HomePanelKind.uptime.title, symbol: HomePanelKind.uptime.symbol, bed: .amber) {
            if standings.isEmpty {
                Text("Open a host's overview once and it joins the podium.")
                    .font(Theme.font(Theme.ui(13), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let first = standings[0]
                HStack(alignment: .top, spacing: 18) {
                    Readout(value: first.label, label: "Longest up", symbol: "trophy.fill",
                            detail: first.host.alias, size: 40)
                    divider
                    Readout(value: "\(standings.count)", label: "Checked", symbol: "server.rack",
                            detail: standings.count == 1 ? "host" : "hosts", size: 40)
                }
                RankBars(rows: standings.prefix(5).map { entry in
                    RankBars.Row(id: entry.host.id.uuidString, label: entry.host.alias,
                                 value: Double(entry.seconds), text: entry.label)
                }, height: 32)
                    .padding(.top, 4)
                caption("since their last boot", "from the last probe of each")
            }
        }
    }

    // MARK: - Recent

    /// The hosts you were on last, as bubbles. Before anything has been
    /// connected to, the first few saved hosts stand in, so the panel is
    /// useful from the first launch.
    private var recent: [Host] {
        let used = store.hosts.filter { $0.lastConnectedAt != nil }
            .sorted { $0.lastConnectedAt! > $1.lastConnectedAt! }
        let rest = store.hosts.filter { $0.lastConnectedAt == nil }
            .sorted { $0.alias.lowercased() < $1.alias.lowercased() }
        return Array((used + rest).prefix(8))
    }

    private var recentPanel: some View {
        let hosts = recent
        return Panel(HomePanelKind.recent.title, symbol: HomePanelKind.recent.symbol, bed: .azure) {
            if hosts.isEmpty {
                Text("Hosts you connect to show up here.")
                    .font(Theme.font(Theme.ui(13), .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                        HostBubble(host: host, group: groups.group(id: host.groupID), zoom: zoom)
                            .popIn(index, base: 0.25)
                    }
                }
            }
        }
        .animation(Theme.Spring.morph, value: hosts.map(\.id))
    }

    // MARK: - Nearby

    /// Discovered Macs that aren't already in the list. A Mac you have
    /// already added is not a discovery, it is a duplicate.
    private var unsavedNearby: [NearbyMacs.Found] {
        let known = Set(store.hosts.map { $0.hostname.lowercased() })
        return nearby.found.filter { !known.contains($0.hostname.lowercased()) }
    }

    @ViewBuilder
    private var nearbyPanel: some View {
        let macs = unsavedNearby
        Panel(HomePanelKind.nearby.title, symbol: HomePanelKind.nearby.symbol, bed: .teal) {
            if macs.isEmpty {
                Text(nearby.denied
                     ? "Local network access is off for Conterm in Settings."
                     : "Macs on this network running Conterm appear here.")
                    .font(Theme.font(Theme.ui(13), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(macs.enumerated()), id: \.element.id) { index, mac in
                        NearbyRow(mac: mac) { add(mac) }
                            .popIn(index, base: 0.2)
                        if index < macs.count - 1 { PanelRule() }
                    }
                }
            }
        } accessory: {
            if !macs.isEmpty {
                Text("\(macs.count)")
                    .font(Theme.font(Theme.ui(11), .bold))
                    .badgePill(tint: Theme.textPrimary)
                    .rollingDigits(on: macs.count)
            }
        }
    }

    /// Add a discovered Mac, prefilled. It still goes through the editor —
    /// the one thing discovery cannot supply is how you authenticate.
    private func add(_ mac: NearbyMacs.Found) {
        Haptics.shared.fire(.light)
        var host = Host(alias: mac.name,
                        hostname: mac.hostname,
                        port: 22,
                        username: mac.username,
                        auth: .privateKey)
        host.distro = "macos"
        router.route = .editHost(host)
    }
}

// MARK: - Pieces

/// The hosts that can be placed on the map, from what their probes said.
enum WorldPins {
    @MainActor
    static func pins(for hosts: [Host], at now: Date) -> [WorldMap.Pin] {
        hosts.compactMap { host in
            guard let info = HostProbeModel.cachedInfo(for: host)?.info,
                  let spot = WorldAtlas.place(zone: info.timeZoneID,
                                              offsetMinutes: info.utcOffsetMinutes)
            else { return nil }
            return WorldMap.Pin(id: host.id.uuidString, lat: spot.lat, lon: spot.lon,
                                color: HostHealth.of(info).color,
                                label: localTime(info, at: now), exact: spot.exact)
        }
    }

    static func localTime(_ info: HostInfo, at now: Date) -> String? {
        let zone: TimeZone? = info.timeZoneID.flatMap(TimeZone.init(identifier:))
            ?? info.utcOffsetMinutes.flatMap { TimeZone(secondsFromGMT: $0 * 60) }
        guard let zone else { return nil }
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: now)
    }
}

/// "41 days, 2:11" as seconds, and the other shapes `uptime` prints.
enum Uptime {
    static func seconds(_ pretty: String) -> Int? {
        let s = pretty.trimmingCharacters(in: .whitespaces)
        var total = 0
        var matched = false
        if let m = s.firstMatch(of: /(\d+) days?/) { total += (Int(m.1) ?? 0) * 86_400; matched = true }
        if let m = s.firstMatch(of: /(\d+):(\d+)/) {
            total += (Int(m.1) ?? 0) * 3600 + (Int(m.2) ?? 0) * 60; matched = true
        } else if let m = s.firstMatch(of: /(\d+) min/) {
            total += (Int(m.1) ?? 0) * 60; matched = true
        } else if let m = s.firstMatch(of: /(\d+) hours?/) {
            total += (Int(m.1) ?? 0) * 3600; matched = true
        }
        return matched ? total : nil
    }
}

/// One host's heart: its name and CPU now, and the spread of its cores
/// over the last minutes, in its own lane.
struct HeartbeatLane: View {
    let host: Host
    let pulse: HostPulse
    var height: CGFloat = 40
    var labelled = false

    var body: some View {
        let spread = pulse.samples.compactMap { s -> PulseChart.Sample? in
            guard let lo = s.coreLow, let hi = s.coreHigh else { return nil }
            return PulseChart.Sample(low: lo, high: hi)
        }
        let cpu = pulse.latest?.cpu
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias)
                    .font(Theme.font(Theme.ui(13), .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(Theme.font(Theme.ui(24), .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .morph(on: cpu.map { Int(($0 * 100).rounded()) } ?? -1, alignment: .leading)
            }
            .frame(width: 92, alignment: .leading)
            PulseChart(samples: spread, capacity: HostPulse.capacity, height: height,
                       topLabel: labelled ? "100%" : nil, bottomLabel: labelled ? "0" : nil,
                       timeLabels: labelled ? ["4m ago", "2m", "now"] : [])
        }
    }
}

/// One thing that wants you: its glyph in its colour, what it is, when.
struct SignalRow: View {
    let signal: ContermSnapshot.Signal
    let now: Date
    /// Whether a tap goes somewhere; the row shows the arrow when it does.
    var opens = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: signal.kind.symbol)
                .font(.system(size: Theme.ui(14), weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title)
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail = signal.detail {
                    Text(detail)
                        .font(Theme.font(Theme.ui(11.5), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(signal.at, style: .relative)
                .font(Theme.font(Theme.ui(11), .medium))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
            if opens {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: Theme.ui(11), weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch signal.kind {
        case .agentWaiting: return Theme.Status.attention
        case .hostDown: return Theme.Status.danger
        case .sessionLost: return Theme.Status.working
        case .note: return Theme.Status.neutral
        }
    }
}

/// A saved host as a bubble: tap to open a shell, hold for the rest.
struct HostBubble: View {
    let host: Host
    var group: HostGroup?
    let zoom: Namespace.ID
    @Environment(HomeRouter.self) private var router

    private var live: Int { SessionStore.shared.liveCount(for: host) }
    private var hasSecret: Bool { KeyStore.shared.hasSecret(for: host) }

    private var gem: Color {
        if live > 0 { return Theme.Status.ready }
        if let group { return group.color }
        return hasSecret ? Theme.textSecondary : Theme.Status.attention
    }

    var body: some View {
        Button {
            router.open(host, from: HomeRouter.zoomID(host))
        } label: {
            Bubble(host.alias, dot: gem, lit: live > 0,
                   detail: live > 0 ? "open" : (hasSecret ? nil : "no key"))
        }
        .buttonStyle(PressablePill(scale: 0.9))
        .matchedTransitionSource(id: HomeRouter.zoomID(host), in: zoom) {
            $0.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .contextMenu {
            Button("Overview", systemImage: "waveform.path.ecg") {
                router.showOverview(host, from: HomeRouter.zoomID(host))
            }
            if live > 0 {
                Button("Open another shell", systemImage: "plus.rectangle.on.rectangle") {
                    router.openNew(host, from: HomeRouter.zoomID(host))
                }
            }
            Button("Agents", systemImage: "sparkles") { router.agentsFor = host }
            Button("Conterm on this Mac", systemImage: "macwindow") { router.contermOn = host }
            Divider()
            Button("Edit host", systemImage: "pencil") { router.route = .editHost(host) }
        }
    }
}

/// Nothing saved yet: the fleet panel carries the invitation.
private struct FleetEmpty: View {
    @Environment(HomeRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No hosts yet")
                .font(Theme.font(Theme.ui(22), .heavy))
                .foregroundStyle(Theme.textPrimary)
            Text("Connect straight away with user@host, or save the hosts you use often.")
                .font(Theme.font(Theme.ui(13), .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8) {
                Button("Quick Connect") { router.route = .quickConnect }
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .filledPill(height: Theme.ui(40))
                    .buttonStyle(PressablePill())
                Button("Add host") { router.route = .newHost }
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .softPill(height: Theme.ui(40))
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
