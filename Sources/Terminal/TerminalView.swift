import SwiftUI
import UIKit

/// SwiftUI wrapper around the libghostty surface.
///
/// The view is created once and never rebuilt: libghostty holds a pointer to
/// it for the surface's whole life, so a `UIViewRepresentable` that made a
/// new one on every update would hand the renderer a dangling view. Hence
/// the session owns the view and this only ever hands it back.
struct TerminalView: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> TerminalSurfaceView {
        session.surfaceView
    }

    func updateUIView(_ view: TerminalSurfaceView, context: Context) {
        // Nothing to push: the session drives the surface directly.
    }
}

/// The key accessory row.
///
/// A phone keyboard has no Escape, no Tab, no Ctrl and no arrows, which is
/// most of what a terminal is driven by. Ctrl and Alt latch for exactly one
/// keystroke — press Ctrl, then C — which is the behaviour a sticky modifier
/// is expected to have and the only one that works one-handed.
struct KeyAccessoryBar: View {
    let session: TerminalSession
    @State private var control = false
    @State private var alt = false

    /// A key is either a real key press or a literal character.
    ///
    /// The distinction is load-bearing, not stylistic. `ghostty_surface_text`
    /// is paste, and ghostty replaces ESC, DEL and the tty control bytes with
    /// spaces in a paste — so escape, backspace, the arrows and every Ctrl
    /// chord have to go through the *key* API with a keycode. Only the plain
    /// punctuation here is safe to send as text.
    private struct Key: Identifiable {
        let id = UUID()
        var label: String = ""
        var symbol: String?
        /// A real key press. Preferred; `text` is the fallback for characters
        /// that carry no control meaning.
        var usage: UIKeyboardHIDUsage?
        var text: String?
        var wide = false
    }

    private static let keys: [Key] = [
        .init(label: "esc", usage: .keyboardEscape),
        .init(label: "tab", usage: .keyboardTab),
        .init(symbol: "return", usage: .keyboardReturnOrEnter, wide: true),
        .init(symbol: "arrow.up", usage: .keyboardUpArrow),
        .init(symbol: "arrow.down", usage: .keyboardDownArrow),
        .init(symbol: "arrow.left", usage: .keyboardLeftArrow),
        .init(symbol: "arrow.right", usage: .keyboardRightArrow),
        .init(label: "/", text: "/"),
        .init(label: "-", text: "-"),
        .init(label: "|", text: "|"),
        .init(label: "~", text: "~"),
        .init(symbol: "delete.left", usage: .keyboardDeleteOrBackspace),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                modifier("ctrl", on: $control)
                modifier("alt", on: $alt)
                ForEach(Self.keys) { key in
                    Button { tap(key) } label: { label(for: key) }
                        .buttonStyle(PressablePill(scale: 0.9))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(alignment: .top) {
            // A hairline along the top edge separates the bar from the
            // terminal without drawing a divider across the glass.
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .background {
            Group {
                if #available(iOS 26, *) {
                    Rectangle().fill(.ultraThinMaterial).glassEffect(in: Rectangle())
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            // The bar's glass has to run to the bottom edge: stopping at the
            // safe area leaves a black strip under the keys where the window
            // background shows through, which reads as a rendering bug rather
            // than as the home indicator. `.container` on purpose — extending
            // past the *keyboard* safe area instead would paint a slab in the
            // gap the keyboard is about to fill.
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    @ViewBuilder
    private func label(for key: Key) -> some View {
        Group {
            if let symbol = key.symbol {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(15), weight: .semibold))
            } else {
                Text(key.label)
                    .font(.system(size: Theme.ui(14), weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(Theme.accentOnDark)
        .frame(minWidth: key.wide ? Theme.ui(62) : Theme.ui(44),
               minHeight: Theme.ui(40))
        .floatingGlass()
    }

    private func modifier(_ title: String, on binding: Binding<Bool>) -> some View {
        Button {
            binding.wrappedValue.toggle()
            syncModifiers()
            SoundEffects.shared.tap(.toggle, haptic: .rigid)
        } label: {
            Text(title)
                .font(.system(size: Theme.ui(14), weight: .semibold, design: .monospaced))
                .foregroundStyle(binding.wrappedValue ? Theme.appBackground : Theme.accentOnDark)
                .frame(minWidth: Theme.ui(52), minHeight: Theme.ui(40))
                .background {
                    if binding.wrappedValue {
                        // A latched modifier is the one thing on this bar
                        // that must be unmistakable at a glance.
                        Capsule(style: .continuous)
                            .fill(Theme.accentOnDark)
                            .shadow(color: Theme.accentOnDark.opacity(0.45), radius: 8)
                    }
                }
                .floatingGlass()
        }
        .buttonStyle(PressablePill(scale: 0.9))
        .animation(Theme.Spring.snappy, value: binding.wrappedValue)
    }

    private func tap(_ key: Key) {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if control { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if alt { raw |= GHOSTTY_MODS_ALT.rawValue }
        let mods = ghostty_input_mods_e(raw)

        if let usage = key.usage {
            session.press(usage, mods: mods, text: key.text)
        } else if let text = key.text {
            if raw == GHOSTTY_MODS_NONE.rawValue {
                // No modifier and no control meaning: text is fine and keeps
                // the character exactly as printed on the key.
                session.send(text)
            } else if let scalar = text.unicodeScalars.first,
                      let usage = TerminalKeyMap.usage(for: scalar) {
                session.press(usage, mods: mods, text: text)
            }
        }

        control = false
        alt = false
        syncModifiers()
        SoundEffects.shared.tap(.click, haptic: .light)
    }

    private func syncModifiers() {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if control { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if alt { raw |= GHOSTTY_MODS_ALT.rawValue }
        session.surfaceView.stickyModifiers = ghostty_input_mods_e(raw)
    }
}
