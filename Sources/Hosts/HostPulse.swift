import Foundation
import Observation

/// A machine's vitals, sampled every few seconds: how busy it is, the
/// spread between its least and most busy core, its memory, its traffic.
/// The one-shot probe says what a machine *is*; this says what it is
/// *doing*, and it is what the overview's chart draws.
///
/// One read of the counters per tick; the rate is the difference from the
/// last tick, so the first tick only establishes a baseline and the chart
/// begins on the second. It keeps going for a while after the screen that
/// draws it has gone, so coming back finds the chart already full and the
/// connection still warm, and it stops on its own once nothing has looked
/// for a few minutes.
@Observable
@MainActor
final class HostPulse {
    struct Sample: Equatable, Sendable {
        let at: Date
        /// Busy fraction of the whole machine, 0...1.
        var cpu: Double?
        /// The least and most busy core over the same interval, 0...1 each.
        /// Equal where the host reports one number for the whole machine.
        var coreLow: Double?
        var coreHigh: Double?
        var load1: Double?
        /// Used fraction, 0...1.
        var memory: Double?
        /// Bytes per second, every interface but loopback.
        var rxPerSec: Double?
        var txPerSec: Double?
    }

    /// The gap between one sample finishing and the next starting.
    static let interval: Duration = .seconds(3)
    /// How many samples are kept — the width of the chart. Eighty at three
    /// seconds apiece is four minutes.
    static let capacity = 80
    /// How long the sampler keeps going after the last screen let go.
    static let linger: Duration = .seconds(300)

    private(set) var samples: [Sample] = []
    private(set) var running = false
    private(set) var failed = false

    private let address: HostAddress
    private let runner: any HostCommandRunner
    private var task: Task<Void, Never>?
    private var stopper: Task<Void, Never>?
    private var lastStat: [String: (busy: Double, total: Double)] = [:]
    private var lastNet: (rx: Double, tx: Double, at: Date)?
    private var lastTop: (idle: Double, at: Date)?

    init(address: HostAddress, runner: any HostCommandRunner) {
        self.address = address
        self.runner = runner
    }

    /// Sample until told otherwise. Cancels a pending stop.
    func start() {
        stopper?.cancel()
        stopper = nil
        guard task == nil else { return }
        running = true
        failed = false
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// The screen has gone. Keep sampling for `linger`, then stop.
    func release() {
        guard task != nil, stopper == nil else { return }
        stopper = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopper?.cancel()
        stopper = nil
        task?.cancel()
        task = nil
        running = false
    }

    /// The newest sample.
    var latest: Sample? { samples.last }

    private func tick() async {
        let raw: String
        do {
            raw = try await runner.runShell(Self.script, on: address)
        } catch {
            // One miss is a slow radio; the chart keeps what it has and the
            // next tick tries again. Only the screen's own probe reports.
            failed = true
            return
        }
        guard !Task.isCancelled, raw.contains("===conterm:load===") else { return }
        failed = false
        if let sample = parse(raw) {
            samples.append(sample)
            if samples.count > Self.capacity {
                samples.removeFirst(samples.count - Self.capacity)
            }
        }
    }

    /// One read of the counters. Linux answers from `/proc`; a Mac answers
    /// load from `sysctl`, the CPU from `top` as one number for the whole
    /// machine, and memory from `vm_stat`.
    nonisolated static let script = #"""
    put() { printf '\n===conterm:%s===\n' "$1"; }
    put load; cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null; true
    put mem; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null; true
    put stat; grep '^cpu' /proc/stat 2>/dev/null; true
    put net; tail -n +3 /proc/net/dev 2>/dev/null; true
    put top; [ -f /proc/stat ] || top -l 1 -n 0 -s 0 2>/dev/null | grep 'CPU usage'; true
    put macmem; [ -f /proc/meminfo ] || { sysctl -n hw.memsize 2>/dev/null; vm_stat 2>/dev/null; }; true
    put end
    """#

    /// Nil on the very first read, which only sets the baseline.
    private func parse(_ raw: String) -> Sample? {
        let sections = Self.sections(raw)
        let now = Date()
        var sample = Sample(at: now)

        if let load = sections["load"]?.first {
            let nums = load.replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
                .split(separator: " ").compactMap { Double($0) }
            sample.load1 = nums.first
        }
        sample.memory = Self.linuxMemory(sections["mem"] ?? [])
            ?? Self.macMemory(sections["macmem"] ?? [])

        var hadBaseline = false
        let stat = Self.cpuCounters(sections["stat"] ?? [])
        if !stat.isEmpty {
            if let b = lastStat["cpu"], let a = stat["cpu"], a.total > b.total {
                hadBaseline = true
                sample.cpu = min(max((a.busy - b.busy) / (a.total - b.total), 0), 1)
                let cores: [Double] = stat.keys.filter { $0 != "cpu" }.compactMap { key in
                    guard let b = lastStat[key], let a = stat[key], a.total > b.total
                    else { return nil }
                    return min(max((a.busy - b.busy) / (a.total - b.total), 0), 1)
                }
                sample.coreLow = cores.min() ?? sample.cpu
                sample.coreHigh = cores.max() ?? sample.cpu
            }
            lastStat = stat
        } else if let top = sections["top"]?.first,
                  let idle = top.split(separator: ",")
                      .first(where: { $0.contains("idle") })?
                      .split(separator: " ", omittingEmptySubsequences: true)
                      .compactMap({ Double($0.replacingOccurrences(of: "%", with: "")) })
                      .first {
            // `top` reports the whole machine at once; no baseline needed.
            hadBaseline = true
            sample.cpu = min(max(1 - idle / 100, 0), 1)
            sample.coreLow = sample.cpu
            sample.coreHigh = sample.cpu
        }

        if let net = Self.netCounters(sections["net"] ?? []) {
            if let last = lastNet {
                let dt = max(now.timeIntervalSince(last.at), 0.5)
                sample.rxPerSec = max(net.rx - last.rx, 0) / dt
                sample.txPerSec = max(net.tx - last.tx, 0) / dt
            }
            lastNet = (net.rx, net.tx, now)
        }

        return hadBaseline ? sample : nil
    }

    nonisolated private static func sections(_ raw: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("===conterm:"), line.hasSuffix("===") {
                current = String(line.dropFirst("===conterm:".count).dropLast(3))
                sections[current!] = []
            } else if let key = current, !line.isEmpty {
                sections[key, default: []].append(String(line))
            }
        }
        return sections
    }

    nonisolated private static func linuxMemory(_ mem: [String]) -> Double? {
        guard mem.count >= 2 else { return nil }
        func kb(_ prefix: String) -> Double? {
            mem.first { $0.hasPrefix(prefix) }?
                .split(separator: " ", omittingEmptySubsequences: true)
                .dropFirst().first.flatMap { Double($0) }
        }
        guard let total = kb("MemTotal:"), let avail = kb("MemAvailable:"), total > 0
        else { return nil }
        return min(max((total - avail) / total, 0), 1)
    }

    /// A Mac: total bytes from sysctl, then vm_stat's page size and its
    /// free, inactive and speculative pages, which is what `free` would
    /// call available.
    nonisolated private static func macMemory(_ mac: [String]) -> Double? {
        guard mac.count > 2,
              let total = Double(mac[0].trimmingCharacters(in: .whitespaces)), total > 0
        else { return nil }
        func pages(_ prefix: String) -> Double {
            mac.first { $0.hasPrefix(prefix) }?
                .split(separator: ":").last
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
                .flatMap { Double($0) } ?? 0
        }
        let pageSize = mac.first { $0.contains("page size of") }?
            .split(separator: " ")
            .compactMap { Double($0) }.first ?? 16384
        let available = (pages("Pages free") + pages("Pages inactive")
                         + pages("Pages speculative")) * pageSize
        return min(max((total - available) / total, 0), 1)
    }

    /// `cpu  user nice system idle iowait irq softirq steal …` per line,
    /// keyed by the first word. Busy is everything but idle and iowait.
    nonisolated private static func cpuCounters(_ lines: [String]) -> [String: (busy: Double, total: Double)] {
        var out: [String: (busy: Double, total: Double)] = [:]
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5, let key = f.first else { continue }
            let nums = f.dropFirst().prefix(8).compactMap { Double($0) }
            guard nums.count >= 4 else { continue }
            let total = nums.reduce(0, +)
            let idle = nums[3] + (nums.count > 4 ? nums[4] : 0)
            out[String(key)] = (total - idle, total)
        }
        return out
    }

    /// `/proc/net/dev` rows: `iface: rx_bytes … tx_bytes …`, summed over
    /// every interface but loopback.
    nonisolated private static func netCounters(_ lines: [String]) -> (rx: Double, tx: Double)? {
        guard !lines.isEmpty else { return nil }
        var rx = 0.0, tx = 0.0, any = false
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let iface = parts[0].trimmingCharacters(in: .whitespaces)
            guard iface != "lo" else { continue }
            let f = parts[1].split(separator: " ", omittingEmptySubsequences: true)
                .compactMap { Double($0) }
            guard f.count >= 9 else { continue }
            rx += f[0]
            tx += f[8]
            any = true
        }
        return any ? (rx, tx) : nil
    }
}

/// Bytes per second, the way a person says it.
func formatRate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
    let b = max(bytesPerSecond, 0)
    if b < 1024 { return (String(Int(b)), "B/s") }
    if b < 1024 * 1024 { return (String(format: "%.1f", b / 1024), "KB/s") }
    return (String(format: "%.2f", b / 1024 / 1024), "MB/s")
}
