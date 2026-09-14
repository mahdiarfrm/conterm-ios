import SwiftUI

/// The shells you have running, as cards in a row; the machines you could
/// start one on when nothing is; and New at the end.
///
/// This is the switcher. A terminal on a phone is a thing you leave and
/// come back to, and coming back should be one tap from wherever you are:
/// the row sits at the top of the home, and drops over a terminal when
/// you want a different one. The same cards in both places, so the eye
/// learns them once.
struct ShellDeck: View {
    enum Mode: Equatable {
        /// The home: every running shell, the Macs, the machines to start,
        /// and New.
        case home
        /// Over a terminal: every running shell, the one you are in
        /// marked, and a new one on the same host.
        case switcher(current: TerminalSession)
    }

    var mode: Mode = .home
    /// The home's zoom namespace, so a pushed screen grows out of its card.
    var zoom: Namespace.ID?
    /// The switcher's answers. The home routes itself.
    var onPick: ((TerminalSession) -> Void)?
    var onNew: (() -> Void)?

    @Environment(HomeRouter.self) private var router: HomeRouter?
    private var sessions: SessionStore { SessionStore.shared }

    static let cardWidth: CGFloat = 150
    static let cardHeight: CGFloat = 118
    static let corner: CGFloat = 22

    private var live: [TerminalSession] { sessions.live }
    private var macs: [Host] { Handoff.macs }
    private var linuxCanStart: Bool {
        LinuxMachine.imageURL != nil && !LinuxMachine.shared.isUp
    }

    /// The hosts to offer when nothing runs: the ones you were on last,
    /// then the rest by name, the Macs left out because they have a card
    /// of their own.
    private var starters: [Host] {
        let hosts = HostStore.shared.hosts.filter { $0.distro != Distro.macos.rawValue }
        let used = hosts.filter { $0.lastConnectedAt != nil }
            .sorted { $0.lastConnectedAt! > $1.lastConnectedAt! }
        let rest = hosts.filter { $0.lastConnectedAt == nil }
            .sorted { $0.alias.lowercased() < $1.alias.lowercased() }
        return Array((used + rest).prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PanelLabel(label, symbol: "apple.terminal.fill")
                Spacer(minLength: 0)
                if !live.isEmpty {
                    Text("\(live.count)")
                        .font(Theme.font(Theme.ui(11), .bold))
                        .badgePill(tint: Theme.Status.ready)
                        .rollingDigits(on: live.count)
                }
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    cards
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
            // The cards run to the screen's edge while the label keeps the
            // column's margin.
            .padding(.horizontal, -16)
            .animation(Theme.Spring.morph, value: live.map(\.id))
        }
    }

    private var label: String {
        switch mode {
        case .home: return live.isEmpty ? "Shells" : "Running"
        case .switcher: return "Switch to"
        }
    }

    @ViewBuilder
    private var cards: some View {
        switch mode {
        case .home:
            ForEach(Array(live.enumerated()), id: \.element.id) { index, session in
                SessionCard(session: session, siblings: sessions.liveCount(for: session.host),
                            current: false, zoom: zoom) {
                    router?.resume(session, from: HomeRouter.zoomID(session))
                }
                .popIn(index, base: 0.1)
            }
            ForEach(Array(macs.enumerated()), id: \.element.id) { index, mac in
                MacCard(mac: mac) { router?.showPanes(mac) }
                    .popIn(live.count + index, base: 0.1)
            }
            if linuxCanStart {
                LinuxCard { router?.openLinux(from: HomeRouter.zoomID(LinuxMachine.host)) }
                    .popIn(live.count + macs.count, base: 0.1)
            }
            if live.isEmpty {
                ForEach(Array(starters.enumerated()), id: \.element.id) { index, host in
                    StartCard(host: host, zoom: zoom) {
                        router?.open(host, from: Self.zoomID(host))
                    }
                    .popIn(macs.count + 1 + index, base: 0.1)
                }
            }
            NewCard(title: "New", detail: "a shell anywhere") {
                Haptics.shared.fire(.light)
                router?.route = .connect
            }
        case .switcher(let current):
            ForEach(Array(live.enumerated()), id: \.element.id) { index, session in
                SessionCard(session: session, siblings: sessions.liveCount(for: session.host),
                            current: session === current, zoom: nil) {
                    onPick?(session)
                }
                .popIn(index, base: 0.05)
            }
            if !current.isLocalLinux, let onNew {
                NewCard(title: "New", detail: "another on \(current.host.alias)") {
                    Haptics.shared.fire(.light)
                    onNew()
                }
            }
        }
    }

    /// A start card's zoom id, apart from the host bubbles' further down
    /// the same screen.
    static func zoomID(_ host: Host) -> String { "deck-host-\(host.id)" }
}

// MARK: - Cards

/// The card every deck entry sits on: one size, one corner, a bed.
private extension View {
    func deckTile(_ bed: PanelBed) -> some View {
        padding(13)
            .frame(width: ShellDeck.cardWidth, height: ShellDeck.cardHeight, alignment: .topLeading)
            .panelSurface(bed, cornerRadius: ShellDeck.corner)
            .contentShape(RoundedRectangle(cornerRadius: ShellDeck.corner, style: .continuous))
    }
}

/// A running shell: the gem, the host, what the shell is doing, and how
/// long it has been up, ticking.
private struct SessionCard: View {
    let session: TerminalSession
    var siblings: Int = 1
    /// In the switcher, the shell you are already in.
    var current: Bool
    var zoom: Namespace.ID?
    let action: () -> Void
    @Environment(HomeRouter.self) private var router: HomeRouter?

    var body: some View {
        let card = Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    DistroMark(distro: session.host.distro.flatMap(Distro.init(rawValue:)),
                               size: Theme.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    if current {
                        Text("here")
                            .font(Theme.font(Theme.ui(9), .bold))
                            .badgePill(tint: Theme.textPrimary)
                    } else if siblings > 1 {
                        Text("#\(session.ordinal)")
                            .font(.system(size: Theme.ui(9), weight: .bold, design: .monospaced))
                            .badgePill(tint: Theme.textPrimary)
                    }
                }
                Text(session.host.alias)
                    .font(Theme.font(Theme.ui(15), .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 4)
                Text(subtitle)
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .morph(on: subtitle, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: Theme.ui(9), weight: .bold))
                    Text(session.startedAt, style: .timer)
                        .font(.system(size: Theme.ui(11), weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 52, alignment: .leading)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: Theme.ui(10), weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .deckTile(current ? .glass : .grass)
            .animation(Theme.Spring.morph, value: session.state)
        }
        .buttonStyle(PressablePill(scale: 0.96))
        .disabled(current)
        .contextMenu { menu }

        if let zoom {
            card.matchedTransitionSource(id: HomeRouter.zoomID(session), in: zoom) {
                $0.clipShape(RoundedRectangle(cornerRadius: ShellDeck.corner, style: .continuous))
            }
        } else {
            card
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let router, !current {
            if !session.isLocalLinux {
                Button("Open another shell", systemImage: "plus.rectangle.on.rectangle") {
                    router.openNew(session.host)
                }
                Button("Overview", systemImage: "waveform.path.ecg") {
                    router.showOverview(session.host)
                }
                Button("Files", systemImage: "folder") { router.showFiles(session.host) }
                if session.host.distro != Distro.macos.rawValue, !Handoff.macs.isEmpty {
                    Button("Continue on Mac", systemImage: "macbook.and.iphone") {
                        router.continueOnMac(session.host)
                    }
                }
                Divider()
            }
            Button(session.isLocalLinux ? "Power off" : "Disconnect",
                   systemImage: session.isLocalLinux ? "power" : "bolt.horizontal.circle",
                   role: .destructive) {
                SessionStore.shared.close(session)
                SoundEffects.shared.play(.disconnect)
            }
        }
    }

    private var tint: Color {
        switch session.state {
        case .connecting: return Theme.Status.working
        case .connected: return Theme.Status.ready
        case .failed: return Theme.Status.danger
        case .closed: return Theme.Status.neutral
        }
    }

    private var subtitle: String {
        switch session.state {
        case .connecting: return session.bootPhase ?? "connecting\u{2026}"
        case .connected: return session.title ?? session.host.displaySubtitle
        case .failed(let why): return why
        case .closed(let why): return why ?? "closed"
        }
    }
}

/// A Mac with Conterm on it: what it was doing the last time this phone
/// looked, and the way to its panes.
private struct MacCard: View {
    let mac: Host
    let action: () -> Void

    var body: some View {
        let summary = MacSummary.read(for: mac)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: Theme.ui(12), weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    if let summary, summary.waiting > 0 {
                        Text("\(summary.waiting) waiting")
                            .font(Theme.font(Theme.ui(9), .bold))
                            .badgePill(tint: Theme.Status.attention)
                    }
                }
                Text(mac.alias)
                    .font(Theme.font(Theme.ui(15), .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 4)
                Text(summary.map { "\($0.panes) pane\($0.panes == 1 ? "" : "s") on it" }
                     ?? "Conterm on this Mac")
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .font(.system(size: Theme.ui(9), weight: .bold))
                    Text("Panes")
                        .font(Theme.font(Theme.ui(11), .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: Theme.ui(10), weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .deckTile(.azure)
        }
        .buttonStyle(PressablePill(scale: 0.96))
    }
}

/// Debian on this phone, off: one tap boots it.
private struct LinuxCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    DistroMark(distro: .debian, size: Theme.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                Text("Debian")
                    .font(Theme.font(Theme.ui(15), .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 4)
                Text("Linux on this iPhone")
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: Theme.ui(9), weight: .bold))
                    Text("Boot")
                        .font(Theme.font(Theme.ui(11), .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: Theme.ui(10), weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .deckTile(.violet)
        }
        .buttonStyle(PressablePill(scale: 0.96))
    }
}

/// A saved host with nothing running on it: one tap opens a shell.
private struct StartCard: View {
    let host: Host
    var zoom: Namespace.ID?
    let action: () -> Void
    @Environment(HomeRouter.self) private var router: HomeRouter?

    private var hasSecret: Bool { KeyStore.shared.hasSecret(for: host) }

    var body: some View {
        let card = Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    DistroMark(distro: host.distro.flatMap(Distro.init(rawValue:)), size: Theme.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    if !hasSecret {
                        Text("no key")
                            .font(Theme.font(Theme.ui(9), .bold))
                            .badgePill(tint: Theme.Status.attention)
                    }
                }
                Text(host.alias)
                    .font(Theme.font(Theme.ui(15), .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 4)
                Text(host.displaySubtitle)
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: Theme.ui(9), weight: .bold))
                    Text("Shell")
                        .font(Theme.font(Theme.ui(11), .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: Theme.ui(10), weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .deckTile(.glass)
        }
        .buttonStyle(PressablePill(scale: 0.96))
        .contextMenu {
            if let router {
                Button("Overview", systemImage: "waveform.path.ecg") { router.showOverview(host) }
                Button("Files", systemImage: "folder") { router.showFiles(host) }
                Divider()
                Button("Edit host", systemImage: "pencil") { router.route = .editHost(host) }
            }
        }

        if let zoom {
            card.matchedTransitionSource(id: ShellDeck.zoomID(host), in: zoom) {
                $0.clipShape(RoundedRectangle(cornerRadius: ShellDeck.corner, style: .continuous))
            }
        } else {
            card
        }
    }
}

/// The last card: a shell somewhere new.
private struct NewCard: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: Theme.ui(18), weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: Theme.ui(34), height: Theme.ui(34))
                    .glassPill()
                Spacer(minLength: 0)
                Text(title)
                    .font(Theme.font(Theme.ui(15), .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .deckTile(.glass)
        }
        .buttonStyle(PressablePill(scale: 0.96))
    }
}

// MARK: - What a Mac was doing

/// The last picture this phone had of a Mac, kept so the home can say
/// "5 panes, 1 waiting" without opening a connection to find out.
struct MacSummary: Codable {
    var panes: Int
    var waiting: Int
    var at: Date

    private static func key(_ host: Host) -> String { "conterm.mac.\(host.id.uuidString)" }

    static func store(_ summary: MacSummary, for host: Host) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: key(host))
    }

    static func read(for host: Host) -> MacSummary? {
        guard let data = UserDefaults.standard.data(forKey: key(host)) else { return nil }
        return try? JSONDecoder().decode(MacSummary.self, from: data)
    }
}
