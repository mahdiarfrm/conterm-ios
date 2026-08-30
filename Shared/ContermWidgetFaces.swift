import SwiftUI
import WidgetKit

/// Every widget size, as plain views.
///
/// Kept out of the widget target on purpose: the app renders exactly these in
/// a gallery, so the design can be looked at and changed in a build-and-run
/// loop rather than by installing a widget on a home screen to see what it
/// came out like.
///
/// Each face is a terminal showing the output of a command it just ran, and
/// they escalate by how much output there is room for:
///
///   inline       is anything running
///   circular     how many
///   rectangular  which one, and how long
///   small        the session you are in
///   medium       that, plus the rest of the fleet
///   large        all of it, plus what wants you
///
/// A new feature emits a `Signal` and appears at the right rank wherever
/// there is room. No layout changes.

// MARK: - Small

/// One session, the way a terminal would report it.
struct SmallFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        CT.Screen(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    CT.Prompt(command: "conterm", size: 9.5)
                    Spacer(minLength: 0)
                    Text("\(snapshot.live.count)/\(snapshot.hostCount)")
                        .font(CT.mono(9.5, .medium))
                        .foregroundStyle(CT.faint)
                }
                .padding(.bottom, 7)

                if let session = snapshot.headline {
                    HStack(spacing: 5) {
                        Text(CT.glyph(session.phase))
                            .font(CT.mono(13, .bold))
                            .foregroundStyle(CT.tint(session.phase))
                        Text(session.alias)
                            .font(CT.mono(16, .bold))
                            .foregroundStyle(CT.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                    Text(session.target)
                        .font(CT.mono(9, .medium))
                        .foregroundStyle(CT.faint)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Text(session.startedAt, style: .timer)
                        .font(CT.mono(23, .semibold))
                        .foregroundStyle(CT.text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.top, 6)

                    // The rest of the fleet as characters, not as rows. The
                    // list version truncated every line to "sibche-p…" in
                    // 170pt, which is worse than the empty band it replaced.
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        CT.Fleet(sessions: snapshot.live, size: 12)
                        Spacer(minLength: 0)
                        if let top = snapshot.ranked.first {
                            Text(CT.glyph(top.kind))
                                .font(CT.mono(12, .bold))
                                .foregroundStyle(CT.tint(top.kind))
                        }
                    }
                    HStack(spacing: 0) {
                        Text("\(snapshot.live.count) up")
                            .font(CT.mono(9.5, .medium))
                            .foregroundStyle(CT.faint)
                        Spacer(minLength: 0)
                        Text("\(CT.bytes(session.bytesIn)) in")
                            .font(CT.mono(9.5, .medium))
                            .foregroundStyle(CT.faint)
                    }
                    .padding(.top, 2)
                } else {
                    Text("no sessions")
                        .font(CT.mono(15, .semibold))
                        .foregroundStyle(CT.dim)
                    Text("\(snapshot.hostCount) hosts")
                        .font(CT.mono(10, .medium))
                        .foregroundStyle(CT.faint)
                        .padding(.top, 1)
                    Spacer(minLength: 0)
                    CT.Cursor(size: 13, color: CT.faint)
                }
            }
        }
    }
}

// MARK: - Medium

/// The fleet, as a block of output.
struct MediumFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        CT.Screen(padding: 15) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    CT.Prompt(command: "conterm sessions", size: 10)
                    Spacer(minLength: 0)
                    Text(counts)
                        .font(CT.mono(10, .medium))
                        .foregroundStyle(CT.faint)
                }
                .padding(.bottom, 7)

                if snapshot.live.isEmpty {
                    Text("no sessions")
                        .font(CT.mono(13, .semibold))
                        .foregroundStyle(CT.dim)
                        .frame(height: CT.line(13))
                    Spacer(minLength: 0)
                    CT.Cursor(size: 13, color: CT.faint)
                } else {
                    ForEach(Array(snapshot.live.prefix(4))) { session in
                        CT.SessionLine(session: session, size: 13)
                    }
                    if snapshot.live.count > 4 {
                        Text("+\(snapshot.live.count - 4) more")
                            .font(CT.mono(11, .medium))
                            .foregroundStyle(CT.faint)
                            .frame(height: CT.line(11))
                    }
                    Spacer(minLength: 0)
                }

                if let top = snapshot.ranked.first {
                    CT.Rule().padding(.vertical, 6)
                    CT.SignalLine(signal: top, size: 12)
                }
            }
        }
    }

    private var counts: String {
        "\(snapshot.live.count)/\(snapshot.hostCount)"
    }
}

// MARK: - Large

/// Everything, in two blocks of output.
struct LargeFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        CT.Screen(padding: 17) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    CT.Prompt(command: "conterm status", size: 10.5)
                    Spacer(minLength: 0)
                    Text("\(snapshot.live.count)/\(snapshot.hostCount)")
                        .font(CT.mono(10.5, .medium))
                        .foregroundStyle(CT.faint)
                }
                .padding(.bottom, 11)

                if snapshot.live.isEmpty {
                    Text("no sessions")
                        .font(CT.mono(14, .semibold))
                        .foregroundStyle(CT.dim)
                        .frame(height: CT.line(14))
                } else {
                    ForEach(Array(snapshot.live.prefix(6))) { session in
                        CT.SessionLine(session: session, size: 14)
                    }
                }

                if !snapshot.ranked.isEmpty {
                    CT.Rule().padding(.vertical, 10)
                    ForEach(Array(snapshot.ranked.prefix(4))) { signal in
                        CT.SignalLine(signal: signal, size: 13)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 0) {
                    CT.Cursor(size: 13, color: snapshot.live.isEmpty ? CT.faint : CT.ready)
                    Spacer(minLength: 0)
                    Text("\(CT.bytes(snapshot.live.reduce(0) { $0 + $1.bytesIn })) in")
                        .font(CT.mono(10.5, .medium))
                        .foregroundStyle(CT.faint)
                }
            }
        }
    }
}

// MARK: - Lock screen
//
// The lock screen renders these as a single tinted stencil, so they lean on
// shape and count rather than on colour, which will not survive.

/// A ring segmented by session, with the count in the middle.
struct CircularFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            let count = max(snapshot.live.count, 1)
            // The system's own backdrop for a circular accessory. Without it
            // the ring floats on the wallpaper with nothing behind it.
            AccessoryWidgetBackground()
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
                .font(CT.mono(18, .bold))
                .monospacedDigit()
        }
    }
}

/// Which one, and how long.
struct RectangularFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let session = snapshot.headline {
                Text(session.alias)
                    .font(CT.mono(14, .bold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(CT.glyph(session.phase))
                    Text(session.startedAt, style: .timer).monospacedDigit()
                    if let top = snapshot.ranked.first {
                        Text(CT.glyph(top.kind))
                        Text(top.title).lineLimit(1)
                    }
                }
                .font(CT.mono(11.5, .medium))
            } else {
                Text("conterm")
                    .font(CT.mono(14, .bold))
                Text("\(snapshot.hostCount) hosts · idle")
                    .font(CT.mono(11.5, .medium))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line, in the system's own type.
struct InlineFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        if let session = snapshot.headline {
            Text("\(session.alias) · \(snapshot.live.count) up")
        } else {
            Text("conterm · idle")
        }
    }
}
