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
    }

    private static let keys: [Key] = [
        .init(label: "esc", symbol: nil, send: "\u{1b}"),
        .init(label: "tab", symbol: nil, send: "\t"),
        .init(label: "/", symbol: nil, send: "/"),
        .init(label: "-", symbol: nil, send: "-"),
        .init(label: "|", symbol: nil, send: "|"),
        .init(label: "~", symbol: nil, send: "~"),
        .init(label: "", symbol: "arrow.up", send: "\u{1b}[A"),
        .init(label: "", symbol: "arrow.down", send: "\u{1b}[B"),
        .init(label: "", symbol: "arrow.left", send: "\u{1b}[D"),
        .init(label: "", symbol: "arrow.right", send: "\u{1b}[C"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                modifier("ctrl", on: $control)
                modifier("alt", on: $alt)
                ForEach(Self.keys) { key in
                    Button { tap(key) } label: { label(for: key) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Theme.paneTitleBar.opacity(0.92))
    }

    @ViewBuilder
    private func label(for key: Key) -> some View {
        Group {
            if let symbol = key.symbol {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(13), weight: .semibold))
            } else {
                Text(key.label)
                    .font(.system(size: Theme.ui(13), weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(Theme.accentOnDark)
        .frame(minWidth: Theme.ui(38), minHeight: Theme.ui(34))
        .glassPill(tone: .dark)
    }

    private func modifier(_ title: String, on binding: Binding<Bool>) -> some View {
        Button {
            binding.wrappedValue.toggle()
            syncModifiers()
        } label: {
            Text(title)
                .font(.system(size: Theme.ui(13), weight: .semibold, design: .monospaced))
                .foregroundStyle(binding.wrappedValue ? Theme.paneTile : Theme.accentOnDark)
                .frame(minWidth: Theme.ui(44), minHeight: Theme.ui(34))
                .background(
                    Capsule(style: .continuous)
                        .fill(binding.wrappedValue ? Theme.accentOnDark : .clear))
                .glassPill(tone: .dark, selected: binding.wrappedValue)
        }
        .buttonStyle(.plain)
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func syncModifiers() {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if control { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if alt { raw |= GHOSTTY_MODS_ALT.rawValue }
        session.surfaceView.stickyModifiers = ghostty_input_mods_e(raw)
    }
}
