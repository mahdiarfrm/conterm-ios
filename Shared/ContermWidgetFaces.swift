import SwiftUI
import WidgetKit

/// Every widget size, as plain views.
///
/// Kept out of the widget target on purpose: the app renders exactly these in
/// a gallery, so the design can be looked at and changed in a build-and-run
/// loop rather than by installing a widget on a home screen to see what it
/// came out like.
///
/// Each face answers one more question than the last:
///
///   inline       is anything running
///   circular     how many
///   rectangular  which one, and how long
///   small        the session you are in
///   medium       how many, and which
///   large        all of it, plus what wants you
///
/// Every one sits on the ground the app is on, and is drawn with the app's
/// panels: a translucent tile with a lit rim, the number first and large.

// MARK: - Small

struct SmallFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            CT.Ground(palette: CT.palette(snapshot.ground))
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(15)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            CT.Logo(height: 12)
            Spacer(minLength: 0)
            if let top = snapshot.ranked.first {
                Image(systemName: CT.symbol(top.kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CT.tint(top.kind))
            } else {
                CT.Gem(color: snapshot.live.isEmpty ? CT.idle.opacity(0.5) : CT.ready, size: 7)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = snapshot.headline {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 6)
                Text(session.alias)
                    .font(CT.ui(17, .bold))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(session.target)
                    .font(CT.ui(10.5, .medium))
                    .foregroundStyle(CT.dim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.top, 1)
                Spacer(minLength: 4)
                Text(session.startedAt, style: .timer)
                    .font(CT.ui(30, .bold))
                    .foregroundStyle(CT.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                CT.Chip(lit: true) {
                    HStack(spacing: 5) {
                        CT.Gem(color: CT.tint(session.phase), size: 5)
                        Text(caption(for: session))
                            .font(CT.ui(10, .bold))
                            .foregroundStyle(CT.text)
                    }
                }
                .padding(.top, 6)
            }
        } else {
            Spacer(minLength: 6)
            CT.Readout(value: "\(snapshot.hostCount)",
                       label: snapshot.hostCount == 1 ? "host" : "hosts",
                       symbol: "server.rack", size: 40)
            Spacer(minLength: 4)
            Text("Nothing running")
                .font(CT.ui(11, .semibold))
                .foregroundStyle(CT.dim)
        }
    }

    /// The chip says the most useful thing there is room for: how many other
    /// sessions are up, or — when this is the only one — what state it is in.
    private func caption(for session: ContermSnapshot.Session) -> String {
        let others = snapshot.live.count - 1
        return others > 0 ? "+\(others) more" : session.phase.label
    }
}

// MARK: - Medium

struct MediumFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            CT.Ground(palette: CT.palette(snapshot.ground))
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    CT.Logo(height: 12)
                    Spacer(minLength: 6)
                    CT.Readout(value: "\(snapshot.live.count)",
                               label: "live", symbol: "bolt.horizontal.fill", size: 44,
                               tint: CT.text)
                    Spacer(minLength: 4)
                    Text(snapshot.hostCount == 1 ? "1 host" : "\(snapshot.hostCount) hosts")
                        .font(CT.ui(11, .semibold))
                        .foregroundStyle(CT.dim)
                }
                .frame(width: 104, alignment: .leading)

                VStack(spacing: 6) {
                    if snapshot.live.isEmpty {
                        Spacer(minLength: 0)
                        Text("Nothing running")
                            .font(CT.ui(14, .bold))
                            .foregroundStyle(CT.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                    } else {
                        ForEach(Array(snapshot.live.prefix(3))) { session in
                            CT.Tile(cornerRadius: 14, padding: 9) {
                                CT.SessionRow(session: session, size: 13)
                            }
                        }
                    }
                    if let top = snapshot.ranked.first {
                        CT.Chip(tint: CT.tint(top.kind)) {
                            HStack(spacing: 5) {
                                Image(systemName: CT.symbol(top.kind))
                                    .font(.system(size: 9, weight: .bold))
                                Text(top.title)
                                    .font(CT.ui(10, .bold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(CT.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if snapshot.live.count > 3 {
                        Text("+\(snapshot.live.count - 3) more")
                            .font(CT.ui(10.5, .semibold))
                            .foregroundStyle(CT.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(15)
        }
    }
}

// MARK: - Large

struct LargeFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            CT.Ground(palette: CT.palette(snapshot.ground))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    CT.Logo(height: 15)
                    Spacer(minLength: 0)
                    CT.Chip {
                        Text(snapshot.updatedAt, style: .relative)
                            .font(CT.ui(10, .semibold))
                            .foregroundStyle(CT.dim)
                            .monospacedDigit()
                    }
                }
                .padding(.bottom, 14)

                HStack(alignment: .top, spacing: 14) {
                    CT.Readout(value: "\(snapshot.live.count)", label: "live",
                               symbol: "bolt.horizontal.fill", size: 30)
                    divider
                    CT.Readout(value: "\(snapshot.hostCount)", label: "hosts",
                               symbol: "server.rack", size: 30)
                    divider
                    CT.Readout(value: "\(snapshot.ranked.count)", label: "wants you",
                               symbol: "sparkles", size: 30,
                               tint: snapshot.ranked.isEmpty ? CT.text : CT.attention)
                }
                .padding(.bottom, 12)

                if snapshot.live.isEmpty {
                    CT.Tile(cornerRadius: 16, padding: 12) {
                        Text("Nothing running")
                            .font(CT.ui(14, .bold))
                            .foregroundStyle(CT.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Three rows when signals need the room beneath, four
                    // when they do not.
                    VStack(spacing: 5) {
                        ForEach(Array(snapshot.live.prefix(snapshot.ranked.isEmpty ? 4 : 3))) { session in
                            CT.Tile(cornerRadius: 15, padding: 9) {
                                HStack(spacing: 8) {
                                    CT.SessionRow(session: session, size: 13.5)
                                    Text("↓ \(CT.bytes(session.bytesIn))")
                                        .font(CT.ui(10.5, .semibold))
                                        .foregroundStyle(CT.faint)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                if !snapshot.ranked.isEmpty {
                    Text("WANTS YOU")
                        .font(CT.ui(9.5, .bold))
                        .tracking(1.1)
                        .foregroundStyle(CT.dim)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    VStack(spacing: 6) {
                        ForEach(Array(snapshot.ranked.prefix(2))) { signal in
                            CT.SignalRow(signal: signal, size: 13)
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 0) {
                    Text("\(CT.bytes(snapshot.live.reduce(0) { $0 + $1.bytesIn })) in")
                    Text("  ·  ")
                    Text("\(CT.bytes(snapshot.live.reduce(0) { $0 + $1.bytesOut })) out")
                    Spacer(minLength: 0)
                }
                .font(CT.ui(11, .medium))
                .foregroundStyle(CT.faint)
                .monospacedDigit()
            }
            .padding(17)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 36).padding(.top, 4)
    }
}

// MARK: - Lock screen
//
// Rendered as a single tinted stencil over the wallpaper, so these lean on
// shape and count. Colour does not survive; nothing here depends on it.

struct CircularFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            let count = max(snapshot.live.count, 1)
            Circle()
                .stroke(.primary.opacity(0.22), lineWidth: 3.5)
                .padding(3)
            ForEach(0..<min(snapshot.live.count, 8), id: \.self) { index in
                Circle()
                    .trim(from: CGFloat(index) / CGFloat(count) + 0.014,
                          to: CGFloat(index + 1) / CGFloat(count) - 0.014)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }
            Text("\(snapshot.live.count)")
                .font(CT.ui(18, .bold))
                .monospacedDigit()
        }
    }
}

struct RectangularFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let session = snapshot.headline {
                Text(session.alias)
                    .font(CT.ui(15, .bold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(session.startedAt, style: .timer).monospacedDigit()
                    if let top = snapshot.ranked.first {
                        Image(systemName: CT.symbol(top.kind))
                        Text(top.title).lineLimit(1)
                    } else {
                        Text("· \(snapshot.live.count) live")
                    }
                }
                .font(CT.ui(12, .medium))
            } else {
                Text("Conterm")
                    .font(CT.ui(15, .bold))
                Text("\(snapshot.hostCount) hosts · idle")
                    .font(CT.ui(12, .medium))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlineFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        if let session = snapshot.headline {
            Text("\(session.alias) · \(snapshot.live.count) live")
        } else {
            Text("Conterm · idle")
        }
    }
}
