import SwiftUI

/// Every motion primitive on one screen, cycling by itself.
///
/// Launch with `CONTERM_DESIGN=1` (`SIMCTL_CHILD_CONTERM_DESIGN=1` on the
/// simulator). The same reasoning as the widget gallery: a transition you
/// can only see by connecting to a real host first is a transition that
/// stops getting looked at. Nothing here is product; it is the design
/// language made visible so it can be judged, and it runs its own clock
/// only while it is on screen.
struct DesignGallery: View {
    @State private var tick = 0
    @State private var segment = Segment.day
    @State private var pressed = 0
    @State private var awake = true
    @State private var showingSettings = false
    @State private var showingEditor = false
    /// A spread that grows one sample per tick, so the pulse chart draws
    /// itself in and then keeps going.
    @State private var spread: [PulseChart.Sample] = (0..<24).map(DesignGallery.spreadSample)
    @State private var line: [Double] = (0..<40).map(DesignGallery.lineSample)

    nonisolated private static func spreadSample(_ i: Int) -> PulseChart.Sample {
        let t = Double(i)
        let base: Double = 0.25 + 0.2 * sin(t / 3)
        let span: Double = 0.15 + 0.3 * abs(sin(t / 1.7))
        return PulseChart.Sample(low: base, high: base + span)
    }

    nonisolated private static func lineSample(_ i: Int) -> Double {
        let t = Double(i)
        let peak: Double = pow(max(0, sin(t / 4.5)), 3)
        let wobble: Double = 0.1 * sin(t / 1.3)
        return max(0, 0.15 + 0.6 * peak + wobble)
    }

    enum Segment: String, CaseIterable { case day = "D", week = "W", month = "M" }

    private static let phases = ["resolving", "handshake", "authenticating", "connected"]
    private static let loads: [(String, Double)] = [("0.42", 0.05), ("1.87", 0.23),
                                                    ("6.12", 0.77), ("7.90", 0.99)]
    private static let memory: [(String, Double)] = [("31%", 0.31), ("48%", 0.48),
                                                     ("83%", 0.83), ("52%", 0.52)]
    private static let hosts = [3, 4, 12, 7]

    private var phase: String { Self.phases[tick % Self.phases.count] }
    private var load: (String, Double) { Self.loads[tick % Self.loads.count] }
    private var mem: (String, Double) { Self.memory[tick % Self.memory.count] }
    private var hostCount: Int { Self.hosts[tick % Self.hosts.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                block("System", note: "The machine's shares as concentric rings, the facts that are numbers beside them.") {
                    Panel("System", symbol: "cpu", bed: .cream) {
                        HStack(alignment: .center, spacing: 20) {
                            ZStack {
                                RingStack(slices: [
                                    .init(id: "disk", label: "Disk", fraction: 0.62,
                                          tint: Color(red: 0.14, green: 0.47, blue: 0.98), text: "62%"),
                                    .init(id: "memory", label: "Memory", fraction: mem.1,
                                          tint: Color(red: 0.52, green: 0.33, blue: 0.95), text: mem.0),
                                    .init(id: "cpu", label: "CPU", fraction: load.1,
                                          tint: Color(red: 0.03, green: 0.58, blue: 0.64),
                                          text: "\(Int(load.1 * 100))%"),
                                ], size: 150, lineWidth: 13, gap: 5)
                                VStack(spacing: 0) {
                                    Text("62%").font(Theme.font(Theme.ui(22), .heavy))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("Disk").font(Theme.font(Theme.ui(10), .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach([("Disk", "62%", Color(red: 0.14, green: 0.47, blue: 0.98)),
                                         ("Memory", mem.0, Color(red: 0.52, green: 0.33, blue: 0.95)),
                                         ("CPU", "\(Int(load.1 * 100))%", Color(red: 0.03, green: 0.58, blue: 0.64))],
                                        id: \.0) { row in
                                    HStack(spacing: 8) {
                                        Circle().fill(row.2).frame(width: 8, height: 8)
                                        Text(row.0).font(Theme.font(Theme.ui(12.5), .semibold))
                                            .foregroundStyle(Theme.textSecondary)
                                        Spacer(minLength: 4)
                                        Text(row.1).font(Theme.font(Theme.ui(14), .bold))
                                            .foregroundStyle(Theme.textPrimary).monospacedDigit()
                                    }
                                }
                            }
                        }
                        Rectangle().fill(Theme.stroke).frame(height: 0.5)
                        HStack(spacing: 14) {
                            ForEach([("clock", "Up", "41d 2h"), ("person.2", "Logged in", "3"),
                                     ("exclamationmark.triangle", "Failed units", "0")], id: \.1) { fact in
                                HStack(spacing: 8) {
                                    Image(systemName: fact.0)
                                        .font(.system(size: Theme.ui(11), weight: .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(fact.2).font(Theme.font(Theme.ui(17), .heavy))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(fact.1).font(Theme.font(Theme.ui(10.5), .medium))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                block("World", note: "The world as dots, the night side dimmed by where the sun is; every placed host with its local time.") {
                    Panel("World", symbol: "globe.europe.africa.fill", bed: .ink) {
                        WorldMap(pins: [
                            .init(id: "a", lat: 35.7, lon: 51.4, color: Theme.Status.ready, label: "21:14"),
                            .init(id: "b", lat: 52.5, lon: 13.4, color: Theme.Status.ready, label: "19:44"),
                            .init(id: "c", lat: 40.7, lon: -74.0, color: Theme.Status.attention, label: "13:44"),
                            .init(id: "d", lat: 1.3, lon: 103.8, color: Theme.Status.ready, label: "01:44"),
                            .init(id: "e", lat: 24, lon: -120, color: Theme.Status.neutral, label: "10:44", exact: false),
                        ])
                        HStack {
                            Text("5 of 9 hosts placed")
                            Spacer()
                            Text("night side dimmed")
                        }
                        .font(Theme.font(Theme.ui(10.5), .medium))
                        .foregroundStyle(Theme.textSecondary.opacity(0.85))
                    } accessory: {
                        Text("18:44")
                            .font(Theme.font(Theme.ui(11), .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                block("Panels", note: "A card with one number and its picture. Each arrives after the last; what is inside draws itself.") {
                    VStack(spacing: 14) {
                        Panel("Vitals", symbol: "waveform.path.ecg", bed: .ink) {
                            HStack(alignment: .top, spacing: 18) {
                                Readout(value: load.0, label: "CPU", symbol: "cpu",
                                        detail: "8 cores", fraction: load.1, size: 40)
                                Rectangle().fill(Theme.stroke).frame(width: 1, height: 70).padding(.top, 8)
                                Readout(value: mem.0, label: "Memory", symbol: "memorychip",
                                        detail: "16 GB", fraction: mem.1, size: 40)
                            }
                            PulseChart(samples: spread, capacity: 60, height: 110,
                                       topLabel: "100%", bottomLabel: "0",
                                       timeLabels: ["3m ago", "2m", "1m", "now"])
                        } accessory: {
                            HStack(spacing: 5) {
                                Circle().fill(Theme.Status.ready).frame(width: 6, height: 6)
                                Text("LIVE").font(Theme.font(Theme.ui(10), .bold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .arrive(0)

                        Panel("Activity", symbol: "waveform.path.ecg", bed: .ink) {
                            PanelReadout(value: "1.4", unit: "KB/s", tag: "now")
                            LineChart(values: line, secondary: line.map { $0 * 0.4 }, height: 90)
                        }
                        .arrive(1)

                        Panel("Docker", symbol: "shippingbox", bed: .grass) {
                            FlowLayout(spacing: 8) {
                                ForEach(Array(["web", "api", "postgres", "redis", "worker", "nginx"].enumerated()),
                                        id: \.offset) { i, name in
                                    Bubble(name, dot: i < 4 ? Theme.Status.ready : Theme.textSecondary.opacity(0.5),
                                           lit: i < 4, detail: i < 4 ? "3h" : "exited 2d")
                                        .popIn(i, base: 0.3)
                                }
                            }
                        } accessory: {
                            Text("4 of 6 up")
                                .font(Theme.font(Theme.ui(10.5), .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .arrive(2)

                        Panel("Load", symbol: "gauge.with.dots.needle.33percent", bed: .cream) {
                            HStack(alignment: .top, spacing: 18) {
                                Readout(value: load.0, label: "1 min", detail: "of 8 cores",
                                        tint: Theme.textPrimary, size: 34)
                                    .frame(width: 118)
                                CapsuleBars(bars: [.init(id: "1", label: "1m", value: load.1 * 8),
                                                   .init(id: "5", label: "5m", value: mem.1 * 8),
                                                   .init(id: "15", label: "15m", value: 2.4)],
                                            highlight: "1", maximum: 8, height: 88, barWidth: 14,
                                            spacing: 12, alignment: .trailing)
                            }
                        }
                        .arrive(3)
                    }
                }

                block("Morph", note: "A value that changed goes out of focus and the new one focuses in.") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(phase == "connected" ? Theme.Status.ready : Theme.Status.working)
                            .frame(width: 6, height: 6)
                        Text(phase)
                            .font(Theme.font(Theme.ui(22), .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .morph(on: phase, alignment: .leading)
                    }
                    .animation(Theme.Spring.morph, value: phase)
                }

                block("Readouts", note: "Number first, meaning beneath. The meter eases to its fill.") {
                    HStack(alignment: .top, spacing: 10) {
                        Readout(value: load.0, label: "Load",
                                symbol: "gauge.with.dots.needle.33percent",
                                detail: "8 cores", fraction: load.1,
                                tint: load.1 > 0.9 ? Theme.Status.danger
                                    : load.1 > 0.8 ? Theme.warning : Theme.sshAccent)
                        Readout(value: mem.0, label: "Memory", symbol: "memorychip",
                                detail: "16 GB", fraction: mem.1,
                                tint: mem.1 > 0.8 ? Theme.Status.attention : Theme.meter)
                        Readout(value: "—", label: "Disk", symbol: "internaldrive",
                                detail: " ", fraction: 0, muted: true)
                    }
                }

                block("Rolling digits", note: "A count that moves rolls rather than jumps.") {
                    Text("\(hostCount) host\(hostCount == 1 ? "" : "s")")
                        .font(Theme.font(Theme.ui(22), .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                        .rollingDigits(on: hostCount)
                }

                block("Segmented pill", note: "One thumb that travels, not three buttons that light up.") {
                    SegmentedPill(selection: $segment, options: Segment.allCases) { $0.rawValue }
                        .frame(maxWidth: 220)
                }

                block("Tiles", note: "A readout in a translucent tile with a lit rim.") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        StatTile(value: "2d 15h", label: "Uptime", symbol: "clock", detail: " ")
                        StatTile(value: mem.0, label: "Disk", symbol: "internaldrive", detail: "/",
                                 fraction: mem.1)
                        StatTile(value: "\(hostCount)", label: "Failed units",
                                 symbol: "exclamationmark.triangle", detail: " ")
                        StatTile(value: "16", label: "Logged in", symbol: "person.2", detail: " ")
                    }
                }

                block("Capsule bars", note: "Every bar a capsule; the one that matters is solid.") {
                    CapsuleBars(bars: [.init(id: "1", label: "1m", value: load.1 * 8),
                                       .init(id: "5", label: "5m", value: mem.1 * 8),
                                       .init(id: "15", label: "15m", value: 2.4)],
                                highlight: "1", maximum: 8, height: 100, barWidth: 14)
                }

                block("Cream sheet", note: "What you read closely sits on cream, in ink.") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep screen awake")
                                    .font(Theme.font(Theme.ui(15), .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Only while a terminal is open.")
                                    .font(Theme.font(Theme.ui(11), .medium))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $awake).labelsHidden().tint(Theme.accent)
                        }
                        SegmentedPill(selection: $segment, options: Segment.allCases) { $0.rawValue }
                        HStack(spacing: 10) {
                            Text("Connect").font(Theme.font(Theme.ui(14), .semibold)).filledPill()
                            Text("Overview").font(Theme.font(Theme.ui(14), .semibold)).softPill()
                            Text("no key").font(Theme.font(Theme.ui(10), .semibold)).badgePill(tint: Theme.Status.attention)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .creamCard(cornerRadius: 28)
                }

                block("Press", note: "Sinks quickly under the finger, springs back with give.") {
                    HStack(spacing: 10) {
                        pill("Connect", filled: true)
                        pill("Overview", filled: false)
                        Text("\(pressed)")
                            .font(.system(size: Theme.ui(13), weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .rollingDigits(on: pressed)
                    }
                }
            }
            .padding(20)
            .contermReadableColumn()
        }
        .brandGround()
        .navigationTitle("Design")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingEditor) {
            HostEditorView(store: HostStore.shared, groups: HostGroupStore())
        }
        .task {
            // `CONTERM_DESIGN=settings` or `=editor` opens that sheet by
            // itself, so a cream modal can be looked at without a tap.
            let which = ProcessInfo.processInfo.environment["CONTERM_DESIGN"]
            guard which == "settings" || which == "editor" else { return }
            try? await Task.sleep(for: .seconds(1))
            if which == "settings" { showingSettings = true } else { showingEditor = true }
        }
        .task {
            // The gallery's own clock; cancelled with the view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                tick += 1
                spread.append(Self.spreadSample(spread.count + tick))
                if spread.count > 60 { spread.removeFirst() }
                let all = Segment.allCases
                withAnimation(Theme.Spring.snappy) {
                    segment = all[(all.firstIndex(of: segment)! + 1) % all.count]
                }
            }
        }
    }

    private func block<Content: View>(_ title: String, note: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(Theme.font(Theme.ui(10), .bold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.textSecondary)
                Text(note)
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            content()
        }
    }

    private func pill(_ title: String, filled: Bool) -> some View {
        Button {
            Haptics.shared.fire(.light)
            pressed += 1
        } label: {
            Text(title)
                .font(Theme.font(Theme.ui(14), .semibold))
                .foregroundStyle(filled ? Theme.onAccent : Theme.accent)
                .padding(.horizontal, 20)
                .frame(height: Theme.hitTarget)
                .background {
                    Capsule(style: .continuous).fill(filled ? Theme.accent : Theme.accentSoft)
                }
        }
        .buttonStyle(PressablePill(scale: 0.92))
    }
}
