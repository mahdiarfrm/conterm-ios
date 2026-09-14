import SwiftUI

/// Motion primitives ported from Conterm.
///
/// All of them are gated on Reduce Motion, and all of them are one-shot —
/// nothing here runs a continuous clock. Conterm learned that the hard way on
/// a laptop; on a phone a permanent animation loop is a battery bug wearing a
/// design hat.

/// Content rises out of a blur into place. Conterm calls this the
/// "clock-digit reveal" and uses it for palette rows and briefing content.
struct RollUpReveal: ViewModifier {
    var delay: Double = 0
    /// Off: already in place, no motion.
    var enabled = true
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: Bool { shown || reduceMotion || !enabled }

    func body(content: Content) -> some View {
        content
            .blur(radius: still ? 0 : 5)
            .opacity(still ? 1 : 0)
            .offset(y: still ? 0 : 9)
            .onAppear {
                guard !reduceMotion, enabled else { shown = true; return }
                // Every appearance, not only the first: a tab shown again
                // rises again.
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shown = false }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.68).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// List rows fading in from the leading edge, staggered and capped.
///
/// The cap matters: without it, row 40 waits a second and a half and the list
/// reads as broken rather than choreographed.
struct RevealCascade: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(x: shown || reduceMotion ? 0 : -16)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(Theme.Spring.soft.delay(0.04 + Double(min(index, 8)) * 0.035)) {
                    shown = true
                }
            }
    }
}

/// A press state with physical give: the control sinks quickly under the
/// finger and springs back with a little bounce on release. The two halves
/// use different springs on purpose — press-in must feel instant, and the
/// release is where the bubbliness lives.
///
/// Scaling rows in a tight list reads as jitter, so a row shifts instead
/// (`PressableRow`) — the same call Conterm makes for its sidebar.
struct PressablePill: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? Theme.Spring.crisp : Theme.Spring.pop,
                       value: configuration.isPressed)
    }
}

struct PressableRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(x: configuration.isPressed ? 3 : 0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Theme.Spring.snappy, value: configuration.isPressed)
    }
}

extension View {
    func rollUp(delay: Double = 0, enabled: Bool = true) -> some View {
        modifier(RollUpReveal(delay: delay, enabled: enabled))
    }
    func revealCascade(_ index: Int) -> some View { modifier(RevealCascade(index: index)) }
}

/// A panel arriving: it focuses in from a blur, a touch smaller and a
/// little lower than where it lands, one after another down the screen.
/// The morph, applied to arrival — so a card that appears and a value that
/// changes inside it later are the same physical event at two sizes.
///
/// `index` staggers a column of panels; the delay is capped so the tenth
/// panel does not wait a second for its turn.
struct Arrive: ViewModifier {
    var index: Int
    var step: Double = 0.07
    var enabled = true
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: Bool { shown || reduceMotion || !enabled }

    func body(content: Content) -> some View {
        content
            .blur(radius: still ? 0 : 12)
            .opacity(still ? 1 : 0)
            .scaleEffect(still ? 1 : 0.94)
            .offset(y: still ? 0 : 18)
            .onAppear {
                guard !reduceMotion, enabled else { shown = true; return }
                // Every appearance, not only the first: a tab shown again
                // rises again.
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shown = false }
                withAnimation(Theme.Spring.morph.delay(0.05 + Double(min(index, 10)) * step)) {
                    shown = true
                }
            }
    }
}

/// A bubble popping in: from half size and out of focus to full size with
/// the release spring's give. For the small round things inside a panel —
/// container bubbles, host bubbles, chips — which arrive after the panel
/// has, staggered across the cloud.
struct PopIn: ViewModifier {
    var index: Int
    var step: Double = 0.045
    var base: Double = 0.12
    var enabled = true
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: Bool { shown || reduceMotion || !enabled }

    func body(content: Content) -> some View {
        content
            .blur(radius: still ? 0 : 6)
            .opacity(still ? 1 : 0)
            .scaleEffect(still ? 1 : 0.55)
            .onAppear {
                guard !reduceMotion, enabled else { shown = true; return }
                // Every appearance, not only the first: a tab shown again
                // rises again.
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shown = false }
                withAnimation(Theme.Spring.pop.delay(base + Double(min(index, 16)) * step)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Arrive as the `index`th panel in a column.
    func arrive(_ index: Int, step: Double = 0.07, enabled: Bool = true) -> some View {
        modifier(Arrive(index: index, step: step, enabled: enabled))
    }
    /// Pop in as the `index`th bubble in a cloud.
    func popIn(_ index: Int, base: Double = 0.12, enabled: Bool = true) -> some View {
        modifier(PopIn(index: index, base: base, enabled: enabled))
    }
}

/// A panel in a scrolling column, as it comes and goes: it focuses in as
/// it enters the screen and goes out of focus as it leaves, driven by the
/// scroll itself, so scrolling back through the column plays the arrivals
/// again. The morph, tied to the finger.
struct ScrollMorph: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // No blur here: a blur over a whole panel is redrawn every frame of
        // the scroll and was the one thing that dropped frames. Opacity,
        // scale and a little offset read as the same move and cost nothing.
        // The threshold is low so a panel taller than the screen counts as
        // arrived once a slice of it is in view, rather than never.
        content
            .scrollTransition(.interactive(timingCurve: .easeInOut).threshold(.visible(0.12))) { view, phase in
                view
                    .opacity(phase.isIdentity || reduceMotion ? 1 : 0.3)
                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.95)
                    .offset(y: reduceMotion ? 0 : phase.value * 18)
            }
    }
}

extension View {
    /// Come and go with the scroll.
    func scrollMorph() -> some View { modifier(ScrollMorph()) }
}
