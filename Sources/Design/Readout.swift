import SwiftUI

// MARK: - Readout

/// A number you glance at: the value first and large, the meaning beneath it
/// as a small glyph and a word. The grammar of a stat tile, without the tile —
/// it sits directly on whatever surface it is given.
///
/// The value morphs when it changes, so a refresh that moves a number reads
/// as the number moving rather than the screen redrawing.
struct Readout: View {
    let value: String
    let label: String
    var symbol: String?
    /// A second line under the label — the unit, the mount, the core count.
    var detail: String?
    /// Draws a meter between the value and the label when present.
    var fraction: Double?
    /// Meter and glyph colour. The value stays in the text colour so the
    /// three readouts on a row don't turn into a traffic light.
    var tint: Color = Theme.meter
    var size: CGFloat = 26
    /// A readout with nothing to say dims rather than disappears, so the
    /// row keeps its shape.
    var muted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(Theme.font(Theme.ui(size), .bold))
                .foregroundStyle(muted ? Theme.textSecondary : Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .morph(on: value, alignment: .leading)

            if let fraction {
                MeterBar(fraction: fraction, tint: tint)
            }

            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Theme.ui(10), weight: .semibold))
                        .foregroundStyle(muted ? Theme.textSecondary : tint)
                }
                Text(label)
                    .font(Theme.font(Theme.ui(11.5), .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            if let detail {
                Text(detail)
                    .font(Theme.font(Theme.ui(9.5), .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .morph(on: detail, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A capsule meter that eases to its new fill. Rounded ends, a soft glow
/// in the tint, and the fill grows from the leading edge.
struct MeterBar: View {
    let fraction: Double
    var tint: Color = Theme.meter
    var height: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.stroke)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.65), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : Theme.Spring.morph, value: fraction)
    }
}

/// A readout in a tile: the meaning first and small, then the number as
/// large as the tile allows, then a detail. Two by two of these under a
/// chart is a briefing you can take in at arm's length.
struct StatTile: View {
    let value: String
    let label: String
    var symbol: String?
    var detail: String?
    var size: CGFloat = 40
    /// Draws a ring in the corner when the number is a share of something.
    var fraction: Double?
    var tint: Color = Theme.meter
    var bed: PanelBed = .glass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 5) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: Theme.ui(11), weight: .semibold))
                    }
                    Text(label)
                        .font(Theme.font(Theme.ui(12), .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                if let fraction {
                    Ring(fraction: fraction, tint: tint, size: 30, lineWidth: 4)
                }
            }
            Spacer(minLength: 0)
            Text(value)
                .font(Theme.font(Theme.ui(size), .heavy))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .morph(on: value, alignment: .leading)
            if let detail, !detail.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(detail)
                    .font(Theme.font(Theme.ui(11), .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .morph(on: detail, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .panelSurface(bed, cornerRadius: Theme.tileCorner)
    }
}
