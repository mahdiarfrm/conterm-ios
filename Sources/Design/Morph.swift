import SwiftUI

// MARK: - The morph
//
// The one transition for a thing that changed while you were looking at it.
// The old content slips out of focus — blur, a touch smaller, gone — and the
// new content comes into focus in the same place. About half a second, no
// bounce: a blur that overshoots reads as a glitch, not a change.
//
// It is the same move the launch overlay makes with the wordmark and
// `RollUpReveal` makes on first appearance; this is that move applied to
// *changes* rather than arrivals, so a number that updated, a label that
// flipped state and a loading row that became real content all read as the
// same physical event. Reduce Motion drops the blur and the scale and keeps
// the crossfade.

/// The out-of-focus end of the morph. `focused` is the identity.
struct MorphEffect: ViewModifier {
    var focused: Bool
    var radius: CGFloat = 9
    var scale: CGFloat = 0.94

    func body(content: Content) -> some View {
        content
            .blur(radius: focused ? 0 : radius)
            .opacity(focused ? 1 : 0)
            .scaleEffect(focused ? 1 : scale)
    }
}

extension AnyTransition {
    /// Blur out, blur in. Pair with `Theme.Spring.morph`.
    static var morph: AnyTransition {
        .modifier(active: MorphEffect(focused: false),
                  identity: MorphEffect(focused: true))
    }

    /// A softer morph for large surfaces — less blur, less shrink, so a whole
    /// panel swapping out doesn't look like it fell through the floor.
    static var morphPanel: AnyTransition {
        .modifier(active: MorphEffect(focused: false, radius: 6, scale: 0.98),
                  identity: MorphEffect(focused: true, radius: 6, scale: 0.98))
    }

    /// For a whole screen swapping — a tab. The lightest blur that still
    /// reads as the morph, because a blur over a full screen is the one
    /// effect that can cost frames.
    static var morphScreen: AnyTransition {
        .modifier(active: MorphEffect(focused: false, radius: 4, scale: 0.985),
                  identity: MorphEffect(focused: true, radius: 4, scale: 0.985))
    }
}

/// Re-identifies its content on `value`, so a change swaps the old view for
/// a new one through the morph. The two overlap for the duration, which is
/// what makes it read as one thing becoming another rather than two things
/// taking turns.
private struct Morph<Value: Hashable>: ViewModifier {
    var value: Value
    var alignment: Alignment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content
                .id(value)
                .transition(reduceMotion ? .opacity : .morph)
        }
        .animation(reduceMotion ? Theme.crossfade : Theme.Spring.morph, value: value)
    }
}

/// A number that changed. The same morph as everything else — the old
/// value goes out of focus, the new one focuses in — rather than digits
/// rolling like an odometer, which is a different physical event from the
/// rest of the screen. Kept as its own name so a call site says what it is.
private struct RollingDigits<Value: Hashable>: ViewModifier {
    var value: Value

    func body(content: Content) -> some View {
        content.morph(on: value)
    }
}

extension View {
    /// Morph to new content whenever `value` changes.
    ///
    /// `alignment` is where the old and new content are pinned to each other
    /// while they overlap: `.leading` for a line of text that grows or
    /// shrinks, `.center` for a number in a tile.
    func morph<V: Hashable>(on value: V, alignment: Alignment = .center) -> some View {
        modifier(Morph(value: value, alignment: alignment))
    }

    /// Morph this number to its new value whenever `value` changes.
    func rollingDigits<V: Hashable>(on value: V) -> some View {
        modifier(RollingDigits(value: value))
    }
}
