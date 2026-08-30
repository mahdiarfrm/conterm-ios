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
///   medium       that, plus the rest of the fleet
///   large        all of it, plus what wants you
///
/// A new feature emits a `Signal` and appears wherever there is room, ranked.
/// No layout changes.

// MARK: - Small

struct SmallFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            CT.Ground()
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(15)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            CT.Mark(size: 12)
            Spacer(minLength: 0)
            if let top = snapshot.ranked.first {
                Image(systemName: CT.symbol(top.kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CT.tint(top.kind))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = snapshot.headline {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 6)
                Text(session.alias)
                    .font(CT.ui(19, .bold))
                    .foregroundStyle(CT.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                // Where it actually is. Without it the face was a name, a
                // clock, and a band of nothing between the two.
                Text(session.target)
                    .font(CT.ui(10.5, .medium))
                    .foregroundStyle(CT.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.top, 1)

                Spacer(minLength: 4)

                Text(session.startedAt, style: .timer)
                    .font(CT.ui(26, .semibold))
                    .foregroundStyle(CT.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                CT.Chip(tint: CT.tint(session.phase)) {
                    HStack(spacing: 5) {
                        CT.Gem(color: CT.tint(session.phase), size: 5)
                        Text(caption(for: session))
                            .font(CT.ui(10, .semibold))
                            .foregroundStyle(CT.text)
                    }
                }
                .padding(.top, 6)
            }
        } else {
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing running")
                    .font(CT.ui(16, .bold))
                    .foregroundStyle(CT.text)
                Text(snapshot.hostCount == 1 ? "1 host" : "\(snapshot.hostCount) hosts")
                    .font(CT.ui(12, .medium))
                    .foregroundStyle(CT.faint)
            }
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
            CT.Ground()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    CT.Mark(size: 13)
                    Spacer(minLength: 0)
                    CT.Chip {
                        Text("\(snapshot.live.count) live")
                            .font(CT.ui(10.5, .semibold))
                            .foregroundStyle(CT.dim)
                            .monospacedDigit()
                    }
                }
                .padding(.bottom, 12)

                if snapshot.live.isEmpty {
                    empty
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(snapshot.live.prefix(3))) { session in
                            CT.SessionRow(session: session, size: 14)
                        }
                    }
                }

                Spacer(minLength: 6)

                if let top = snapshot.ranked.first {
                    CT.SignalRow(signal: top, size: 12.5)
                } else if snapshot.live.count > 3 {
                    Text("+\(snapshot.live.count - 3) more")
                        .font(CT.ui(11, .medium))
                        .foregroundStyle(CT.faint)
                }
            }
            .padding(16)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nothing running")
                .font(CT.ui(15, .bold))
                .foregroundStyle(CT.text)
            Text(snapshot.hostCount == 1 ? "1 host saved"
                                         : "\(snapshot.hostCount) hosts saved")
                .font(CT.ui(12, .medium))
                .foregroundStyle(CT.faint)
        }
    }
}

// MARK: - Large

struct LargeFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            CT.Ground()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    CT.Mark(size: 16)
                    Spacer(minLength: 0)
                    CT.Chip {
                        Text("\(snapshot.live.count) live · \(snapshot.hostCount) hosts")
                            .font(CT.ui(11, .semibold))
                            .foregroundStyle(CT.dim)
                            .monospacedDigit()
                    }
                }
                .padding(.bottom, 18)

                if snapshot.live.isEmpty {
                    Text("Nothing running")
                        .font(CT.ui(16, .bold))
                        .foregroundStyle(CT.text)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(snapshot.live.prefix(5))) { session in
                            CT.SessionRow(session: session, size: 15)
                        }
                    }
                }

                if !snapshot.ranked.isEmpty {
                    Spacer(minLength: 18)
                    Text("WANTS YOU")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(CT.faint)
                        .padding(.bottom, 9)
                    VStack(spacing: 10) {
                        ForEach(Array(snapshot.ranked.prefix(3))) { signal in
                            CT.SignalRow(signal: signal, size: 13.5)
                        }
                    }
                }

                Spacer(minLength: 10)

                HStack(spacing: 0) {
                    Text("\(CT.bytes(snapshot.live.reduce(0) { $0 + $1.bytesIn })) received")
                        .font(CT.ui(11, .medium))
                        .foregroundStyle(CT.faint)
                    Spacer(minLength: 0)
                    Text(snapshot.updatedAt, style: .relative)
                        .font(CT.ui(11, .medium))
                        .foregroundStyle(CT.faint)
                }
            }
            .padding(18)
        }
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
