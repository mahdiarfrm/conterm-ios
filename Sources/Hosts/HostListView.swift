import SwiftUI

/// The app's home screen: your hosts.
struct HostListView: View {
    let app: Ghostty.App

    @State private var store = HostStore()
    private var sessions: SessionStore { SessionStore.shared }
    @State private var query = ""
    @State private var session: TerminalSession?
    @State private var overview: Host?
    @State private var agentsFor: Host?
    @State private var contermOn: Host?
    @State private var route: Route?
    @State private var importing = false

    @State private var notice: String?

    @State private var groups = HostGroupStore()
    @State private var groupPrompt: GroupPrompt?
    @State private var newGroupName = ""
    private let editingGroups = false

    /// Everything this screen can put on top of itself.
    enum Route: Identifiable, Hashable {
        case palette, keys, settings, newHost, quickConnect
        case editHost(Host)

        var id: String {
            switch self {
            case .palette: return "palette"
            case .keys: return "keys"
            case .settings: return "settings"
            case .newHost: return "newHost"
            case .quickConnect: return "quickConnect"
            case .editHost(let host): return "edit-\(host.id)"
            }
        }
    }

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

    private var filtered: [Host] {
        let base = store.hosts.sorted {
            // Most recently used first, then alphabetical — the same
            // frecency instinct as Conterm's palette, minus the decay.
            switch ($0.lastConnectedAt, $1.lastConnectedAt) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.alias.lowercased() < $1.alias.lowercased()
            }
        }
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter {
            $0.alias.lowercased().contains(q) || $0.hostname.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                brandHeader
                Group {
                // A live session keeps the list on screen even with nothing
                // saved — Quick Connect shouldn't strand you on an empty state
                // while a shell of yours is running behind it.
                if store.hosts.isEmpty && sessions.live.isEmpty {
                    EmptyHostsView(route: $route, importing: $importing)
                } else {
                    list
                }
                }
                .frame(maxHeight: .infinity)
            }
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { paletteBar }
            // One sheet, not six. SwiftUI attaches each `.sheet` modifier to
            // the same view, and only one of them reliably wins — stacking
            // them is why the search bar sometimes did nothing when tapped.
            // A single presentation driven by a route can't race itself.
            .sheet(item: $route) { route in
                switch route {
                case .palette:
                    CommandPalette(store: store,
                                   onConnect: { host in self.route = nil; open(host) },
                                   onOverview: { host in self.route = nil; overview = host },
                                   onNewHost: { self.route = .newHost },
                                   onQuickConnect: { self.route = .quickConnect },
                                   onImport: { self.route = nil; importing = true },
                                   onKeys: { self.route = .keys })
                case .keys:
                    KeyLibraryView()
                case .settings:
                    SettingsView()
                case .newHost:
                    HostEditorView(store: store, groups: groups)
                case .editHost(let host):
                    HostEditorView(store: store, groups: groups, existing: host)
                case .quickConnect:
                    QuickConnectView(app: app, store: store) {
                        SessionStore.shared.adopt($0)
                        self.route = nil
                        session = $0
                    }
                }
            }
            // Same reasoning for the two group prompts: one alert, one route.
            .alert(groupPrompt?.title ?? "", isPresented: Binding(
                get: { groupPrompt != nil },
                set: { if !$0 { groupPrompt = nil; newGroupName = "" } })) {
                TextField("Name", text: $newGroupName)
                Button("Cancel", role: .cancel) { groupPrompt = nil; newGroupName = "" }
                Button(groupPrompt?.confirmTitle ?? "OK") { confirmGroupPrompt() }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { importConfig($0) }
            .navigationDestination(item: $session) { live in
                TerminalScreen(session: live) { host in
                    session = nil
                    openNew(host)
                }
            }
            .navigationDestination(item: $agentsFor) { AgentCenterView(host: $0) }
            .navigationDestination(item: $contermOn) { ContermRemoteView(host: $0) }
            .navigationDestination(item: $overview) { host in
                HostOverviewView(host: host) { target in
                    overview = nil
                    open(target)
                }
            }
            .alert("Import", isPresented: .constant(notice != nil)) {
                Button("OK") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
        .tint(Theme.accentOnDark)
        // Sessions that died keep their terminal readable while it is open;
        // once you are back here they are just clutter.
        .onAppear { sessions.pruneDead() }
    }

    private var brandHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                ContermWordmark(height: Theme.ui(30))
                    .foregroundStyle(Theme.accentOnDark)
                if !store.hosts.isEmpty {
                    Text("\(store.hosts.count) host\(store.hosts.count == 1 ? "" : "s")")
                        .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            headerButton("key") { route = .keys }
            headerButton("gearshape") { route = .settings }
            headerButton("plus") { route = .newHost }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .rollUp()
    }

    private func headerButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.fire(.light)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: Theme.ui(15), weight: .semibold))
                .foregroundStyle(Theme.accentOnDark)
                .frame(width: Theme.ui(38), height: Theme.ui(38))
                .glassPill(tone: .dark)
        }
        .buttonStyle(PressablePill(scale: 0.9))
    }

    private var paletteBar: some View {
        Button {
            route = .palette
            Haptics.shared.fire(.light)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.ui(14), weight: .medium))
                Text("Search hosts, actions, or a sum")
                    .font(.system(size: Theme.ui(14), weight: .medium, design: .rounded))
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 18)
            .frame(height: Theme.ui(50))
            .floatingGlass()
            // The glass is `.interactive()` on iOS 26, which installs its own
            // touch handling inside the button's label. Declaring the hit
            // shape explicitly means the tap is resolved by the button's own
            // frame rather than by whatever the effect decided its shape was.
            .contentShape(Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 7)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .buttonStyle(PressablePill())
    }

    private var list: some View {
        List {
            // Live shells come first, always. They are the things with state
            // in them — a running job, a half-typed command — and burying
            // them under a host list you have to remember to scroll is how
            // you end up opening a second connection by accident.
            if !sessions.live.isEmpty {
                Section {
                    ForEach(sessions.live) { live in
                        Button { session = live } label: {
                            SessionRow(session: live,
                                       siblings: sessions.liveCount(for: live.host))
                        }
                            .buttonStyle(PressableRow())
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.stroke)
                            .swipeActions(edge: .trailing) {
                                Button("Disconnect") {
                                    sessions.close(live)
                                    SoundEffects.shared.play(.disconnect)
                                }
                                .tint(Theme.Action.destructive)
                            }
                    }
                } header: {
                    sectionHeader("Live sessions", count: sessions.live.count)
                }
            }

            // Searching flattens the groups. A query is a question about
            // every host you have, and hiding half the answers inside a
            // folded folder would be a lie.
            if !query.isEmpty {
                Section {
                    hostRows(filtered)
                } header: {
                    sectionHeader("Matches", count: filtered.count)
                }
            } else {
                ForEach(groups.ordered) { group in
                    let members = filtered.filter { $0.groupID == group.id }
                    if !members.isEmpty || editingGroups {
                        Section {
                            if !group.collapsed { hostRows(members) }
                        } header: {
                            groupHeader(group, count: members.count)
                        }
                    }
                }

                let loose = filtered.filter { host in
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func hostRows(_ hosts: [Host]) -> some View {
        ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
            HStack(spacing: 0) {
                Button { open(host) } label: {
                    HostRow(host: host, group: groups.group(id: host.groupID))
                }
                .buttonStyle(PressableRow())
                // The briefing is a peer of connecting, not buried in a
                // menu — "how is that box?" is the question you open the
                // app for as often as "give me a shell".
                Button { overview = host } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: Theme.ui(15), weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.stroke)
            .revealCascade(index)
            .swipeActions(edge: .trailing) {
                Button("Delete") { store.delete(host) }
                    .tint(Theme.Action.destructive)
                Button("Edit") { route = .editHost(host) }
                    .tint(Theme.Action.neutral)
            }
            .contextMenu { groupMenu(for: host) }
        }
    }

    /// Move a host between groups without opening the editor. Assigning a
    /// folder is a one-tap decision and should cost one long-press, not a
    /// round trip through a form.
    @ViewBuilder
    private func groupMenu(for host: Host) -> some View {
        Menu("Move to group", systemImage: "folder") {
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
                openNew(host)
            }
        }
        Button("Edit host", systemImage: "pencil") { route = .editHost(host) }
        Button("Overview", systemImage: "info.circle") { overview = host }
        Button("Agents", systemImage: "sparkles") { agentsFor = host }
        Button("Conterm on this Mac", systemImage: "macwindow") { contermOn = host }
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
                    .shadow(color: group.color.opacity(0.7), radius: 3)
                Text(group.name.uppercased())
                    .font(.system(size: Theme.ui(11), weight: .bold))
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

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: Theme.ui(11), weight: .bold))
                .tracking(1.1)
            Text("\(count)")
                .font(.system(size: Theme.ui(11), weight: .bold, design: .monospaced))
                .monospacedDigit()
                .opacity(0.65)
            Spacer()
        }
        .foregroundStyle(Theme.textSecondary)
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

    /// Always a fresh shell, even if this host already has one.
    private func openNew(_ host: Host) {
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            SoundEffects.shared.play(.error)
            route = .editHost(host)
            return
        }
        SoundEffects.shared.tap(.connect, haptic: .medium)
        session = sessions.newSession(for: host, app: app, credentials: credentials)
        store.noteConnected(host)
    }

    private func open(_ host: Host) {
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            // No secret stored — send them to the editor rather than opening a
            // terminal that can only fail.
            SoundEffects.shared.play(.error)
            Haptics.shared.fire(.warning)
            route = .editHost(host)
            return
        }
        SoundEffects.shared.tap(.connect, haptic: .medium)
        // Resumes the shell if this host already has one. Opening a second
        // connection to a box you are already on is never what the tap meant.
        let s = SessionStore.shared.session(for: host, app: app,
                                            credentials: credentials)
        store.noteConnected(host)
        session = s
    }

    private func importConfig(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let parsed = SSHConfig.parse(fileAt: url)
        let added = store.merge(parsed.hosts, defaultUsername: "root")

        var message = "Imported \(added) host\(added == 1 ? "" : "s")."
        if added < parsed.hosts.count {
            message += " \(parsed.hosts.count - added) already existed."
        }
        if !parsed.unresolvedIncludes.isEmpty {
            // Never lose half a fleet quietly.
            message += " \(parsed.unresolvedIncludes.count) Include(s) couldn't be followed."
        }
        message += " Each host still needs a password or key before it can connect."
        notice = message
    }
}

/// A shell you already have open.
///
/// Deliberately not the same shape as a host row: this one is *live*, and the
/// difference has to be legible at a glance or the two sections read as one
/// list with a duplicate in it. The gem pulses while connecting, the subtitle
/// says what the session is doing rather than where it lives, and the grid
/// size is there because it is the one number that proves the far end and the
/// terminal agree.
private struct SessionRow: View {
    let session: TerminalSession
    /// How many live shells this host has, so "#2" only appears when it means
    /// something.
    var siblings: Int = 1

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint.opacity(0.7), radius: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title ?? session.host.alias)
                    .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if siblings > 1 {
                    Text("#\(session.ordinal)")
                        .font(.system(size: Theme.ui(10), weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Text(subtitle)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if case .connected = session.state {
                Text("\(session.grid.columns)\u{00d7}\(session.grid.rows)")
                    .font(.system(size: Theme.ui(10), weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassPill(tone: .dark)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: Theme.ui(11), weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch session.state {
        case .connecting: return Theme.Status.working
        case .connected:  return Theme.Status.ready
        case .failed:     return Theme.Status.danger
        case .closed:     return Theme.Status.neutral
        }
    }

    private var subtitle: String {
        switch session.state {
        case .connecting: return "connecting\u{2026}"
        case .connected:  return session.host.displaySubtitle
        case .failed(let why): return why
        case .closed(let why): return why ?? "closed"
        }
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
                .shadow(color: gemColor.opacity(0.6), radius: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.alias)
                    .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(host.displaySubtitle)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            if liveCount > 0 {
                Text(liveCount == 1 ? "open" : "\(liveCount) open")
                    .font(.system(size: Theme.ui(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Status.ready)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassPill(tone: .dark)
            } else if !hasSecret {
                Text("no key")
                    .font(.system(size: Theme.ui(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassPill(tone: .dark)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: Theme.ui(11), weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
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
    @Binding var route: HostListView.Route?
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .rollUp(delay: 0.05)
            Text("No hosts yet")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .rollUp(delay: 0.11)
            Text("Connect straight away with user@host, or save hosts you use often.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .rollUp(delay: 0.17)

            Button("Quick Connect") { route = .quickConnect }
                .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.paneTile)
                .padding(.horizontal, 22)
                .frame(height: Theme.hitTarget)
                .background(Capsule().fill(Theme.accentOnDark))
                .padding(.top, 6)
                .rollUp(delay: 0.23)

            HStack(spacing: 10) {
                Button("Add host") { route = .newHost }
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accentOnDark)
                    .padding(.horizontal, 18)
                    .frame(height: Theme.hitTarget)
                    .glassPill(tone: .dark)

                Button("Keys") { route = .keys }
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accentOnDark)
                    .padding(.horizontal, 18)
                    .frame(height: Theme.hitTarget)
                    .glassPill(tone: .dark)

                Button("Import ssh config") { importing = true }
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accentOnDark)
                    .padding(.horizontal, 18)
                    .frame(height: Theme.hitTarget)
                    .glassPill(tone: .dark)
            }
            .padding(.top, 4)
            .rollUp(delay: 0.29)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
