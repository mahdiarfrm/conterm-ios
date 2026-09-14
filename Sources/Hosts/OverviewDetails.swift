import SwiftUI

/// The panels on an overview that open into more.
enum OverviewDetail: String, Hashable, Identifiable {
    case vitals, network
    var id: String { rawValue }
    var zoomID: String { "overview-panel-\(rawValue)" }
}

/// The vitals, opened: how busy the machine is, enormous; memory as a
/// ramp filling toward the top; the core spread drawn large; the load
/// beside it; what the sampler has seen over its window.
struct VitalsDetail: View {
    let info: HostInfo
    let pulse: HostPulse

    var body: some View {
        let latest = pulse.latest
        let cpu = latest?.cpu
        let memory: Double? = latest?.memory ?? {
            guard let total = info.memTotalMB, let avail = info.memAvailMB, total > 0
            else { return nil }
            return Double(total - avail) / Double(total)
        }()
        let cpus = pulse.samples.compactMap(\.cpu)
        let spread = pulse.samples.compactMap { s -> PulseChart.Sample? in
            guard let lo = s.coreLow, let hi = s.coreHigh else { return nil }
            return PulseChart.Sample(low: lo, high: hi)
        }
        let totalGB = info.memTotalMB.map { Double($0) / 1024 }

        PanelDetail(title: "Vitals", symbol: "waveform.path.ecg",
                    value: cpu.map { "\(Int(($0 * 100).rounded()))" } ?? "—",
                    unit: "%",
                    caption: info.cores.map { "of \($0) cores busy, right now" }
                        ?? "of the machine busy, right now",
                    bed: .ink) {
            HStack(alignment: .top, spacing: 16) {
                DetailFact(value: info.loadAvg.map { String(format: "%.2f", $0.0) } ?? "—",
                           label: "Load, 1 min")
                DetailFact(value: cpus.max().map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                           label: "Peak, 4 min")
                DetailFact(value: memory.map { "\(Int($0 * 100))%" } ?? "—",
                           label: "Memory")
            }
        } card: {
            if let memory {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory")
                        .font(Theme.font(Theme.ui(18), .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let totalGB {
                        Text(String(format: "%.1f of %.1f GB", memory * totalGB, totalGB))
                            .font(Theme.font(Theme.ui(12), .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
                CapsuleRamp(fraction: memory, count: 22, maxHeight: 48,
                            tint: memory > 0.9 ? Theme.Status.danger : Theme.meter,
                            labels: totalGB.map { t in
                                [0, 0.25, 0.5, 0.75, 1].map { String(format: "%.0f", $0 * t) }
                            } ?? ["0", "25%", "50%", "75%", "100%"])
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Cores")
                    .font(Theme.font(Theme.ui(18), .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(spread.isEmpty ? "sampling…" : "least and busiest, every few seconds")
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            PulseChart(samples: spread, capacity: HostPulse.capacity, height: 180,
                       tint: Theme.meter, topLabel: "100%", bottomLabel: "0",
                       timeLabels: ["4m ago", "3m", "2m", "1m", "now"])

            if let load = info.loadAvg {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                HStack(alignment: .firstTextBaseline) {
                    Text("Load")
                        .font(Theme.font(Theme.ui(18), .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let cores = info.cores {
                        Text("full bar = \(cores) core\(cores == 1 ? "" : "s")")
                            .font(Theme.font(Theme.ui(12), .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                CapsuleBars(bars: [.init(id: "1", label: "1m", value: load.0),
                                   .init(id: "5", label: "5m", value: load.1),
                                   .init(id: "15", label: "15m", value: load.2)],
                            highlight: "1", maximum: Double(max(info.cores ?? 1, 1)),
                            height: 110, barWidth: 16, spacing: 14)
            }

            if !cpus.isEmpty {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                HStack(spacing: 0) {
                    DetailStat(value: "\(Int((cpus.reduce(0, +) / Double(cpus.count) * 100).rounded()))%",
                               label: "Average")
                    DetailStat(value: "\(Int(((cpus.min() ?? 0) * 100).rounded()))%", label: "Quietest")
                    DetailStat(value: "\(cpus.count)", label: "Samples")
                }
            }
        }
    }
}

/// The network, opened: what is coming in, enormous; what is going out;
/// the two lines drawn large; the addresses and the ports.
struct NetworkDetail: View {
    let info: HostInfo
    let pulse: HostPulse

    var body: some View {
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
        let peakRate = formatRate(rates.map { $0.rx + $0.tx }.max() ?? 0)

        PanelDetail(title: "Network", symbol: "antenna.radiowaves.left.and.right",
                    value: down.value, unit: down.unit,
                    caption: "coming in, right now", bed: .teal) {
            HStack(alignment: .top, spacing: 16) {
                DetailFact(value: "\(up.value) \(up.unit)", label: "Going out")
                DetailFact(value: "\(peakRate.value) \(peakRate.unit)", label: "Peak, 4 min")
                DetailFact(value: "\(info.listeningPorts.count)", label: "Listening")
            }
        } card: {
            HStack(alignment: .firstTextBaseline) {
                Text("Last four minutes")
                    .font(Theme.font(Theme.ui(18), .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(rates.isEmpty ? "sampling…" : "in, and out")
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            LineChart(values: rx, secondary: tx, height: 170, lineWidth: 3)
            HStack {
                Text("4m ago"); Spacer(); Text("2m"); Spacer(); Text("now")
            }
            .font(Theme.font(Theme.ui(11), .medium))
            .foregroundStyle(Theme.textSecondary)

            if !info.ips.isEmpty {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                Text("Addresses")
                    .font(Theme.font(Theme.ui(13), .bold))
                    .foregroundStyle(Theme.textSecondary)
                FlowLayout(spacing: 6) {
                    ForEach(Array(info.ips.enumerated()), id: \.offset) { index, ip in
                        Text(ip)
                            .font(.system(size: Theme.ui(12), weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule(style: .continuous).fill(Theme.accentSoft))
                            .popIn(index, base: 0.35)
                    }
                }
            }
            if !info.listeningPorts.isEmpty {
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                Text("Listening")
                    .font(Theme.font(Theme.ui(13), .bold))
                    .foregroundStyle(Theme.textSecondary)
                FlowLayout(spacing: 6) {
                    ForEach(Array(info.listeningPorts.enumerated()), id: \.offset) { index, port in
                        Text(port)
                            .font(.system(size: Theme.ui(12), weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule(style: .continuous).fill(Theme.accentSoft))
                            .popIn(index, base: 0.4)
                    }
                }
            }
        }
    }
}

/// A number and a word, one of a row across a card.
struct DetailStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.font(Theme.ui(24), .bold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .morph(on: value, alignment: .leading)
            Text(label)
                .font(Theme.font(Theme.ui(12), .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
