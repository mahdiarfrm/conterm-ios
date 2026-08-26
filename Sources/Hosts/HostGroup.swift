import Foundation
import SwiftUI

/// A folder of hosts, browser-tab style.
///
/// Ported from Conterm's `TabGroup` — same eight colour keys, same decision
/// to store a key rather than a colour so the on-disk shape survives a
/// retheme, same `collapsed` flag persisted so a folded group stays folded.
/// The Mac app groups tabs; here it groups the machines those tabs connect
/// to, which is the same idea one level up.
struct HostGroup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// One of `HostGroup.colorKeys`.
    var colorKey: String
    /// Folded in the list: the header stays, its rows hide.
    var collapsed: Bool = false
    /// Where this group sits relative to the others.
    var order: Int = 0

    enum CodingKeys: String, CodingKey { case id, name, colorKey, collapsed, order }

    init(id: UUID = UUID(), name: String, colorKey: String,
         collapsed: Bool = false, order: Int = 0) {
        self.id = id
        self.name = name
        self.colorKey = colorKey
        self.collapsed = collapsed
        self.order = order
    }

    /// Tolerant of files written before a field existed, rather than failing
    /// the whole decode and losing every group.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorKey = try c.decode(String.self, forKey: .colorKey)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }

    static let colorKeys = [
        "blue", "purple", "pink", "red", "orange",
        "yellow", "green", "teal",
    ]

    /// Tuned for dark backgrounds, exactly as on the Mac.
    static func color(forKey key: String) -> Color {
        switch key {
        case "blue":   return Color(red: 0.42, green: 0.66, blue: 1.00)
        case "purple": return Color(red: 0.72, green: 0.56, blue: 1.00)
        case "pink":   return Color(red: 0.96, green: 0.56, blue: 0.78)
        case "red":    return Color(red: 0.97, green: 0.45, blue: 0.45)
        case "orange": return Color(red: 1.00, green: 0.62, blue: 0.32)
        case "yellow": return Color(red: 1.00, green: 0.86, blue: 0.34)
        case "green":  return Color(red: 0.48, green: 0.86, blue: 0.55)
        case "teal":   return Color(red: 0.42, green: 0.86, blue: 0.86)
        default:       return Color.gray
        }
    }

    var color: Color { Self.color(forKey: colorKey) }
}

/// Persists group definitions. Membership lives on `Host.groupID`, so a
/// group can be renamed or recoloured without touching a single host.
@Observable
@MainActor
final class HostGroupStore {
    private(set) var groups: [HostGroup] = []

    private let url: URL

    init(filename: String = "host-groups.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        load()
    }

    /// Create a group, cycling colours so two made in a row never match.
    @discardableResult
    func create(name: String) -> HostGroup {
        let used = Set(groups.map(\.colorKey))
        let key = HostGroup.colorKeys.first { !used.contains($0) }
            ?? HostGroup.colorKeys[groups.count % HostGroup.colorKeys.count]
        let group = HostGroup(name: name, colorKey: key,
                              order: (groups.map(\.order).max() ?? -1) + 1)
        groups.append(group)
        save()
        return group
    }

    func update(_ group: HostGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i] = group
        save()
    }

    /// Remove a group. Its hosts are not deleted — they fall back to
    /// ungrouped, which the caller has to apply since it owns the hosts.
    func delete(_ group: HostGroup) {
        groups.removeAll { $0.id == group.id }
        save()
    }

    func toggleCollapsed(_ group: HostGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i].collapsed.toggle()
        save()
    }

    func group(id: UUID?) -> HostGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// Groups in display order, newest last.
    var ordered: [HostGroup] {
        groups.sorted { ($0.order, $0.name.lowercased()) < ($1.order, $1.name.lowercased()) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HostGroup].self, from: data)
        else { return }
        groups = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
