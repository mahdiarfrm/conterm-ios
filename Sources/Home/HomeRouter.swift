import SwiftUI
import Observation

/// Where the home screen can go, and how it gets there.
///
/// One object owns every push and every sheet the home can make, so a tap
/// on a panel, a row in the hosts tab and a pick in the palette all land in
/// the same place and can't race each other. Views reach it through the
/// environment.
@MainActor
@Observable
final class HomeRouter {
    let app: Ghostty.App

    /// What is pushed.
    var session: TerminalSession?
    var overview: Host?
    var agentsFor: Host?
    var contermOn: Host?
    /// A host's files.
    var files: Host?
    /// A host waiting for the user to say which Mac to continue it on.
    var handoff: Host?
    /// A panel opened into its detail.
    var detail: HomeDetail?
    /// The `matchedTransitionSource` id of whatever was tapped, so the
    /// pushed screen can grow out of it.
    var zoomSource: String?

    /// What is presented.
    var route: Route?
    var importing = false
    var notice: String?

    /// A probe handed in for a host, by the harness. Nil everywhere else.
    var injectedProbe: (host: Host, probe: HostProbeModel)?
    /// The harness asking the home to scroll: to the foot on an odd count,
    /// back to the top on an even one. Nothing else touches it.
    var scrollRequest = 0
    /// The harness asking the terminal to drop its switcher; each count
    /// toggles it.
    var switcherRequest = 0

    /// Everything the home can put on top of itself.
    enum Route: Identifiable, Hashable {
        case keys, snippets, settings, newHost, quickConnect, connect, panels
        case editHost(Host)

        var id: String {
            switch self {
            case .keys: return "keys"
            case .snippets: return "snippets"
            case .settings: return "settings"
            case .newHost: return "newHost"
            case .quickConnect: return "quickConnect"
            case .connect: return "connect"
            case .panels: return "panels"
            case .editHost(let host): return "edit-\(host.id)"
            }
        }
    }

    init(app: Ghostty.App) {
        self.app = app
    }

    private var store: HostStore { HostStore.shared }
    private var sessions: SessionStore { SessionStore.shared }

    /// Take me to that machine. Resumes the shell if it already has one;
    /// opening a second connection to a box you are already on is never
    /// what the tap meant.
    func open(_ host: Host, from source: String? = nil) {
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            // No secret stored — the editor, rather than a terminal that
            // can only fail.
            SoundEffects.shared.play(.error)
            Haptics.shared.fire(.warning)
            route = .editHost(host)
            return
        }
        SoundEffects.shared.tap(.connect, haptic: .medium)
        let s = sessions.session(for: host, app: app, credentials: credentials)
        store.noteConnected(host)
        zoomSource = source
        session = s
    }

    /// Always a fresh shell, even if this host already has one.
    func openNew(_ host: Host, from source: String? = nil) {
        guard let credentials = KeyStore.shared.credentials(for: host) else {
            SoundEffects.shared.play(.error)
            route = .editHost(host)
            return
        }
        SoundEffects.shared.tap(.connect, haptic: .medium)
        zoomSource = source
        session = sessions.newSession(for: host, app: app, credentials: credentials)
        store.noteConnected(host)
    }

    /// The Linux machine on this phone: boot it, or back to its console.
    func openLinux(from source: String? = nil) {
        SoundEffects.shared.tap(.connect, haptic: .medium)
        zoomSource = source
        session = sessions.localLinux(app: app)
    }

    /// Back to a shell that is already running.
    func resume(_ live: TerminalSession, from source: String? = nil) {
        Haptics.shared.fire(.light)
        zoomSource = source
        session = live
    }

    func showOverview(_ host: Host, from source: String? = nil) {
        Haptics.shared.fire(.light)
        zoomSource = source
        overview = host
    }

    func showFiles(_ host: Host) {
        Haptics.shared.fire(.light)
        files = host
    }

    /// Conterm on a Mac: its windows, tabs and panes, each one a tap from
    /// being picked up here.
    func showPanes(_ mac: Host) {
        Haptics.shared.fire(.light)
        contermOn = mac
    }

    /// From one running shell to another, in place. The terminal screen
    /// stays; only the session in it changes.
    func switchTo(_ live: TerminalSession) {
        Haptics.shared.fire(.light)
        zoomSource = nil
        session = live
    }

    /// Put a shell on this host into a new tab of Conterm on a Mac. One
    /// Mac saved: straight there. Several: ask which. None: say so.
    func continueOnMac(_ target: Host) {
        let macs = Handoff.macs.filter { $0.id != target.id }
        switch macs.count {
        case 0:
            Haptics.shared.fire(.warning)
            notice = "Save the Mac as a host first, so Conterm knows which machine to hand this to."
        case 1:
            runHandoff(target, via: macs[0])
        default:
            handoff = target
        }
    }

    func runHandoff(_ target: Host, via mac: Host) {
        SoundEffects.shared.tap(.connect, haptic: .medium)
        handoff = nil
        Task { @MainActor in
            do {
                try await Handoff.continueOnMac(target, via: mac)
                Haptics.shared.fire(.success)
                notice = "Opened \(target.alias) in a new tab on \(mac.alias)."
            } catch {
                Haptics.shared.fire(.warning)
                notice = error.localizedDescription
            }
        }
    }

    /// Present something after a sheet closes. Dismissing and navigating in
    /// one tick lets one cancel the other, so the navigation waits a turn.
    func afterDismiss(_ work: @escaping @MainActor () -> Void) {
        route = nil
        Task { @MainActor in work() }
    }

    /// Open a panel into its detail; it grows out of the panel.
    func expand(_ detail: HomeDetail) {
        Haptics.shared.fire(.light)
        zoomSource = detail.zoomID
        self.detail = detail
    }

    /// The zoom id for a session, shared by every row that can open it.
    static func zoomID(_ session: TerminalSession) -> String {
        "session-\(ObjectIdentifier(session).hashValue)"
    }
    static func zoomID(_ host: Host) -> String { "host-\(host.id)" }
    static func overviewZoomID(_ host: Host) -> String { "overview-\(host.id)" }
}

/// The panels on the home that open into a detail screen.
enum HomeDetail: String, Hashable, Identifiable {
    case activity, fleet, world, heartbeat
    var id: String { rawValue }
    var zoomID: String { "panel-\(rawValue)" }
}

/// The tabs in the bar at the foot of the home screen: the general things.
/// Home is what is running and the dashboard; Machines is everything a
/// shell can be opened on, this phone and the Macs included; keys and
/// snippets live inside Machines and Settings.
enum HomeTab: String, CaseIterable, Identifiable {
    case home, machines, settings, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .machines: return "Machines"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.stack.3d.up.fill"
        case .machines: return "point.3.filled.connected.trianglepath.dotted"
        case .settings: return "gearshape.fill"
        case .search: return "magnifyingglass"
        }
    }

    /// `CONTERM_TAB=<tab>` for the harness. The older names still land
    /// somewhere sensible: `hosts` is Machines, and `companion` is the
    /// home, from which the Mac's panes are pushed.
    static func harness(_ raw: String?) -> HomeTab {
        switch raw {
        case "hosts", "machines": return .machines
        case "settings": return .settings
        case "search": return .search
        default: return .home
        }
    }
}

/// The panels the home screen can show. Each is one card with one picture.
/// What is running is not a panel: the shell deck sits above them all and
/// cannot be switched off.
enum HomePanelKind: String, CaseIterable, Identifiable {
    case activity, heartbeat, world, fleet, wantsYou, uptime, recent, nearby

    var id: String { rawValue }

    static var defaultOrder: [String] { allCases.map(\.rawValue) }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .heartbeat: return "Heartbeat"
        case .world: return "World"
        case .fleet: return "Fleet"
        case .wantsYou: return "Wants you"
        case .uptime: return "Uptime"
        case .recent: return "Recent"
        case .nearby: return "Nearby"
        }
    }

    var symbol: String {
        switch self {
        case .activity: return "waveform.path.ecg"
        case .heartbeat: return "heart.fill"
        case .world: return "globe.europe.africa.fill"
        case .fleet: return "server.rack"
        case .wantsYou: return "sparkles"
        case .uptime: return "trophy.fill"
        case .recent: return "clock.arrow.circlepath"
        case .nearby: return "laptopcomputer"
        }
    }

    var summary: String {
        switch self {
        case .activity: return "Terminal traffic over the last two minutes."
        case .heartbeat: return "Every host you have looked at lately, its CPU beating in its own lane."
        case .world: return "Your hosts on the map, the night side dimmed, their local times."
        case .fleet: return "How many hosts, groups and keys, and hosts by group."
        case .wantsYou: return "Agents waiting on your Mac, hosts that stopped answering, lost shells."
        case .uptime: return "The three machines that have been up longest, on a podium."
        case .recent: return "The hosts you were on last, one tap away."
        case .nearby: return "Macs on this network running Conterm."
        }
    }
}
