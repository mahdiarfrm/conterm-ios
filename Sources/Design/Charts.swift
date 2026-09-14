import SwiftUI

// MARK: - Capsule bars

/// A bar chart where every bar is a thin capsule and the one that matters
/// is solid. The rest are the same colour, faded, so the chart reads as one
/// object with a highlight rather than a row of separate marks.
///
/// Bars stand close together at a fixed gap. Labels go under the bars when
/// they are short, or in a legend beneath the row when they are words. A
/// bar's height is its value and nothing else: a zero is a hairline.
struct CapsuleBars: View {
    struct Bar: Identifiable, Equatable {
        let id: String
        let label: String
        let value: Double
    }

    enum Labels { case under, legend, none }

    let bars: [Bar]
    /// The `id` of the bar drawn solid.
    var highlight: String?
    /// The value that fills the full height. Nil scales to the tallest bar.
    var maximum: Double?
    var height: CGFloat = 96
    var barWidth: CGFloat = 14
    /// Gap between bars.
    var spacing: CGFloat = 10
    var labels: Labels = .under
    var alignment: Alignment = .leading
    var tint: Color = Theme.meter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    private var top: Double {
        max(maximum ?? bars.map(\.value).max() ?? 1, 0.000_1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    let solid = bar.id == highlight
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Capsule(style: .continuous)
                            .fill(tint.opacity(solid ? 1 : 0.38))
                            .frame(width: barWidth,
                                   height: grown
                                       ? max(2, height * CGFloat(min(bar.value / top, 1)))
                                       : 2)
                            .animation(reduceMotion ? nil
                                       : Theme.Spring.morph.delay(Double(index) * 0.06),
                                       value: grown)
                        if labels == .under {
                            Text(bar.label)
                                .font(Theme.font(Theme.ui(10), .semibold))
                                .foregroundStyle(solid ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: barWidth + spacing)
                        }
                    }
                }
            }
            .frame(height: height + (labels == .under ? 20 : 0), alignment: .bottom)
            .frame(maxWidth: .infinity, alignment: alignment)
            if labels == .legend {
                FlowLayout(spacing: 10) {
                    ForEach(bars) { bar in
                        let solid = bar.id == highlight
                        HStack(spacing: 5) {
                            Capsule(style: .continuous)
                                .fill(tint.opacity(solid ? 1 : 0.38))
                                .frame(width: 10, height: 5)
                            Text(bar.label)
                                .font(Theme.font(Theme.ui(11), .semibold))
                                .foregroundStyle(solid ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : Theme.Spring.morph, value: bars)
        .onAppear { grown = true }
    }
}

// MARK: - Pulse chart

/// A time series as fine vertical lines on a gridded field: each sample a
/// line from its low to its high, the newest at the right, lit. The shape a
/// heart-rate chart takes, used here for the things a machine reports as a
/// spread — the least and most busy core, traffic in and out.
///
/// The lines draw themselves in one after another when the chart appears,
/// and each new sample grows in at the end. The field is a fixed number of
/// slots with the newest at the right edge, so a chart that has just
/// started is a few lines by "now" and empty to the left, which is the
/// honest picture of a sampler that has just begun.
struct PulseChart: View {
    struct Sample: Equatable {
        /// Both 0...1. Equal where the host reports one number.
        var low: Double
        var high: Double

        init(low: Double, high: Double) {
            self.low = min(max(min(low, high), 0), 1)
            self.high = min(max(max(low, high), 0), 1)
        }
        init(_ value: Double) { self.init(low: value, high: value) }
    }

    let samples: [Sample]
    var capacity: Int = 60
    var height: CGFloat = 120
    var tint: Color = Theme.meter
    /// Right-hand axis, top and bottom.
    var topLabel: String?
    var bottomLabel: String?
    /// Under the field, spread left to right.
    var timeLabels: [String] = []

    @State private var revealed: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let spread: Double = 3

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    PulseGrid()
                    PulseLines(samples: samples, capacity: capacity, revealed: revealed)
                        .fill(tint.opacity(0.9))
                    // The newest line, white: the same shape, only its last sample.
                    PulseLines(samples: samples, capacity: capacity, revealed: revealed,
                               onlyLast: true)
                        .fill(Color.white)
                }
                .frame(height: height)
                .clipped()
                if topLabel != nil || bottomLabel != nil {
                    VStack(alignment: .trailing) {
                        Text(topLabel ?? "")
                        Spacer(minLength: 0)
                        Text(bottomLabel ?? "")
                    }
                    .font(Theme.font(Theme.ui(10), .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .frame(height: height)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            if !timeLabels.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(timeLabels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer(minLength: 0) }
                        Text(label)
                            .font(Theme.font(Theme.ui(10), .medium))
                            .foregroundStyle(Theme.textSecondary.opacity(0.85))
                    }
                }
                .padding(.trailing, topLabel == nil && bottomLabel == nil ? 0 : 34)
            }
        }
        .onAppear { reveal(to: samples.count) }
        .onChange(of: samples.count) { _, count in reveal(to: count) }
    }

    /// Draw up to `count` lines. First appearance sweeps the whole field;
    /// a new sample only grows the one line.
    private func reveal(to count: Int) {
        let target = Double(count) + Self.spread
        if reduceMotion { revealed = target; return }
        let sweep = revealed == 0
        withAnimation(sweep ? .easeOut(duration: min(1.4, 0.3 + Double(count) * 0.03))
                            : Theme.Spring.morph) {
            revealed = target
        }
    }
}

/// The lines. `revealed` is how many are drawn, fractional, and each line
/// takes `spread` units of it to grow, so a sweep draws them in overlapping
/// sequence rather than one strictly after another.
private struct PulseLines: Shape {
    var samples: [PulseChart.Sample]
    var capacity: Int
    var revealed: Double
    var onlyLast = false
    var lineWidth: CGFloat = 3
    var spread: Double = 3

    var animatableData: Double {
        get { revealed }
        set { revealed = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let n = samples.count
        guard n > 0 else { return path }
        let slot = (rect.width - lineWidth) / CGFloat(max(capacity - 1, 1))
        let first = onlyLast ? n - 1 : 0
        for i in first..<n {
            let t = min(max((revealed - Double(i)) / spread, 0), 1)
            guard t > 0 else { continue }
            let s = samples[i]
            // Newest at the right edge, older to the left.
            let x = rect.maxX - lineWidth / 2 - CGFloat(n - 1 - i) * slot
            let yHigh = rect.minY + CGFloat(1 - s.high) * (rect.height - lineWidth) + lineWidth / 2
            let yLow = rect.minY + CGFloat(1 - s.low) * (rect.height - lineWidth) + lineWidth / 2
            let mid = (yHigh + yLow) / 2
            let half = max((yLow - yHigh) / 2, lineWidth / 2) * CGFloat(t)
            let box = CGRect(x: x - lineWidth / 2, y: mid - half,
                             width: lineWidth, height: half * 2)
            path.addRoundedRect(in: box, cornerSize: CGSize(width: lineWidth / 2,
                                                            height: lineWidth / 2))
        }
        return path
    }
}

/// The field behind the lines: dotted rules at quarter heights, faint
/// verticals at quarter widths.
private struct PulseGrid: View {
    var body: some View {
        Canvas { context, size in
            let rule = Color.white.opacity(0.22)
            for step in 0...4 {
                let y = size.height * CGFloat(step) / 4
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(rule),
                               style: StrokeStyle(lineWidth: 0.8, dash: [1.5, 4]))
            }
            let faint = Color.white.opacity(0.09)
            for step in 1..<4 {
                let x = size.width * CGFloat(step) / 4
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(faint), lineWidth: 0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Line chart

/// A smooth line with a soft fill beneath it and a dot on its newest point.
/// It draws itself from the left when it appears.
///
/// Two series when there are two: the second is the same line, dimmer, for
/// traffic out beside traffic in.
struct LineChart: View {
    /// Oldest first, 0...1.
    let values: [Double]
    var secondary: [Double]?
    var height: CGFloat = 100
    var tint: Color = Theme.meter
    var lineWidth: CGFloat = 2.5
    var showsArea = true
    var endDot = true
    /// A soft light under the line and its dot. The activity panel only;
    /// everywhere else the line is just the line.
    var glow = false

    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showsArea {
                SmoothLine(values: values, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(progress)
            }
            if let secondary {
                SmoothLine(values: secondary)
                    .trim(from: 0, to: progress)
                    .stroke(tint.opacity(0.45),
                            style: StrokeStyle(lineWidth: lineWidth * 0.8,
                                               lineCap: .round, lineJoin: .round))
            }
            SmoothLine(values: values)
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth,
                                                 lineCap: .round, lineJoin: .round))
                .shadow(color: tint.opacity(glow ? 0.45 : 0), radius: 4)
            if endDot, let last = values.last {
                GeometryReader { geo in
                    let inset = lineWidth
                    let x = geo.size.width - inset
                    let y = inset + CGFloat(1 - min(max(last, 0), 1)) * (geo.size.height - inset * 2)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .shadow(color: tint.opacity(glow ? 0.9 : 0), radius: 5)
                        .position(x: x, y: y)
                        .scaleEffect(progress)
                        .opacity(progress)
                }
            }
        }
        .frame(height: height)
        .onAppear {
            guard !reduceMotion else { progress = 1; return }
            withAnimation(.easeOut(duration: 1.1)) { progress = 1 }
        }
    }
}

/// A Catmull-Rom curve through the values, optionally closed to the
/// baseline. Constant point count means it can be trimmed for the draw-on.
private struct SmoothLine: Shape {
    var values: [Double]
    var closed = false
    var inset: CGFloat = 2.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = plotted(in: rect)
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: first.y))
        } else {
            for i in 0..<(points.count - 1) {
                let p0 = points[max(i - 1, 0)]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = points[min(i + 2, points.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
        if closed, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    private func plotted(in rect: CGRect) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let width = rect.width - inset * 2
        let height = rect.height - inset * 2
        let step = values.count > 1 ? width / CGFloat(values.count - 1) : width
        return values.enumerated().map { i, v in
            CGPoint(x: rect.minX + inset + CGFloat(i) * step,
                    y: rect.minY + inset + CGFloat(1 - min(max(v, 0), 1)) * height)
        }
    }
}

// MARK: - Ring

/// A fraction as an arc. Draws itself round on appearance and eases to a
/// new fill afterwards.
struct Ring: View {
    let fraction: Double
    var tint: Color = Theme.meter
    var size: CGFloat = 40
    var lineWidth: CGFloat = 5
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: drawn ? min(max(fraction, 0), 1) : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : Theme.Spring.morph, value: fraction)
        .onAppear {
            guard !reduceMotion else { drawn = true; return }
            withAnimation(Theme.Spring.morph.delay(0.2)) { drawn = true }
        }
    }
}

// MARK: - Capsule ramp

/// A share of something as a row of capsules that grow from dots on the
/// left to pills on the right, lit up to the value. The shape a water
/// tracker takes for "so far, out of the goal"; here it is memory in use,
/// a disk filling, anything that is a part of a whole.
///
/// It is alive: the capsules light one after another when the chart
/// appears, the frontier glows, and a change sweeps along the row rather
/// than snapping.
struct CapsuleRamp: View {
    let fraction: Double
    var count: Int = 20
    var minHeight: CGFloat = 8
    var maxHeight: CGFloat = 44
    var spacing: CGFloat = 5
    var tint: Color = Theme.meter
    /// Spread evenly under the row, with a tick above each.
    var labels: [String] = []

    @State private var lit = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var target: Int {
        Int((min(max(fraction, 0), 1) * Double(count)).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = max((geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 3)
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        let on = i < lit
                        let frontier = on && i == lit - 1
                        let height = minHeight + (maxHeight - minHeight)
                            * CGFloat(i) / CGFloat(max(count - 1, 1))
                        Capsule(style: .continuous)
                            .fill(on ? tint : Theme.stroke)
                            .frame(width: width, height: max(height, width))
                            .scaleEffect(on ? 1 : 0.9, anchor: .bottom)
                            .opacity(frontier ? 1 : (on ? 0.85 : 1))
                            .animation(reduceMotion ? nil
                                       : Theme.Spring.pop.delay(Double(min(i, count)) * 0.03),
                                       value: lit)
                    }
                }
                .frame(width: geo.size.width, height: maxHeight, alignment: .bottomLeading)
            }
            .frame(height: maxHeight)
            if !labels.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer(minLength: 0) }
                        VStack(spacing: 3) {
                            Rectangle().fill(Theme.textSecondary.opacity(0.5))
                                .frame(width: 1, height: 5)
                            Text(label)
                                .font(Theme.font(Theme.ui(10), .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { lit = target; return }
            // A beat after the panel has landed, then the sweep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { lit = target }
        }
        .onChange(of: fraction) { _, _ in lit = target }
    }
}

// MARK: - Rank bars

/// A ranked list as horizontal capsules: each row a bar as long as its
/// share, the name on the bar, the number at its end. The first is solid;
/// the rest are the same colour, faded. Bars grow from the left when the
/// chart appears.
struct RankBars: View {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let value: Double
        let text: String
    }

    let rows: [Row]
    var maximum: Double?
    var tint: Color = Theme.meter
    var height: CGFloat = 34
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var top: Double { max(maximum ?? rows.map(\.value).max() ?? 1, 0.000_1) }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                GeometryReader { geo in
                    let fraction = CGFloat(min(row.value / top, 1))
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.14))
                        Capsule(style: .continuous)
                            .fill(tint.opacity(index == 0 ? 1 : 0.42))
                            .frame(width: grown ? max(height, geo.size.width * fraction) : height)
                            .animation(reduceMotion ? nil
                                       : Theme.Spring.morph.delay(Double(index) * 0.06),
                                       value: grown)
                        HStack {
                            Text(row.label)
                                .font(.system(size: Theme.ui(12), weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.leading, 12)
                            Spacer(minLength: 8)
                            Text(row.text)
                                .font(Theme.font(Theme.ui(12), .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                                .padding(.trailing, 12)
                        }
                    }
                }
                .frame(height: height)
            }
        }
        .animation(reduceMotion ? nil : Theme.Spring.morph, value: rows)
        .onAppear { grown = true }
    }
}

// MARK: - Ring stack

/// Several shares as concentric rings, the outermost the first, each in
/// its own colour, each drawing itself round when the chart appears and
/// easing to a new fill afterwards. A legend beside it names them.
struct RingStack: View {
    struct Slice: Identifiable, Equatable {
        let id: String
        let label: String
        let fraction: Double
        let tint: Color
        var text: String?
    }

    let slices: [Slice]
    var size: CGFloat = 150
    var lineWidth: CGFloat = 12
    var gap: CGFloat = 5
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let inset = CGFloat(index) * (lineWidth + gap)
                Circle()
                    .stroke(slice.tint.opacity(0.18), lineWidth: lineWidth)
                    .padding(inset + lineWidth / 2)
                Circle()
                    .trim(from: 0, to: drawn ? min(max(slice.fraction, 0), 1) : 0)
                    .stroke(slice.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset + lineWidth / 2)
                    .animation(reduceMotion ? nil
                               : Theme.Spring.morph.delay(0.15 + Double(index) * 0.12),
                               value: drawn)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : Theme.Spring.morph, value: slices)
        .onAppear { drawn = true }
    }
}
