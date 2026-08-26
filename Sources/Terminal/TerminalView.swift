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

    private struct Key: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String?
        let send: String
        var wide = false
    }

    private static let keys: [Key] = [
        .init(label: "esc", symbol: nil, send: "\u{1b}"),
        .init(label: "tab", symbol: nil, send: "\t"),
        // CR, not LF. A shell ignores a bare newline.
        .init(label: "", symbol: "return", send: "\r", wide: true),
        .init(label: "", symbol: "arrow.up", send: "\u{1b}[A"),
        .init(label: "", symbol: "arrow.down", send: "\u{1b}[B"),
        .init(label: "", symbol: "arrow.left", send: "\u{1b}[D"),
        .init(label: "", symbol: "arrow.right", send: "\u{1b}[C"),
        .init(label: "/", symbol: nil, send: "/"),
        .init(label: "-", symbol: nil, send: "-"),
        .init(label: "|", symbol: nil, send: "|"),
        .init(label: "~", symbol: nil, send: "~"),
        .init(label: "", symbol: "delete.left", send: "\u{7f}"),
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
        // A latched Ctrl applies to the accessory keys too — ctrl+[ is a
        // real thing people press.
        if control, let scalar = key.send.unicodeScalars.first,
           let code = TerminalKeyMap.controlCode(for: scalar) {
            session.send(String(UnicodeScalar(code)))
        } else if alt {
            session.send("\u{1b}" + key.send)
        } else {
            session.send(key.send)
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
