import SwiftUI
import os

/// The home screen.
///
/// Not a list of hosts. The shells you have running sit at the top as a
/// row of cards, with the machines to start one on when nothing runs;
/// under them the home is a column of panels — the traffic, the fleet,
/// the hosts you were on last, the Macs nearby — and the system's glass
/// tab bar at the foot carries the general things: home, the machines,
/// the settings. Keys and snippets live inside the last two. A shell is
/// one tap from the deck, from the bar's plus or from a panel; a host you
/// have never opened is one search away.
///
/// The navigation bar stays. Hiding it here and showing it on every pushed
/// screen left the pushed screen's buttons behind on the way back; keeping
/// it, with its own two buttons and no background, gives the system
/// something to morph between instead.
struct HomeView: View {
    let app: Ghostty.App
    /// The harness's host and probe, for the tour. Nil in the app.
    var tour: OverviewHarness.Rig?

    @State private var router: HomeRouter
    /// `CONTERM_TAB=machines` starts on that tab, for the harness.
    @State private var tab: HomeTab =
        HomeTab.harness(ProcessInfo.processInfo.environment["CONTERM_TAB"])
    /// The tab that was showing before New was tapped, so New can act
    /// without ever becoming a place.
    @State private var lastTab: HomeTab = .home
    @State private var store = HostStore.shared
    @State private var groups = HostGroupStore()
    @State private var nearby = NearbyMacs()
    @State private var traffic = TrafficMeter()
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var zoom
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var sessions: SessionStore { SessionStore.shared }

    init(app: Ghostty.App, tour: OverviewHarness.Rig? = nil) {
        self.app = app
        self.tour = tour
        _router = State(initialValue: HomeRouter(app: app))
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                // On an iPad the home is a sidebar and the session lives
                // beside it, which is the whole reason to use a tablet for
                // this: you can watch a build and pick the next host without
                // one replacing the other.
                NavigationSplitView {
                    shell
                } detail: {
                    NavigationStack { destinations(detailPlaceholder) }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack { destinations(shell) }
            }
        }
        .environment(router)
        .tint(Theme.accentOnDark)
        // Sessions that died keep their terminal readable while it is open;
        // once you are back here they are just clutter.
        .onAppear { sessions.pruneDead() }
        // Browsing is a multicast listener; it runs while this screen is up
        // and not a moment longer. The traffic meter is a sum of integers
        // every two seconds and keeps its history across a trip into a
        // terminal, which is when the traffic happens.
        .onAppear { nearby.start(); traffic.start() }
        .onDisappear { nearby.stop() }
        // Keyed on the rig: it is built by the root's own task, which can
        // land after this screen's first appearance, and a tour that only
        // checked once at that moment ran or did not by luck.
        .task(id: tour?.host.id) { await runTour() }
        // `CONTERM_TAB=companion`: straight into the first Mac's panes, the
        // way the old tab opened.
        .task {
            guard ProcessInfo.processInfo.environment["CONTERM_TAB"] == "companion" else { return }
            try? await Task.sleep(for: .seconds(1))
            if let mac = Handoff.macs.first { router.showPanes(mac) }
        }
    }

    // MARK: - Shell

    private var shell: some View {
        // The system's own tab bar: glass, the liquid response under a
        // finger, shrinking away as you scroll. The ground is painted inside
        // every tab, because the tab view's container is opaque. New is a
        // tab that acts rather than a place: selecting it opens the shell
        // picker and hands the selection straight back.
        TabView(selection: $tab) {
            Tab(HomeTab.home.title, systemImage: HomeTab.home.symbol, value: HomeTab.home) {
                tabContent(.home)
            }
            Tab(HomeTab.machines.title, systemImage: HomeTab.machines.symbol, value: HomeTab.machines) {
                tabContent(.machines)
            }
            Tab(HomeTab.settings.title, systemImage: HomeTab.settings.symbol, value: HomeTab.settings) {
                tabContent(.settings)
            }
            // The search role is the one the system draws apart from the
            // others, in its own circle at the trailing end: the palette.
            Tab(HomeTab.search.title, systemImage: HomeTab.search.symbol, value: HomeTab.search,
                role: .search) {
                searchTab
            }
        }
        .modifier(TabBarFeel())
        .onChange(of: tab) { old, new in
            if new == .search {
                SoundEffects.shared.play(.paletteOpen)
                if old != .search { lastTab = old }
            } else {
                lastTab = new
                query = ""
                searchFocused = false
            }
        }
        .brandGround()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // The wordmark, large, at the left, on the ground itself: the
            // bar's glass circle is for buttons, and this is not one.
            if #available(iOS 26, *) {
                ToolbarItem(placement: .topBarLeading) {
                    ContermWordmark(height: Theme.ui(36))
                        .foregroundStyle(Theme.accentOnDark)
                        .frame(width: Theme.ui(160), height: Theme.ui(44), alignment: .leading)
                        .padding(.leading, 6)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    ContermWordmark(height: Theme.ui(36))
                        .foregroundStyle(Theme.accentOnDark)
                        .frame(width: Theme.ui(160), height: Theme.ui(44), alignment: .leading)
                        .padding(.leading, 6)
                }
            }
            // A shell, now: the one button in the bar, in the system's own
            // glass circle where it draws one.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.shared.fire(.light)
                    router.route = .connect
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Theme.ui(16), weight: .semibold))
                        .foregroundStyle(Theme.accentOnDark)
                }
                .accessibilityLabel("Open a shell")
            }
        }
        // One sheet, not six. SwiftUI attaches each `.sheet` modifier to
        // the same view, and only one of them reliably wins — a single
        // presentation driven by a route can't race itself.
        .sheet(item: $router.route) { route in
            switch route {
            case .keys:
                KeyLibraryView()
            case .snippets:
                SnippetsView(host: nil) { snippet in run(snippet) }
            case .settings:
                SettingsView()
            case .newHost:
                HostEditorView(store: store, groups: groups)
            case .editHost(let host):
                HostEditorView(store: store, groups: groups, existing: host)
            case .quickConnect:
                QuickConnectView(app: app, store: store) {
                    SessionStore.shared.adopt($0)
                    router.route = nil
                    router.zoomSource = nil
                    router.session = $0
                }
            case .connect:
                ConnectSheet(store: store, groups: groups)
            case .panels:
                PanelPicker()
            }
        }
        .fileImporter(isPresented: $router.importing,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { importConfig($0) }
        .alert("Conterm", isPresented: Binding(
            get: { router.notice != nil },
            set: { if !$0 { router.notice = nil } })) {
            Button("OK") { router.notice = nil }
        } message: {
            Text(router.notice ?? "")
        }
        .confirmationDialog("Continue on which Mac?",
                            isPresented: Binding(get: { router.handoff != nil },
                                                 set: { if !$0 { router.handoff = nil } }),
                            titleVisibility: .visible) {
            if let target = router.handoff {
                ForEach(Handoff.macs.filter { $0.id != target.id }) { mac in
                    Button(mac.alias) { router.runHandoff(target, via: mac) }
                }
            }
        }
    }

    /// A tab's content, on the ground.
    @ViewBuilder
    private func tabContent(_ which: HomeTab) -> some View {
        Group {
            switch which {
            case .home:
                homeTab
            case .machines:
                HostListView(store: store, groups: groups, nearby: nearby, zoom: zoom)
                    .padding(.top, 4)
            case .settings:
                SettingsView(embedded: true,
                             onKeys: { router.route = .keys },
                             onSnippets: { router.route = .snippets })
                    .padding(.top, 4)
            case .search:
                searchTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandGround()
    }

    /// The home tab: the column of panels.
    private var homeTab: some View {
        HomePanelsView(store: store, groups: groups, nearby: nearby,
                       traffic: traffic, zoom: zoom)
    }

    /// The search tab: the palette's bar and its results, the bar focused
    /// the moment the tab opens. Picking a result or closing the bar goes
    /// back to the tab that was showing.
    private var searchTab: some View {
        VStack(spacing: 10) {
            PaletteBar(query: $query, focused: $searchFocused, open: true,
                       onSubmit: { if let first = rows.first { pick(first) } },
                       onClose: closeSearch)
            PaletteResults(rows: rows, maxHeight: 10_000) { pick($0) }
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .contermReadableColumn()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .brandGround()
        .onAppear {
            // A beat, so the tab is on screen before the keyboard asks for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
        }
    }

    /// A snippet from the tab is typed into the shell you are on. Without
    /// one there is nowhere for it to go, and the notice says so rather
    /// than the tap doing nothing.
    private func run(_ snippet: Snippet) {
        guard let live = sessions.live.first else {
            router.notice = "Open a shell first. A snippet is typed into the shell you are on."
            return
        }
        live.type(snippet.command)
        if snippet.submits { live.press(.keyboardReturnOrEnter) }
        router.resume(live)
    }

    /// What the detail column shows before you have picked anything. A blank
    /// half-screen reads as a bug; this reads as an invitation.
    private var detailPlaceholder: some View {
        VStack(spacing: 12) {
            ContermWordmark(height: Theme.ui(34))
                .foregroundStyle(Theme.textSecondary.opacity(0.55))
            Text(store.hosts.isEmpty ? "Add a host to get started"
                                     : "Pick a host to open a shell")
                .font(Theme.font(Theme.ui(14), .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandGround()
    }

    // MARK: - Destinations

    /// Everything this screen can push, attached to whichever column owns
    /// navigation — the stack itself on a phone, the detail column on a
    /// tablet. Each grows out of whatever was tapped.
    @ViewBuilder
    private func destinations<Content: View>(_ content: Content) -> some View {
        content
            .navigationDestination(item: $router.session) { live in
                TerminalScreen(session: live,
                               onHandoff: { router.continueOnMac($0) },
                               onSwitch: { router.switchTo($0) }) { host in
                    // Pop, then push — on separate runloop turns. Doing both
                    // in one tick makes the pop cancel the push.
                    router.session = nil
                    Task { @MainActor in router.openNew(host) }
                }
                // A switch changes the item under the same destination; the
                // id makes it a new screen, so the surface view is asked for
                // again rather than the old session's staying on screen.
                .id(live)
                .navigationTransition(.zoom(sourceID: router.zoomSource ?? HomeRouter.zoomID(live),
                                            in: zoom))
            }
            .navigationDestination(item: $router.agentsFor) { AgentCenterView(host: $0) }
            .navigationDestination(item: $router.contermOn) { host in
                ContermRemoteView(host: host, onOpenHere: { router.open($0) })
            }
            .navigationDestination(item: $router.files) { FileBrowserView(host: $0) }
            .navigationDestination(for: RemoteDirectory.self) { directory in
                FileBrowserView(host: directory.host, path: directory.path)
            }
            .navigationDestination(item: $router.overview) { host in
                HostOverviewView(host: host,
                                 onOpenShell: { target in
                                     router.overview = nil
                                     Task { @MainActor in router.open(target) }
                                 },
                                 onFiles: { router.showFiles($0) },
                                 onHandoff: { router.continueOnMac($0) },
                                 injected: router.injectedProbe?.host.id == host.id
                                     ? router.injectedProbe?.probe : nil)
                .navigationTransition(.zoom(sourceID: router.zoomSource ?? HomeRouter.overviewZoomID(host),
                                            in: zoom))
            }
            .navigationDestination(item: $router.detail) { detail in
                Group {
                    switch detail {
                    case .activity:
                        ActivityDetail(traffic: traffic)
                    case .fleet:
                        FleetDetail(store: store, groups: groups, nearby: nearby)
                    case .world:
                        WorldDetail(store: store)
                    case .heartbeat:
                        HeartbeatDetail(store: store)
                    }
                }
                .navigationTransition(.zoom(sourceID: detail.zoomID, in: zoom))
            }
    }

    // MARK: - Search

    private var rows: [CommandPalette.Row] {
        CommandPalette.rows(for: query, hosts: store.hosts, actions: .init(
            newHost: { closeSearch(); router.route = .newHost },
            quickConnect: { closeSearch(); router.route = .quickConnect },
            importConfig: { closeSearch(); router.importing = true },
            keys: { closeSearch(); router.route = .keys },
            settings: { closeSearch(); withAnimation(Theme.Spring.snappy) { tab = .settings } },
            linux: { closeSearch(); router.openLinux() },
            files: { closeSearch(); router.showFiles($0) },
            panes: { closeSearch(); router.showPanes($0) }))
    }

    private func pick(_ row: CommandPalette.Row) {
        let done = runPaletteRow(row,
                                 onConnect: { host in
                                     closeSearch()
                                     router.open(host)
                                 },
                                 onOverview: { host in
                                     closeSearch()
                                     router.showOverview(host)
                                 })
        if done { closeSearch() }
    }

    /// Back to the tab that was showing.
    private func closeSearch() {
        SoundEffects.shared.play(.paletteClose)
        searchFocused = false
        query = ""
        withAnimation(Theme.Spring.morph) { tab = lastTab == .search ? .home : lastTab }
    }

    // MARK: - Import

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
        router.notice = message
    }

    // MARK: - Tour

    /// `CONTERM_TOUR=1`: walk the navigation by itself — home, into the
    /// overview, back, into a shell, back, a panel's detail, the tabs, a
    /// search, a change of ground — so the transitions can be recorded
    /// without a finger on the simulator.
    private func runTour() async {
        guard ProcessInfo.processInfo.environment["CONTERM_TOUR"] != nil, let tour else { return }
        let log = Logger(subsystem: "dev.conterm.ios", category: "tour")
        log.notice("tour: home appeared")
        if !store.hosts.contains(where: { $0.id == tour.host.id }) {
            store.add(tour.host)
            store.noteConnected(tour.host)
        }
        router.injectedProbe = (tour.host, tour.probe)
        try? await Task.sleep(for: .seconds(4))
        log.notice("tour: push overview")
        router.showOverview(tour.host, from: HomeRouter.zoomID(tour.host))
        try? await Task.sleep(for: .seconds(9))
        log.notice("tour: pop overview")
        router.overview = nil
        try? await Task.sleep(for: .seconds(3))
        log.notice("tour: push shell")
        let live = SessionStore.shared.newSession(for: tour.host, app: app,
                                                   credentials: tour.credentials)
        router.zoomSource = HomeRouter.zoomID(tour.host)
        router.session = live
        try? await Task.sleep(for: .seconds(6))
        // A second shell on the same host, opened behind the first, so the
        // switcher has somewhere to go; then the switch itself.
        let second = SessionStore.shared.newSession(for: tour.host, app: app,
                                                     credentials: tour.credentials)
        try? await Task.sleep(for: .seconds(2))
        log.notice("tour: switcher")
        router.switcherRequest += 1
        try? await Task.sleep(for: .seconds(3))
        log.notice("tour: switch")
        router.switchTo(second)
        try? await Task.sleep(for: .seconds(4))
        log.notice("tour: pop shell")
        router.session = nil
        try? await Task.sleep(for: .seconds(3))
        log.notice("tour: scroll")
        router.scrollRequest += 1
        try? await Task.sleep(for: .seconds(3))
        router.scrollRequest += 1
        try? await Task.sleep(for: .seconds(2))
        log.notice("tour: activity detail")
        router.expand(.activity)
        try? await Task.sleep(for: .seconds(5))
        log.notice("tour: pop detail")
        router.detail = nil
        try? await Task.sleep(for: .seconds(3))
        log.notice("tour: files")
        FileTransports.inject(FakeFileTransport.sample(), for: tour.host)
        router.showFiles(tour.host)
        try? await Task.sleep(for: .seconds(8))
        log.notice("tour: pop files")
        router.files = nil
        try? await Task.sleep(for: .seconds(3))
        log.notice("tour: machines tab")
        withAnimation(Theme.Spring.snappy) { tab = .machines }
        try? await Task.sleep(for: .seconds(3))
        log.notice("tour: settings tab")
        withAnimation(Theme.Spring.snappy) { tab = .settings }
        try? await Task.sleep(for: .seconds(3))
        log.notice("tour: search")
        withAnimation(Theme.Spring.snappy) { tab = .search }
        try? await Task.sleep(for: .seconds(2))
        query = "we"
        try? await Task.sleep(for: .seconds(4))
        closeSearch()
        try? await Task.sleep(for: .seconds(2))
        log.notice("tour: ground indigo")
        withAnimation(Theme.Spring.morph) { Preferences.shared.ground = GroundPalette.indigo.id }
        try? await Task.sleep(for: .seconds(4))
        log.notice("tour: ground crimson")
        withAnimation(Theme.Spring.morph) { Preferences.shared.ground = GroundPalette.crimson.id }
        try? await Task.sleep(for: .seconds(2))
        log.notice("tour: done")
    }
}

/// The tab bar's behaviour where the OS has the glass one: it stays, so it
/// is always where the thumb expects it.
private struct TabBarFeel: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

/// Bytes through every open shell, sampled every two seconds. The home's
/// activity panel draws it. A sum of integers on a timer, kept while the
/// app is up; the history is the point.
@MainActor
@Observable
final class TrafficMeter {
    struct Sample: Equatable {
        let at: Date
        let inPerSec: Double
        let outPerSec: Double
        var total: Double { inPerSec + outPerSec }
    }

    static let interval: Duration = .seconds(2)
    static let capacity = 60

    private(set) var samples: [Sample] = []
    private var last: (bytesIn: Int, bytesOut: Int, at: Date)?
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    var now: Double { samples.last?.total ?? 0 }
    var peak: Double { samples.map(\.total).max() ?? 0 }
    var average: Double {
        samples.isEmpty ? 0 : samples.map(\.total).reduce(0, +) / Double(samples.count)
    }
    /// Bytes over the whole window, in and out.
    var windowIn: Double { samples.reduce(0) { $0 + $1.inPerSec * 2 } }
    var windowOut: Double { samples.reduce(0) { $0 + $1.outPerSec * 2 } }

    private func tick() {
        let sessions = SessionStore.shared.sessions
        let bytesIn = sessions.reduce(0) { $0 + $1.bytesIn }
        let bytesOut = sessions.reduce(0) { $0 + $1.bytesOut }
        let at = Date()
        defer { last = (bytesIn, bytesOut, at) }
        guard let last else { return }
        let dt = max(at.timeIntervalSince(last.at), 0.5)
        // A closed session takes its bytes with it; that is not negative
        // traffic.
        let sample = Sample(at: at,
                            inPerSec: max(Double(bytesIn - last.bytesIn), 0) / dt,
                            outPerSec: max(Double(bytesOut - last.bytesOut), 0) / dt)
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }
}
