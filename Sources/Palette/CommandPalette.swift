import SwiftUI

/// One search over everything.
///
/// On a Mac this is a shortcut. On a phone it is the way to get anywhere,
/// so it lives at the top of the home screen rather than behind a key: a
/// thick input bar that is always there, and a results bubble that opens
/// beneath it the moment the bar is touched. Two detached bubbles with a
/// gap between them, exactly the shape the Mac's palette takes.
///
/// Two things carry over from Conterm and matter more than they look:
///
/// **Everything becomes a `Row`.** Hosts, briefings, actions and the
/// calculator are all synthesised into one type, so ranking, rendering and
/// selection need no special cases per source.
///
/// **Two-tier ranking.** Up to three top picks by frecency from any source,
/// then the rest in source order. Scores are computed once up front — doing
/// it inside the sort comparator calls `score()` O(n log n) times per
/// keystroke, which is exactly the sort of thing that makes a search field
/// feel laggy.
enum CommandPalette {
    struct Row: Identifiable {
        enum Kind {
            case host(Host)
            case overview(Host)
            case action(() -> Void)
            case calculation(String)
        }
        let id: String
        let title: String
        var subtitle: String?
        let symbol: String
        var tint: Color?
        let kind: Kind
        /// Frecency namespace key, or nil for rows that shouldn't be learned
        /// (a calculation is never "used again").
        var frecencyKey: String?
    }

    /// What the palette can do besides open a host.
    struct Actions {
        var newHost: () -> Void
        var quickConnect: () -> Void
        var importConfig: () -> Void
        var keys: () -> Void
        var settings: () -> Void
        /// Debian on this phone: boot it, or back to its console.
        var linux: () -> Void
        /// A host's files.
        var files: (Host) -> Void
        /// A Mac's panes.
        var panes: (Host) -> Void
    }

    @MainActor
    static func rows(for query: String, hosts: [Host], actions: Actions) -> [Row] {
        var out: [Row] = []

        // A live calculation always leads — you typed a sum, you want the
        // answer, not a fuzzy host match on the digits.
        if let answer = QuickMath.answer(query) {
            out.append(Row(id: "calc", title: answer.display, subtitle: "Tap to copy",
                           symbol: "equal.square", tint: Theme.sshAccent,
                           kind: .calculation(answer.insert)))
        }

        let q = query.trimmed.lowercased()

        for host in hosts {
            let haystack = "\(host.alias) \(host.hostname) \(host.username)".lowercased()
            guard q.isEmpty || haystack.contains(q) else { continue }
            out.append(Row(id: "host:\(host.id)", title: host.alias,
                           subtitle: host.displaySubtitle,
                           symbol: "terminal",
                           kind: .host(host),
                           frecencyKey: "host.\(host.id)"))
            // Only offer the briefing and the files once a query narrows
            // things, or the list triples in length for no reason.
            if !q.isEmpty {
                out.append(Row(id: "info:\(host.id)", title: "How is \(host.alias)?",
                               subtitle: "Host overview",
                               symbol: "waveform.path.ecg",
                               kind: .overview(host),
                               frecencyKey: "overview.\(host.id)"))
                out.append(Row(id: "files:\(host.id)", title: "Files on \(host.alias)",
                               subtitle: "Browse, edit, upload",
                               symbol: "folder",
                               kind: .action { actions.files(host) },
                               frecencyKey: "files.\(host.id)"))
            }
            // A Mac's panes are worth a row of their own: the shells you
            // left on it, one tap from being picked up here.
            if host.distro == Distro.macos.rawValue {
                out.append(Row(id: "panes:\(host.id)", title: "Panes on \(host.alias)",
                               subtitle: "Conterm on this Mac",
                               symbol: "macwindow",
                               kind: .action { actions.panes(host) },
                               frecencyKey: "panes.\(host.id)"))
            }
        }

        // Debian on this phone, found under its own name or under "linux".
        if LinuxMachine.imageURL != nil,
           q.isEmpty || "debian linux this iphone".contains(q) {
            let state: String
            switch LinuxMachine.shared.state {
            case .off: state = "off"
            case .starting: state = "booting"
            case .running: state = "running"
            case .stopped: state = "stopped"
            }
            out.append(Row(id: "linux", title: "Debian",
                           subtitle: "Linux on this iPhone \u{00b7} \(state)",
                           symbol: "cpu",
                           kind: .action(actions.linux),
                           frecencyKey: "linux"))
        }

        let list: [(String, String, String, () -> Void)] = [
            ("Quick Connect", "user@host, nothing saved", "bolt.horizontal.fill", actions.quickConnect),
            ("New Host", "Save a host you use often", "plus.circle", actions.newHost),
            ("Import ssh config", "Bring across a fleet of hosts", "square.and.arrow.down", actions.importConfig),
            ("Keys", "Import id_rsa or id_ed25519", "key.fill", actions.keys),
            ("Settings", "Colour, terminal, feel", "gearshape", actions.settings),
        ]
        for (title, subtitle, symbol, run) in list {
            guard q.isEmpty || title.lowercased().contains(q) else { continue }
            out.append(Row(id: "action:\(title)", title: title, subtitle: subtitle,
                           symbol: symbol, kind: .action(run),
                           frecencyKey: "action.\(title)"))
        }

        return rank(out)
    }

    /// Up to three frecency picks first, the rest in source order.
    @MainActor
    private static func rank(_ rows: [Row]) -> [Row] {
        // Scored once, here — never inside a comparator.
        let scored: [(Row, Double)] = rows.map { row in
            (row, row.frecencyKey.map { FrecencyStore.shared.score($0) } ?? 0)
        }
        let top = scored.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map(\.0)
        let topIDs = Set(top.map(\.id))
        return top + rows.filter { !topIDs.contains($0.id) }
    }
}

/// The input bar: a magnifier, the field, and a way out. Always on screen
/// at the top of the home; the results open under it when it has focus.
struct PaletteBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var placeholder = "Search hosts, actions, or a sum"
    var open: Bool
    var onSubmit: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.ui(15), weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: $query)
                .font(Theme.font(Theme.ui(16), .medium))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accentOnDark)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused(focused)
                .submitLabel(.go)
                .onSubmit(onSubmit)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.ui(15)))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(PressablePill(scale: 0.85))
                .transition(.morph)
            }
            if open {
                Button(action: onClose) {
                    Text("esc")
                        .font(Theme.font(Theme.ui(10), .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.stroke))
                }
                .buttonStyle(PressablePill(scale: 0.85))
                .transition(.morph)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Theme.ui(56))
        .paletteBubble(cornerRadius: 27, darken: 0.14)
        .animation(Theme.Spring.crisp, value: query.isEmpty)
        .animation(open ? Theme.Spring.crisp : Theme.Spring.morph, value: open)
    }
}

/// The results bubble. Rows are touch targets; the one under the finger
/// lights the way the Mac's focused row does.
struct PaletteResults: View {
    let rows: [CommandPalette.Row]
    /// The most the bubble may take; it hugs its rows below that, the way
    /// the Mac's does, rather than hanging to the foot of the screen for
    /// two results.
    var maxHeight: CGFloat = 480
    let onPick: (CommandPalette.Row) -> Void
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                if rows.isEmpty {
                    Text("Nothing matches.")
                        .font(Theme.font(Theme.ui(13), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button { onPick(row) } label: { PaletteRow(row: row) }
                        .buttonStyle(PaletteRowStyle())
                        .rollUp(delay: 0.03 + Double(min(index, 8)) * 0.035)
                }
            }
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 56), maxHeight))
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .paletteBubble(cornerRadius: 26)
        .animation(Theme.Spring.morph, value: contentHeight)
    }
}

/// Run a picked row. Frecency is bumped here so every caller learns the
/// same way.
@MainActor
func runPaletteRow(_ row: CommandPalette.Row,
                   onConnect: (Host) -> Void,
                   onOverview: (Host) -> Void) -> Bool {
    if let key = row.frecencyKey { FrecencyStore.shared.bump(key) }
    switch row.kind {
    case .calculation(let value):
        UIPasteboard.general.string = value
        SoundEffects.shared.tap(.paletteConfirm, haptic: .success)
        return false                             // stay open; you may want another
    case .host(let host):
        SoundEffects.shared.tap(.paletteConfirm, haptic: .medium)
        onConnect(host)
    case .overview(let host):
        SoundEffects.shared.tap(.paletteConfirm, haptic: .light)
        onOverview(host)
    case .action(let go):
        SoundEffects.shared.tap(.paletteConfirm, haptic: .light)
        go()
    }
    return true
}

private struct PaletteRow: View {
    let row: CommandPalette.Row

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.system(size: Theme.ui(14), weight: .medium))
                .foregroundStyle(row.tint ?? Theme.textSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(Theme.font(Theme.ui(14), .semibold))
                    .foregroundStyle(row.tint ?? Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The Mac's focused-row look, under a finger: a soft wash and a hairline.
private struct PaletteRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.14) : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(configuration.isPressed ? Theme.strokeStrong : .clear,
                                  lineWidth: 0.5))
            .animation(Theme.Spring.crisp, value: configuration.isPressed)
    }
}
