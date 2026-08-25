import UIKit
import os

/// The `UIView` libghostty renders into.
///
/// libghostty's Metal renderer draws into an `IOSurface` and hands it to a
/// layer. On macOS it makes the host `NSView` layer-hosting and assigns that
/// layer directly; on iOS `UIView.layer` is read-only, so it adds its own
/// layer as a *sublayer* of ours. Either way nothing here touches Metal.
///
/// Two invariants, both inherited from the Mac app and both worth stating
/// because violating either produces a black terminal rather than a crash:
///
/// 1. **The view must have a non-zero frame before the surface is created.**
///    A `.zero` frame leaves the renderer permanently degenerate — it never
///    recovers, even after a later layout.
/// 2. **The view is welded to its surface for life.** libghostty holds the
///    pointer we hand it. Never reparent this view into a different surface;
///    make a new one.
final class TerminalSurfaceView: UIView {

    /// libghostty adds its own `CAMetalLayer` as a sublayer, so this view's
    /// own layer stays a plain one.
    private(set) var controller: SurfaceController?

    /// Modifier keys latched by the accessory bar. A phone keyboard has no
    /// Ctrl, so the accessory row provides one and it applies to exactly the
    /// next keystroke — the behaviour people expect from a sticky modifier.
    var stickyModifiers: ghostty_input_mods_e = GHOSTTY_MODS_NONE

    private var keyboardHeight: CGFloat = 0

    init(app: Ghostty.App, fontSize: Float = 14) {
        // Non-zero on purpose — see invariant 1. The real size arrives at the
        // first layout pass, a moment later.
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        backgroundColor = UIColor(Theme.paneTile)
        isOpaque = true
        clipsToBounds = true
        contentScaleFactor = UIScreen.main.scale

        controller = SurfaceController(view: self, app: app, fontSize: fontSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        // `close()` is main-actor isolated and deinit is not; the controller
        // is owned solely by this view, so hand it over rather than reaching
        // into it from here.
        let controller = self.controller
        self.controller = nil
        Task { @MainActor in controller?.close() }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // libghostty's sublayer does not participate in Auto Layout.
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = layer.bounds
        }
        MainActor.assumeIsolated { controller?.updateSize() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        contentScaleFactor = window.screen.scale
        MainActor.assumeIsolated {
            controller?.updateSize()
            controller?.setVisible(true)
        }
    }

    // MARK: - First responder

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { MainActor.assumeIsolated { controller?.setFocus(true) } }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { MainActor.assumeIsolated { controller?.setFocus(false) } }
        return ok
    }
}

// MARK: - Software keyboard

extension TerminalSurfaceView: UIKeyInput {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            // A sticky Ctrl turns the next character into its control code.
            // `ghostty_surface_text` would send the literal letter, so this
            // has to go through the key path instead.
            if stickyModifiers.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0,
               let scalar = text.unicodeScalars.first,
               let control = TerminalKeyMap.controlCode(for: scalar) {
                controller.send(String(UnicodeScalar(control)))
                stickyModifiers = GHOSTTY_MODS_NONE
                return
            }
            if stickyModifiers.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 {
                // Alt is ESC-prefix, which is what every terminal program
                // actually reads it as.
                controller.send("\u{1b}" + text)
                stickyModifiers = GHOSTTY_MODS_NONE
                return
            }
            controller.send(text)
        }
    }

    func deleteBackward() {
        MainActor.assumeIsolated { controller?.send("\u{7f}") }
    }

    /// Autocorrect, capitalisation and smart quotes are all actively harmful
    /// in a terminal — a smart quote is not the quote the shell wants.
    var autocorrectionType: UITextAutocorrectionType {
        get { .no } set { _ = newValue }
    }
    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none } set { _ = newValue }
    }
    var smartQuotesType: UITextSmartQuotesType {
        get { .no } set { _ = newValue }
    }
    var smartDashesType: UITextSmartDashesType {
        get { .no } set { _ = newValue }
    }
    var spellCheckingType: UITextSpellCheckingType {
        get { .no } set { _ = newValue }
    }
    var keyboardType: UIKeyboardType {
        get { .asciiCapable } set { _ = newValue }
    }
}

// MARK: - Hardware keyboard

extension TerminalSurfaceView {
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if send(key: key, action: GHOSTTY_ACTION_PRESS) { handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            _ = send(key: key, action: GHOSTTY_ACTION_RELEASE)
        }
        super.pressesEnded(presses, with: event)
    }

    private func send(key: UIKey, action: ghostty_input_action_e) -> Bool {
        MainActor.assumeIsolated {
            guard let controller else { return false }
            guard let keycode = TerminalKeyMap.virtualKeyCode(for: key.keyCode) else {
                return false
            }
            let mods = TerminalKeyMap.mods(from: key.modifierFlags, plus: stickyModifiers)
            let text = key.characters

            var input = ghostty_input_key_s()
            input.action = action
            input.mods = mods
            input.consumed_mods = GHOSTTY_MODS_NONE
            input.keycode = UInt32(keycode)
            input.composing = false
            input.unshifted_codepoint =
                key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0

            if text.isEmpty {
                input.text = nil
                controller.send(key: input)
            } else {
                text.withCString { ptr in
                    input.text = ptr
                    controller.send(key: input)
                }
            }
            if action == GHOSTTY_ACTION_PRESS { stickyModifiers = GHOSTTY_MODS_NONE }
            return true
        }
    }
}
