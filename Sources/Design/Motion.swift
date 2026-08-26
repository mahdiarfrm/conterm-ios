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
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .blur(radius: shown || reduceMotion ? 0 : 5)
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 9)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
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

/// A press state with physical give. Scaling rows in a tight list reads as
/// jitter, so a row shifts instead — the same call Conterm makes for its
/// sidebar.
struct PressablePill: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.Spring.snappy, value: configuration.isPressed)
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
    func rollUp(delay: Double = 0) -> some View { modifier(RollUpReveal(delay: delay)) }
    func revealCascade(_ index: Int) -> some View { modifier(RevealCascade(index: index)) }
}
