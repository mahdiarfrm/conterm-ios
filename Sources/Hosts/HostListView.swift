import SwiftUI

/// The app's home screen: your hosts.
struct HostListView: View {
    let app: Ghostty.App

    @State private var store = HostStore()
    @State private var query = ""
    @State private var session: TerminalSession?
    @State private var overview: Host?
    @State private var editing: Host?
    @State private var creating = false
    @State private var importing = false
    @State private var quickConnecting = false
    @State private var notice: String?
    @State private var paletteOpen = false

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
            Group {
                if store.hosts.isEmpty {
                    EmptyHostsView(creating: $creating,
                                   importing: $importing,
                                   quickConnecting: $quickConnecting)
                } else {
                    list
                }
            }
            .background(Theme.backdropDark.ignoresSafeArea())
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ContermWordmark(height: 18)
                        .foregroundStyle(Theme.accentOnDark)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { quickConnecting = true } label: {
                            Label("Quick Connect", systemImage: "bolt.horizontal.fill")
                        }
                        Button { creating = true } label: {
                            Label("New Host", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { paletteBar }
            .sheet(isPresented: $paletteOpen) {
                CommandPalette(store: store,
                               onConnect: { open($0) },
                               onOverview: { overview = $0 },
                               onNewHost: { creating = true },
                               onQuickConnect: { quickConnecting = true },
                               onImport: { importing = true })
            }
            .sheet(isPresented: $creating) { HostEditorView(store: store) }
            .sheet(isPresented: $quickConnecting) {
                QuickConnectView(app: app, store: store) { session = $0 }
            }
            .sheet(item: $editing) { host in
                HostEditorView(store: store, existing: host)
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { importConfig($0) }
            .navigationDestination(item: $session) { TerminalScreen(session: $0) }
            .navigationDestination(item: $overview) { HostOverviewView(host: $0) }
            .alert("Import", isPresented: .constant(notice != nil)) {
                Button("OK") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
        .tint(Theme.accentOnDark)
    }

    private var paletteBar: some View {
        Button {
            paletteOpen = true
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
            .padding(.horizontal, 16)
            .frame(height: Theme.ui(46))
            .glassPill(tone: .dark)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        List {
            ForEach(filtered) { host in
                HStack(spacing: 0) {
                    Button { open(host) } label: { HostRow(host: host) }
                        .buttonStyle(.plain)
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
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { store.delete(host) }
                    Button("Edit") { editing = host }.tint(Theme.Status.working)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func open(_ host: Host) {
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            // No secret stored — send them to the editor rather than opening a
            // terminal that can only fail.
            SoundEffects.shared.play(.error)
            Haptics.shared.fire(.warning)
            editing = host
            return
        }
        SoundEffects.shared.tap(.connect, haptic: .medium)
        let s = TerminalSession(host: host, app: app)
        s.connect(credentials: credentials)
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

private struct HostRow: View {
    let host: Host

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(hasSecret ? Theme.Status.ready : Theme.Status.neutral)
                .frame(width: 6, height: 6)
                .shadow(color: (hasSecret ? Theme.Status.ready : Theme.Status.neutral)
                    .opacity(0.6), radius: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.alias)
                    .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(host.displaySubtitle)
                    .font(.system(size: Theme.ui(12), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            if !hasSecret {
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
}

private struct EmptyHostsView: View {
    @Binding var creating: Bool
    @Binding var importing: Bool
    @Binding var quickConnecting: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("No hosts yet")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Connect straight away with user@host, or save hosts you use often.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Quick Connect") { quickConnecting = true }
                .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.paneTile)
                .padding(.horizontal, 22)
                .frame(height: Theme.hitTarget)
                .background(Capsule().fill(Theme.accentOnDark))
                .padding(.top, 4)

            HStack(spacing: 10) {
                Button("Add host") { creating = true }
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accentOnDark)
                    .padding(.horizontal, 18)
                    .frame(height: Theme.hitTarget)
                    .glassPill(tone: .dark)

                Button("Import config") { importing = true }
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accentOnDark)
                    .padding(.horizontal, 18)
                    .frame(height: Theme.hitTarget)
                    .glassPill(tone: .dark)
            }
            .padding(.top, 4)
        }
    }
}
