import SwiftUI

/// One search over everything.
///
/// On a Mac this is a shortcut. On a phone it's the primary way to get
/// anywhere, because every other navigation affordance costs screen. So it
/// opens from a persistent bar rather than a key combination, and its rows
/// are touch targets rather than a keyboard-driven list.
///
/// Two things carry over from Conterm and matter more than they look:
///
/// **Everything becomes a `Row`.** Hosts, actions, settings and the
/// calculator are all synthesised into one type, so ranking, rendering and
/// selection need no special cases per source.
///
/// **Two-tier ranking.** Up to three top picks by frecency from any source,
/// then the rest in source order. Scores are computed once up front — doing
/// it inside the sort comparator calls `score()` O(n log n) times per
/// keystroke, which is exactly the sort of thing that makes a search field
/// feel laggy.
struct CommandPalette: View {
    let store: HostStore
    let onConnect: (Host) -> Void
    let onOverview: (Host) -> Void
    let onNewHost: () -> Void
    let onQuickConnect: () -> Void
    let onImport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

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

    private var rows: [Row] {
        var out: [Row] = []

        // A live calculation always leads — you typed a sum, you want the
        // answer, not a fuzzy host match on the digits.
        if let answer = QuickMath.answer(query) {
            out.append(Row(id: "calc", title: answer.display, subtitle: "Tap to copy",
                           symbol: "equal.square", tint: Theme.sshAccent,
                           kind: .calculation(answer.insert)))
        }

        let q = query.trimmed.lowercased()

        for host in store.hosts {
            let haystack = "\(host.alias) \(host.hostname) \(host.username)".lowercased()
            guard q.isEmpty || haystack.contains(q) else { continue }
            out.append(Row(id: "host:\(host.id)", title: host.alias,
                           subtitle: host.displaySubtitle,
                           symbol: "terminal",
                           kind: .host(host),
                           frecencyKey: "host.\(host.id)"))
            // Only offer the briefing once a query narrows things, or the
            // list doubles in length for no reason.
            if !q.isEmpty {
                out.append(Row(id: "info:\(host.id)", title: "How is \(host.alias)?",
                               subtitle: "Host overview",
                               symbol: "waveform.path.ecg",
                               kind: .overview(host),
                               frecencyKey: "overview.\(host.id)"))
            }
        }

        let actions: [(String, String, String, () -> Void)] = [
            ("Quick Connect", "user@host, nothing saved", "bolt.horizontal.fill", onQuickConnect),
            ("New Host", "Save a host you use often", "plus.circle", onNewHost),
            ("Import ssh config", "Bring across a fleet", "square.and.arrow.down", onImport),
        ]
        for (title, subtitle, symbol, run) in actions {
            guard q.isEmpty || title.lowercased().contains(q) else { continue }
            out.append(Row(id: "action:\(title)", title: title, subtitle: subtitle,
                           symbol: symbol, kind: .action(run),
                           frecencyKey: "action.\(title)"))
        }

        return rank(out)
    }

    /// Up to three frecency picks first, the rest in source order.
    private func rank(_ rows: [Row]) -> [Row] {
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                list
            }
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        SoundEffects.shared.play(.paletteClose)
                        dismiss()
                    }
                }
            }
        }
        .tint(Theme.accentOnDark)
        .onAppear {
            focused = true
            SoundEffects.shared.play(.paletteOpen)
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.ui(14), weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField("Hosts, actions, or a sum", text: $query)
                .font(.system(size: Theme.ui(16), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit { if let first = rows.first { run(first) } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Theme.ui(52))
        .glassPill(tone: .dark)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var list: some View {
        List(Array(rows.enumerated()), id: \.element.id) { index, row in
            Button { run(row) } label: { PaletteRow(row: row) }
                .buttonStyle(PressableRow())
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.stroke)
                .rollUp(delay: 0.03 + Double(min(index, 8)) * 0.035)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func run(_ row: Row) {
        if let key = row.frecencyKey { FrecencyStore.shared.bump(key) }

        switch row.kind {
        case .calculation(let value):
            UIPasteboard.general.string = value
            SoundEffects.shared.tap(.paletteConfirm, haptic: .success)
            return                                   // stay open; you may want another
        case .host(let host):
            SoundEffects.shared.tap(.paletteConfirm, haptic: .medium)
            dismiss(); onConnect(host)
        case .overview(let host):
            SoundEffects.shared.tap(.paletteConfirm, haptic: .light)
            dismiss(); onOverview(host)
        case .action(let go):
            SoundEffects.shared.tap(.paletteConfirm, haptic: .light)
            dismiss(); go()
        }
    }
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
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(row.tint ?? Theme.textPrimary)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
