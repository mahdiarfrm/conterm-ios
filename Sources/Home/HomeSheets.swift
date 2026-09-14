import SwiftUI

/// The plus button: a shell, now. Saved hosts first, most recent at the
/// top; the ways to reach a host that isn't saved beneath them.
struct ConnectSheet: View {
    let store: HostStore
    let groups: HostGroupStore
    @Environment(HomeRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    private var hosts: [Host] {
        store.hosts.sorted {
            switch ($0.lastConnectedAt, $1.lastConnectedAt) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.alias.lowercased() < $1.alias.lowercased()
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !hosts.isEmpty {
                    Section {
                        ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                            Button {
                                SoundEffects.shared.tap(.paletteConfirm, haptic: .medium)
                                router.afterDismiss { router.open(host) }
                            } label: {
                                hostRow(host)
                            }
                            .buttonStyle(PressableRow())
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.stroke)
                            .revealCascade(index)
                        }
                    } header: {
                        caption("Saved hosts")
                    }
                }
                Section {
                    action("Quick Connect", detail: "user@host, nothing saved",
                           symbol: "bolt.horizontal.fill") { router.route = .quickConnect }
                    action("New host", detail: "Save a host you use often",
                           symbol: "plus.circle") { router.route = .newHost }
                    action("Import ssh config", detail: "Bring across a fleet of hosts",
                           symbol: "square.and.arrow.down") {
                        router.afterDismiss { router.importing = true }
                    }
                } header: {
                    caption("Somewhere new")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .creamSheet()
            .navigationTitle("Open a shell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(Theme.Brand.ink)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.font(Theme.ui(11), .bold))
            .tracking(1.1)
            .foregroundStyle(Theme.textSecondary)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 6, trailing: 20))
            .textCase(nil)
    }

    private func hostRow(_ host: Host) -> some View {
        let live = SessionStore.shared.liveCount(for: host)
        let group = groups.group(id: host.groupID)
        let gem = live > 0 ? Theme.Status.ready : (group?.color ?? Theme.Status.neutral)
        return HStack(spacing: 11) {
            Circle().fill(gem).frame(width: 6, height: 6)
            DistroMark(distro: host.distro.flatMap(Distro.init(rawValue:)), size: 16)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.alias)
                    .font(Theme.font(Theme.ui(15), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(host.displaySubtitle)
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if live > 0 {
                Text(live == 1 ? "back to shell" : "\(live) open")
                    .font(Theme.font(Theme.ui(10), .semibold))
                    .badgePill(tint: Theme.Status.ready)
            } else if !KeyStore.shared.hasSecret(for: host) {
                Text("no key")
                    .font(Theme.font(Theme.ui(10), .semibold))
                    .badgePill(tint: Theme.Status.attention)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func action(_ title: String, detail: String, symbol: String,
                        run: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.fire(.light)
            run()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(14), weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.font(Theme.ui(14), .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRow())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.stroke)
    }
}

/// Which panels the home shows, and in what order. Drag to reorder; a
/// panel switched off stays in the list so it can be switched back on.
struct PanelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = Preferences.shared

    private var enabled: [HomePanelKind] {
        prefs.homePanels.compactMap(HomePanelKind.init(rawValue:))
    }

    private var ordered: [HomePanelKind] {
        enabled + HomePanelKind.allCases.filter { !enabled.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ordered) { kind in
                        row(kind)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.stroke)
                            .deleteDisabled(true)
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Drag to reorder. Every panel is drawn from what the app already knows; none of them costs a connection.")
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .creamSheet()
            .navigationTitle("Panels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(Theme.font(Theme.ui(15), .semibold))
                }
            }
        }
        .tint(Theme.Brand.ink)
    }

    private func row(_ kind: HomePanelKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: Theme.ui(14), weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(Theme.font(Theme.ui(15), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.summary)
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { enabled.contains(kind) },
                set: { on in
                    Haptics.shared.fire(.selection)
                    withAnimation(Theme.Spring.snappy) {
                        if on {
                            prefs.homePanels.append(kind.rawValue)
                        } else {
                            prefs.homePanels.removeAll { $0 == kind.rawValue }
                        }
                    }
                }))
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 6)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var all = ordered
        all.move(fromOffsets: source, toOffset: destination)
        let on = Set(prefs.homePanels)
        prefs.homePanels = all.map(\.rawValue).filter { on.contains($0) }
    }
}
