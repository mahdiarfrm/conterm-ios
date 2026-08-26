import SwiftUI

/// Sums a machine into one colour, and says why.
///
/// Ported from Conterm's Host Overview. The thresholds matter and are worth
/// stating: amber is *maintenance* (failed units, a pending reboot, memory or
/// a disk near full); red is reserved for live distress — the CPU saturated
/// right now. A host that merely wants patching should not read the same as
/// one that is falling over.
enum HostHealth {
    case unknown
    case healthy
    case attention
    case distress

    var color: Color {
        switch self {
        case .unknown: return Theme.textSecondary.opacity(0.5)
        case .healthy: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .attention: return Theme.warning
        case .distress: return Theme.Status.danger
        }
    }

    static func of(_ info: HostInfo) -> HostHealth {
        if overloaded(info) { return .distress }
        if (info.failedUnits ?? 0) > 0 || info.rebootRequired
            || memoryHot(info) || diskHot(info) {
            return .attention
        }
        return .healthy
    }

    /// Load average above the core count: more runnable work than there are
    /// cores to run it.
    static func overloaded(_ info: HostInfo) -> Bool {
        guard let load = info.loadAvg, let cores = info.cores, cores > 0
        else { return false }
        return load.0 > Double(cores)
    }

    static func memoryHot(_ info: HostInfo) -> Bool {
        guard let total = info.memTotalMB, let avail = info.memAvailMB, total > 0
        else { return false }
        return Double(total - avail) / Double(total) > 0.92
    }

    static func diskHot(_ info: HostInfo) -> Bool {
        info.disks.contains { $0.pct > 0.9 }
    }

    /// What's wrong, most severe first, for the header line.
    static func alerts(_ info: HostInfo) -> [(HostHealth, String)] {
        var items: [(HostHealth, String)] = []
        if let failed = info.failedUnits, failed > 0 {
            items.append((.distress, "\(failed) failed unit\(failed == 1 ? "" : "s")"))
        }
        if overloaded(info) { items.append((.distress, "load above core count")) }
        if memoryHot(info) { items.append((.attention, "memory nearly full")) }
        for disk in info.disks where disk.pct > 0.9 {
            items.append((.attention, "\(disk.mount) \(Int(disk.pct * 100))% full"))
        }
        if info.rebootRequired { items.append((.attention, "reboot required")) }
        if let updates = info.updatesAvailable, !updates.isEmpty {
            items.append((.attention, updates.trimmingCharacters(in: .whitespaces)))
        }
        return items
    }

    var summary: String {
        switch self {
        case .unknown: return "Collecting…"
        case .healthy: return "Up and healthy"
        case .attention: return "Needs attention"
        case .distress: return "In trouble"
        }
    }
}
