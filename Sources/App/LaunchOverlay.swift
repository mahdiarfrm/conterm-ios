import SwiftUI

/// The launch moment, carried over from Conterm — and shortened.
///
/// The Mac app runs ~3.2s of choreography: scrim, colour wash, wordmark
/// blur-in, tagline, chord. That's a pleasure once a day on a desktop you
/// leave running. A phone app gets opened twenty times a day, so the same
/// sequence would become a toll. This keeps every beat and compresses it to
/// ~1.4s, and skips entirely on a tap — the animation must never stand
/// between you and a shell.
///
/// The palette is the *brand* family (warm crimson/coral on cream), which is
/// deliberately not the cool neutral of the running app. Conterm makes the
/// same distinction: the entrance is warm, the tool is cold.
struct LaunchOverlay: View {
    let onFinish: () -> Void

    @State private var wash = 0.0
    @State private var markIn = false
    @State private var taglineIn = false
    @State private var leaving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Drifting colour blobs. Static gradients would be cheaper still,
            // but this runs for one second and then never again.
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: leaving)) { ctx in
                    Canvas { gc, size in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let colors: [Color] = [Theme.Brand.crimson, Theme.Brand.red,
                                               Theme.Brand.coral, Theme.Brand.raspberry]
                        gc.addFilter(.blur(radius: 110))
                        for (i, color) in colors.enumerated() {
                            let r = min(size.width, size.height) * 0.55
                            let x = size.width * (0.5 + 0.30 * sin(t * 0.5 + Double(i) * 1.7))
                            let y = size.height * (0.5 + 0.22 * cos(t * 0.4 + Double(i) * 2.4))
                            gc.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2,
                                                           width: r, height: r)),
                                    with: .color(color.opacity(0.48)))
                        }
                    }
                    .blendMode(.plusLighter)
                }
                .opacity(wash)
                .ignoresSafeArea()
            } else {
                Theme.Brand.crimson.opacity(wash * 0.35).ignoresSafeArea()
            }

            VStack(spacing: 14) {
                ContermWordmark(height: 46)
                    .foregroundStyle(Theme.Brand.cream)
                    .blur(radius: markIn ? 0 : 18)
                    .opacity(markIn ? 1 : 0)
                    .scaleEffect(markIn ? 1 : 0.96)

                Text("A modern way to connect.")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .foregroundStyle(Theme.Brand.cream.opacity(0.75))
                    .opacity(taglineIn ? 1 : 0)
            }
        }
        .opacity(leaving ? 0 : 1)
        .blur(radius: leaving ? 18 : 0)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { run() }
    }

    private func run() {
        guard !reduceMotion else {
            // Respect the setting completely: show the mark, hold briefly,
            // leave. No drift, no blur-in.
            markIn = true; taglineIn = true; wash = 1
            Task { try? await Task.sleep(for: .milliseconds(450)); finish() }
            return
        }

        withAnimation(.easeOut(duration: 0.45)) { wash = 1 }
        withAnimation(.easeOut(duration: 0.70).delay(0.12)) { markIn = true }
        withAnimation(.easeOut(duration: 0.40).delay(0.58)) { taglineIn = true }

        SoundEffects.shared.play(.connect)
        Haptics.shared.prepare()

        Task {
            try? await Task.sleep(for: .milliseconds(1_450))
            finish()
        }
    }

    private func finish() {
        guard !leaving else { return }
        // The state change has to happen *inside* withAnimation. Setting it
        // first and then calling an empty withAnimation animates nothing —
        // which is why this used to flash past instead of dissolving.
        withAnimation(.easeIn(duration: 0.36)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(360))
            onFinish()
        }
    }
}
