import SwiftUI
import os

/// The Machines tab: everything a shell can be opened on, on a cream
/// card. This phone first, Macs found on the network next, then the saved
/// hosts in their groups. Every row carries its own ways in: a shell on
/// tap, the overview or the Mac's panes as a pill, the files beside it.
/// What is running lives on the home, in the deck; here is where it is
/// started from.
struct HostListView: View {
    let store: HostStore
    let groups: HostGroupStore
    let nearby: NearbyMacs
    /// A Mac being paired, its sheet up.
    @State private var pairing: NearbyMacs.Found?
    let zoom: Namespace.ID

    @Environment(HomeRouter.self) private var router
    private var sessions: SessionStore { SessionStore.shared }

    @State private var groupPrompt: GroupPrompt?
    @State private var newGroupName = ""

    /// The two text prompts groups need, as one thing.
    enum GroupPrompt: Identifiable, Hashable {
        case newGroup(forHost: Host)
        case rename(HostGroup)

        var id: String {
            switch self {
            case .newGroup(let host): return "new-\(host.id)"
            case .rename(let group): return "rename-\(group.id)"
            }
        }
        var title: String {
            switch self {
            case .newGroup: return "New group"
            case .rename: return "Rename group"
            }
        }
        var confirmTitle: String {
            switch self {
            case .newGroup: return "Create"
            case .rename: return "Rename"
            }
        }
    }

    private var sorted: [Host] {
        store.hosts.sorted {
            // Most recently used first, then alphabetical — the same
            // frecency instinct as Conterm's palette, minus the decay.
            switch ($0.lastConnectedAt, $1.lastConnectedAt) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.alias.lowercased() < $1.alias.lowercased()
            }
        }
    }

    /// Nothing saved: the card carries the empty state. A shell running on
    /// an unsaved host is on the home's deck, so nothing is stranded here.
    private var nothingToShow: Bool { store.hosts.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(title: "Machines", count: store.hosts.count, symbol: "plus") {
                router.route = .newHost
            }
            // The specific things that belong to hosts, as chips: the keys
            // they connect with, the commands you keep for them, the file
            // they can be imported from.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Keys", count: KeyLibrary.shared.keys.count,
                         symbol: "key.horizontal.fill") { router.route = .keys }
                        .popIn(0, base: 0.12, enabled: true)
                    chip("Snippets", count: SnippetStore.shared.snippets.count,
                         symbol: "apple.terminal.fill") { router.route = .snippets }
                        .popIn(1, base: 0.12, enabled: true)
                    chip("Import ssh config", count: nil,
                         symbol: "square.and.arrow.down") { router.importing = true }
                        .popIn(2, base: 0.12, enabled: true)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
            Group {
                if nothingToShow {
                    VStack(spacing: 0) {
                        if !unsavedNearby.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                sectionHeader("Nearby", count: unsavedNearby.count)
                                ForEach(unsavedNearby) { mac in
                                    NearbyRow(mac: mac, onAdd: { add(mac) },
                                              onPair: mac.pairPort == nil ? nil : { pairing = mac })
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.top, 6)
                            .transition(.morph)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            sectionHeader("This iPhone", count: 1)
                            LinuxRow(machine: LinuxMachine.shared) {
                                router.openLinux(from: HomeRouter.zoomID(LinuxMachine.host))
                            }
                            .matchedTransitionSource(id: HomeRouter.zoomID(LinuxMachine.host), in: zoom)
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        EmptyHostsView()
                    }
                    .animation(Theme.Spring.morph, value: unsavedNearby.count)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $pairing) { PairSheet(mac: $0) }
        // `CONTERM_LINUX=1`: boot the Linux machine at launch, by itself.
        .task {
            guard LinuxMachine.tour else { return }
            try? await Task.sleep(for: .seconds(1))
            Logger(subsystem: "dev.conterm.ios", category: "tour").notice("tour: linux boot")
            router.openLinux(from: HomeRouter.zoomID(LinuxMachine.host))
        }
        // `CONTERM_PAIR=1`: pair with the first Mac that offers it, by
        // itself, so the whole exchange can be watched on the simulator.
        .task {
            guard ProcessInfo.processInfo.environment["CONTERM_PAIR"] != nil else { return }
            while !Task.isCancelled, pairing == nil {
                if let mac = nearby.found.first(where: { $0.pairPort != nil }) {
                    Logger(subsystem: "dev.conterm.ios", category: "tour").notice("tour: pair start")
                    pairing = mac
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .creamCard()
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .arrive(0, enabled: true)
        // On an iPad the same list stretched to 1024pt reads as a phone
        // screen someone pulled at the corners. A column has a readable
        // width whatever the window is.
        .contermReadableColumn(740)
        // One alert, one route, for the two group prompts.
        .alert(groupPrompt?.title ?? "", isPresented: Binding(
            get: { groupPrompt != nil },
            set: { if !$0 { groupPrompt = nil; newGroupName = "" } })) {
            TextField("Name", text: $newGroupName)
            Button("Cancel", role: .cancel) { groupPrompt = nil; newGroupName = "" }
            Button(groupPrompt?.confirmTitle ?? "OK") { confirmGroupPrompt() }
        }
    }

    private func chip(_ title: String, count: Int?, symbol: String,
                      action: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.fire(.light)
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(11), weight: .semibold))
                Text(title)
                    .font(Theme.font(Theme.ui(12), .semibold))
                if let count {
                    Text("\(count)")
                        .font(.system(size: Theme.ui(11), weight: .bold, design: .monospaced))
                        .opacity(0.7)
                        .rollingDigits(on: count)
                }
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .frame(height: Theme.ui(32))
            .background(Capsule(style: .continuous).fill(Theme.accentSoft))
        }
        .buttonStyle(PressablePill(scale: 0.92))
    }

    /// Discovered Macs that aren't already in the list. A Mac you have
    /// already added is not a discovery, it is a duplicate.
    private var unsavedNearby: [NearbyMacs.Found] {
        let known = Set(store.hosts.map { $0.hostname.lowercased() })
        return nearby.found.filter { !known.contains($0.hostname.lowercased()) }
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

    private var list: some View {
        List {
            // The Linux machine on this phone. Not a host: nothing is
            // connected to, and there is exactly one.
            Section {
                LinuxRow(machine: LinuxMachine.shared) {
                    router.openLinux(from: HomeRouter.zoomID(LinuxMachine.host))
                }
                .matchedTransitionSource(id: HomeRouter.zoomID(LinuxMachine.host), in: zoom)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.stroke)
            } header: {
                sectionHeader("This iPhone", count: 1)
            }

            // Macs on this network that are running Conterm, and are not
            // already saved. Above the saved list: it is an offer, not a
            // list of things you own.
            if !unsavedNearby.isEmpty {
                Section {
                    ForEach(unsavedNearby) { mac in
                        NearbyRow(mac: mac, onAdd: { add(mac) },
                                  onPair: mac.pairPort == nil ? nil : { pairing = mac })
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.stroke)
                    }
                } header: {
                    sectionHeader("Nearby", count: unsavedNearby.count)
                }
            }

            ForEach(groups.ordered) { group in
                let members = sorted.filter { $0.groupID == group.id }
                if !members.isEmpty {
                    Section {
                        if !group.collapsed { hostRows(members) }
                    } header: {
                        groupHeader(group, count: members.count)
                    }
                }
            }

            let loose = sorted.filter { host in
                host.groupID == nil || groups.group(id: host.groupID) == nil
            }
            if !loose.isEmpty {
                Section {
                    hostRows(loose)
                } header: {
                    sectionHeader(groups.groups.isEmpty ? "Hosts" : "Ungrouped",
                                  count: loose.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
    }

    @ViewBuilder
    private func hostRows(_ hosts: [Host]) -> some View {
        ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
            let isMac = host.distro == Distro.macos.rawValue
            HStack(spacing: 6) {
                Button { router.open(host, from: HomeRouter.zoomID(host)) } label: {
                    HostRow(host: host, group: groups.group(id: host.groupID),
                            liveCount: sessions.liveCount(for: host))
                }
                .buttonStyle(PressableRow())
                .matchedTransitionSource(id: HomeRouter.zoomID(host), in: zoom)
                // The second way in is a peer of connecting, not buried in
                // a menu: "how is that box?" on a server, "what did I leave
                // open?" on a Mac. The third, the files, sits beside it.
                if isMac {
                    pill("Panes", symbol: "macwindow") { router.showPanes(host) }
                        .accessibilityLabel("Panes on \(host.alias)")
                    circle("waveform.path.ecg") {
                        router.showOverview(host, from: HomeRouter.overviewZoomID(host))
                    }
                    .matchedTransitionSource(id: HomeRouter.overviewZoomID(host), in: zoom)
                    .accessibilityLabel("Overview of \(host.alias)")
                } else {
                    pill("Overview", symbol: "waveform.path.ecg") {
                        router.showOverview(host, from: HomeRouter.overviewZoomID(host))
                    }
                    .matchedTransitionSource(id: HomeRouter.overviewZoomID(host), in: zoom)
                    .accessibilityLabel("Overview of \(host.alias)")
                    circle("folder.fill") { router.showFiles(host) }
                        .accessibilityLabel("Files on \(host.alias)")
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.stroke)
            .revealCascade(index)
            .swipeActions(edge: .trailing) {
                Button("Delete") { store.delete(host) }
                    .tint(Theme.Action.destructive)
                Button("Edit") { router.route = .editHost(host) }
                    .tint(Theme.Action.neutral)
            }
            .contextMenu { groupMenu(for: host) }
        }
    }

    /// A row's second way in, with a word on it.
    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(11), weight: .bold))
                Text(title)
                    .font(Theme.font(Theme.ui(12), .bold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .frame(height: Theme.ui(34))
            .background(Capsule(style: .continuous).fill(Theme.accentSoft))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressablePill(scale: 0.9))
    }

    /// A row's third way in: one glyph in a circle.
    private func circle(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.ui(12), weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.ui(34), height: Theme.ui(34))
                .background(Circle().fill(Theme.accentSoft))
                .contentShape(Circle())
        }
        .buttonStyle(PressablePill(scale: 0.9))
    }

    /// Move a host between groups without opening the editor. Assigning a
    /// folder is a one-tap decision and should cost one long-press, not a
    /// round trip through a form.
    @ViewBuilder
    private func groupMenu(for host: Host) -> some View {
        Button("Files", systemImage: "folder") { router.showFiles(host) }
        if host.distro != Distro.macos.rawValue, !Handoff.macs.isEmpty {
            Button("Continue on Mac", systemImage: "macbook.and.iphone") {
                router.continueOnMac(host)
            }
        }
        Divider()
        Menu("Move to group", systemImage: "folder.badge.gearshape") {
            ForEach(groups.ordered) { group in
                Button {
                    var updated = host
                    updated.groupID = group.id
                    store.update(updated)
                    Haptics.shared.fire(.selection)
                } label: {
                    Label(group.name, systemImage: host.groupID == group.id
                          ? "checkmark.circle.fill" : "circle")
                }
            }
            if host.groupID != nil {
                Divider()
                Button("Remove from group") {
                    var updated = host
                    updated.groupID = nil
                    store.update(updated)
                }
            }
            Divider()
            Button("New group\u{2026}", systemImage: "folder.badge.plus") {
                groupPrompt = .newGroup(forHost: host)
            }
        }
        if sessions.liveCount(for: host) > 0 {
            Button("Open another shell", systemImage: "plus.rectangle.on.rectangle") {
                router.openNew(host)
            }
        }
        Button("Edit host", systemImage: "pencil") { router.route = .editHost(host) }
        Button("Overview", systemImage: "waveform.path.ecg") { router.showOverview(host) }
        Button("Agents", systemImage: "sparkles") { router.agentsFor = host }
        Button("Panes on this Mac", systemImage: "macwindow") { router.showPanes(host) }
    }

    private func groupHeader(_ group: HostGroup, count: Int) -> some View {
        Button {
            withAnimation(Theme.Spring.snappy) { groups.toggleCollapsed(group) }
            Haptics.shared.fire(.light)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.ui(9), weight: .bold))
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                Circle()
                    .fill(group.color)
                    .frame(width: 6, height: 6)
                Text(group.name.uppercased())
                    .font(Theme.font(Theme.ui(11), .bold))
                    .tracking(1.1)
                Text("\(count)")
                    .font(.system(size: Theme.ui(11), weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .opacity(0.65)
                Spacer()
            }
            .foregroundStyle(group.color)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 6, trailing: 20))
        .listRowBackground(Color.clear)
        .textCase(nil)
        .contextMenu {
            Button("Rename\u{2026}", systemImage: "pencil") {
                newGroupName = group.name
                groupPrompt = .rename(group)
            }
            Button("Delete group", systemImage: "trash", role: .destructive) {
                for host in store.hosts where host.groupID == group.id {
                    var updated = host
                    updated.groupID = nil
                    store.update(updated)
                }
                groups.delete(group)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int,
                               tint: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Theme.font(Theme.ui(11), .bold))
                .tracking(1.1)
            Text("\(count)")
                .font(.system(size: Theme.ui(11), weight: .bold, design: .monospaced))
                .monospacedDigit()
                .opacity(0.65)
                .rollingDigits(on: count)
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 6, trailing: 20))
        .listRowBackground(Color.clear)
        .textCase(nil)
    }

    private func confirmGroupPrompt() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        defer { groupPrompt = nil; newGroupName = "" }
        guard !name.isEmpty, let prompt = groupPrompt else { return }
        switch prompt {
        case .newGroup(let host):
            var updated = host
            updated.groupID = groups.create(name: name).id
            store.update(updated)
        case .rename(var group):
            group.name = name
            groups.update(group)
        }
    }
}

/// The title row of a cream card that is a tab: the name, a count, and the
/// one thing you can add.
struct CardHeader: View {
    let title: String
    var count: Int?
    var symbol: String?
    var animated = true
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(Theme.font(Theme.ui(34), .heavy))
                .foregroundStyle(Theme.textPrimary)
                .rollUp(enabled: true)
            if let count, count > 0 {
                Text("\(count)")
                    .font(Theme.font(Theme.ui(16), .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .rollingDigits(on: count)
                    .rollUp(delay: 0.05, enabled: true)
            }
            Spacer(minLength: 0)
            if let symbol, let action {
                Button {
                    Haptics.shared.fire(.light)
                    action()
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: Theme.ui(14), weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: Theme.ui(38), height: Theme.ui(38))
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(PressablePill(scale: 0.86))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 10 }
                .rollUp(delay: 0.08, enabled: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }
}

private struct HostRow: View {
    let host: Host
    var group: HostGroup?
    var liveCount: Int = 0

    var body: some View {
        HStack(spacing: 11) {
            // The gem carries two facts at once: colour is the group, fill is
            // whether this host can actually connect. A grouped host with no
            // key still reads as "no key" via the badge on the right.
            Circle()
                .fill(gemColor)
                .frame(width: 6, height: 6)

            DistroMark(distro: host.distro.flatMap(Distro.init(rawValue:)), size: Theme.ui(16))
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.alias)
                    .font(Theme.font(Theme.ui(15), .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(host.displaySubtitle)
                    .font(Theme.font(Theme.ui(12), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if liveCount > 0 {
                Text(liveCount == 1 ? "open" : "\(liveCount) open")
                    .font(Theme.font(Theme.ui(10), .semibold))
                    .badgePill(tint: Theme.Status.ready)
            } else if !hasSecret {
                Text("no key")
                    .font(Theme.font(Theme.ui(10), .semibold))
                    .badgePill(tint: Theme.Status.attention)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var hasSecret: Bool { KeyStore.shared.hasSecret(for: host) }

    private var gemColor: Color {
        if let group { return group.color }
        return hasSecret ? Theme.Status.ready : Theme.Status.neutral
    }
}

private struct EmptyHostsView: View {
    @Environment(HomeRouter.self) private var router

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .rollUp(delay: 0.05)
            Text("No hosts yet")
                .font(Theme.font(19, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .rollUp(delay: 0.11)
            Text("Connect straight away with user@host, or save hosts you use often.")
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .rollUp(delay: 0.17)

            Button("Quick Connect") { router.route = .quickConnect }
                .font(Theme.font(Theme.ui(15), .semibold))
                .filledPill()
                .buttonStyle(PressablePill())
                .padding(.top, 6)
                .rollUp(delay: 0.23)

            HStack(spacing: 10) {
                Button("Add host") { router.route = .newHost }
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .softPill()
                    .buttonStyle(PressablePill())

                Button("Keys") { router.route = .keys }
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .softPill()
                    .buttonStyle(PressablePill())

                Button("Import ssh config") { router.importing = true }
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .softPill()
                    .buttonStyle(PressablePill())
            }
            .padding(.top, 4)
            .rollUp(delay: 0.29)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Mac found on the network, offered rather than listed.
///
/// When the Mac says Remote Login is off the row says so instead of pretending
/// it can be added — the connection would be refused, and "connection refused"
/// three screens later is a worse way to learn it.
struct NearbyRow: View {
    let mac: NearbyMacs.Found
    let onAdd: () -> Void
    /// Pairing, when the Mac offers it: a key made here, allowed there.
    var onPair: (() -> Void)?

    private var canAct: Bool { onPair != nil || mac.sshEnabled }

    var body: some View {
        Button(action: onPair ?? (mac.sshEnabled ? onAdd : {})) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: Theme.ui(15), weight: .medium))
                    .foregroundStyle(mac.sshEnabled ? Theme.accent : Theme.textSecondary)
                    .frame(width: Theme.ui(22))

                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name)
                        .font(Theme.font(Theme.ui(15), .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(mac.sshEnabled ? Theme.textSecondary : Theme.Status.attention)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if canAct {
                    Text(onPair != nil ? "Pair" : "Add")
                        .font(Theme.font(Theme.ui(12), .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(Theme.accent))
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(PressableRow())
        .disabled(!canAct)
    }

    private var subtitle: String {
        guard mac.sshEnabled else {
            return onPair != nil
                ? "Remote Login is off on that Mac. Pair anyway; the Mac opens the switch."
                : "Remote Login is off — turn it on in System Settings → "
                 + "General → Sharing on that Mac."
        }
        var parts = [mac.hostname]
        if let version = mac.appVersion { parts.append("Conterm \(version)") }
        return parts.joined(separator: " · ")
    }
}

/// Debian on this phone: one row, whatever the machine is doing.
struct LinuxRow: View {
    let machine: LinuxMachine
    let onOpen: () -> Void

    private var available: Bool { LinuxMachine.imageURL != nil }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                DistroMark(distro: .debian, size: Theme.ui(16))
                    .foregroundStyle(available ? Theme.accent : Theme.textSecondary)
                    .frame(width: Theme.ui(22))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Debian")
                        .font(Theme.font(Theme.ui(15), .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(subtitleTint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .morph(on: subtitle, alignment: .leading)
                }

                Spacer(minLength: 8)

                if available {
                    Text(action)
                        .font(Theme.font(Theme.ui(12), .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(Theme.accent))
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(PressableRow())
        .disabled(!available)
    }

    private var subtitle: String {
        guard available else {
            return "This build has no Linux image. Run scripts/linux-image.sh and build again."
        }
        switch machine.state {
        case .off: return "Linux on this iPhone \u{00b7} off"
        case .starting(let phase): return "Linux on this iPhone \u{00b7} \(phase)\u{2026}"
        case .running: return "Linux on this iPhone \u{00b7} running"
        case .stopped(let reason): return reason
        }
    }

    private var subtitleTint: Color {
        if case .stopped = machine.state { return Theme.Status.attention }
        return Theme.textSecondary
    }

    private var action: String {
        switch machine.state {
        case .off, .stopped: return "Boot"
        case .starting, .running: return "Open"
        }
    }
}
