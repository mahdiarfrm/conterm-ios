import SwiftUI

/// Every widget size, as plain views.
///
/// Kept out of the widget target on purpose: the app renders exactly these in
/// a gallery, so the design can be looked at and changed in a build-and-run
/// loop rather than by installing a widget on a home screen to see what it
/// came out like. The WidgetKit wrappers do nothing but hand each of these a
/// snapshot.
///
/// Each face answers a different number of questions, and they escalate:
///
///   inline       is anything running
///   circular     how many, and is anything wrong
///   rectangular  which one, and how long
///   small        the session you are actually in
///   medium       that, plus the rest of the fleet
///   large        all of it, plus what wants you
///
/// A new feature emits a `Signal` and appears at the right rank in the three
/// faces that have room for signals. No layout changes.
public enum ContermFace {}

// MARK: - Small

/// The session you are in. One name, one clock, one gem.
struct SmallFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        CT.Plate(corner: 22, padding: 15) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 6)
                body(for: snapshot.headline)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            CT.Label(text: snapshot.live.isEmpty ? "conterm" : "session")
            Spacer(minLength: 0)
            if let top = snapshot.ranked.first {
                Image(systemName: top.kind.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CT.tint(top.kind))
            }
            CT.Rail(colors: CT.railColors(snapshot), thickness: 2.5, length: 12, axis: .horizontal)
        }
    }

    @ViewBuilder
    private func body(for session: ContermSnapshot.Session?) -> some View {
        if let session {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    CT.Cursor(height: 20, color: CT.tint(session.phase),
                              filled: session.phase == .connected)
                    Text(session.alias)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(CT.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(session.target)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(CT.dim)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 2)

                // The two numbers worth the bottom of a small widget, on one
                // baseline. An empty band between the name and the clock read
                // as a layout that had run out of things to say.
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(session.startedAt, style: .timer)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(CT.text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Text(CT.bytes(session.bytesIn))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CT.dim)
                }
                CT.Label(text: session.phase.label)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                CT.Cursor(height: 20, color: CT.dim, filled: false)
                Spacer(minLength: 0)
                Text("nothing running")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(CT.text)
                Text(snapshot.hostCount == 1 ? "1 host saved"
                                             : "\(snapshot.hostCount) hosts saved")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CT.dim)
            }
        }
    }
}

// MARK: - Medium

/// The session, and the rest of what is up.
struct MediumFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        CT.Plate(corner: 22, padding: 15) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    left
                    divider
                    right
                }
                // A signal spans the whole plate rather than sharing the
                // narrow left column, where "Claude needs you · sibche-prod"
                // truncated to "Clau… sibch…" and said nothing at all.
                if let top = snapshot.ranked.first {
                    Rectangle().fill(CT.dim.opacity(0.16))
                        .frame(height: 0.5)
                        .padding(.top, 9)
                    CT.SignalRow(signal: top, size: 12)
                        .padding(.top, 7)
                }
            }
        }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 3) {
            CT.Label(text: "live")
            Text("\(snapshot.live.count)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(CT.text)
                .monospacedDigit()
                .lineLimit(1)
            // Horizontal, under the number: the fleet reads as a bar chart
            // of what is up rather than as a tall stripe competing with it.
            CT.Rail(colors: CT.railColors(snapshot), thickness: 3, length: 16, axis: .horizontal)
            Spacer(minLength: 0)
            Text(snapshot.hostCount == 1 ? "1 host" : "\(snapshot.hostCount) hosts")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(CT.dim)
        }
        .frame(width: 96, alignment: .leading)
    }

    private var divider: some View {
        // A hairline that fades out at both ends, so it separates without
        // drawing a hard line across the plate.
        LinearGradient(colors: [.clear, CT.dim.opacity(0.35), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 1)
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 7) {
            if snapshot.live.isEmpty {
                CT.Label(text: "no sessions")
                Text("Tap to connect")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(CT.text)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(snapshot.live.prefix(3))) { session in
                    CT.SessionRow(session: session, size: 13)
                }
                if snapshot.live.count > 3 {
                    Text("+\(snapshot.live.count - 3) more")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(CT.dim)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Large

/// Everything, ranked: what is up, and what wants you.
struct LargeFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        CT.Plate(corner: 24, padding: 17) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 13)

                section("sessions")
                if snapshot.live.isEmpty {
                    empty("Nothing running",
                          detail: snapshot.hostCount == 1 ? "1 host saved"
                                                          : "\(snapshot.hostCount) hosts saved")
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(snapshot.live.prefix(4))) { session in
                            CT.SessionRow(session: session, size: 14)
                        }
                    }
                    .padding(.bottom, 4)
                }

                Spacer(minLength: 10)

                section("wants you")
                if snapshot.ranked.isEmpty {
                    empty("All quiet", detail: nil)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(snapshot.ranked.prefix(4))) { signal in
                            CT.SignalRow(signal: signal, size: 13)
                        }
                    }
                }

                Spacer(minLength: 0)
                footer
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            CT.Cursor(height: 20, color: CT.ssh, filled: !snapshot.live.isEmpty)
            Text("Conterm")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(CT.text)
            Spacer(minLength: 0)
            CT.Rail(colors: CT.railColors(snapshot), thickness: 3, length: 16, axis: .horizontal)
        }
    }

    private func section(_ title: String) -> some View {
        CT.Label(text: title).padding(.bottom, 7)
    }

    private func empty(_ title: String, detail: String?) -> some View {
        HStack(spacing: 7) {
            CT.Cursor(height: 13, color: CT.dim, filled: false)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(CT.dim)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(CT.dim.opacity(0.7))
            }
        }
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            CT.Readout(label: "hosts") {
                Text("\(snapshot.hostCount)")
            }
            CT.Readout(label: "received") {
                Text(CT.bytes(snapshot.live.reduce(0) { $0 + $1.bytesIn }))
            }
            Spacer(minLength: 0)
            CT.Readout(label: "updated") {
                Text(snapshot.updatedAt, style: .relative)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CT.dim)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(CT.dim.opacity(0.16)).frame(height: 0.5)
        }
    }
}

// MARK: - Lock screen

/// A ring of the fleet, with the count in the middle.
struct CircularFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        ZStack {
            AccessoryBackground()
            let colors = CT.railColors(snapshot)
            ForEach(Array(colors.prefix(8).enumerated()), id: \.offset) { index, color in
                Circle()
                    .trim(from: fraction(index, of: colors.count) + 0.012,
                          to: fraction(index + 1, of: colors.count) - 0.012)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(3)

            Text("\(snapshot.live.count)")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }

    private func fraction(_ index: Int, of count: Int) -> CGFloat {
        CGFloat(index) / CGFloat(max(count, 1))
    }
}

/// Which one, and how long.
struct RectangularFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        HStack(spacing: 6) {
            if let session = snapshot.headline {
                CT.Cursor(height: 13, color: .primary, filled: session.phase == .connected)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.alias)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.startedAt, style: .timer)
                            .monospacedDigit()
                        if let top = snapshot.ranked.first {
                            Image(systemName: top.kind.symbol)
                            Text(top.title).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                }
            } else {
                CT.Cursor(height: 13, color: .primary, filled: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Conterm")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("\(snapshot.hostCount) hosts · nothing running")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One line, in the system's own type.
struct InlineFace: View {
    var snapshot: ContermSnapshot

    var body: some View {
        if let session = snapshot.headline {
            Text("\(session.alias) · \(snapshot.live.count) live")
        } else {
            Text("Conterm · nothing running")
        }
    }
}

/// The lock screen tints everything to a single colour, so accessory faces
/// use `.primary` and lean on shape rather than hue.
private struct AccessoryBackground: View {
    var body: some View {
        Circle().fill(.clear)
    }
}
